defmodule Membrane.Protocol.Icecast.Input.Machine do
  @moduledoc """
  This module implements a state machine that is capable of parsing an input
  stream in the [Icecast2](http://www.icecast.org)-compatible protocol.

  There are multiple versions of the protocol but all of them have a lot in
  common with HTTP.

  The streaming client is connecting to the server over TCP, sends HTTP-like
  headers and then continuously pushes the media stream in the MP3 or Ogg
  format.

  Icecast versions prior to 2.4.1 have been using

  It can be used by any acceptor library, such as `:ranch`, or with a single
  TCP socket
  """

  @behaviour :gen_statem

  require Logger

  import Membrane.Protocol.Icecast.Helpers

  alias Membrane.Protocol.Transport
  alias Membrane.Protocol.Icecast.Types
  alias Membrane.Protocol.Icecast.Input

  # Maximum amount of headers while reading HTTP part of the protocol
  @http_max_headers 64

  @http_and_version "HTTP/1.0"
  @default_format :mp3

  @known_format_headers ["audio/mpeg", "audio/ogg"]

  @type opts :: %{
          socket: Transport.socket(),
          transport: Transport.t(),
          controller_module: Input.Controller.t(),
          controller_arg: any(),
          allowed_methods: [Types.method_t()],
          allowed_formats: [Types.format_t()],
          server_string: String.t(),
          request_timeout: integer(),
          body_timeout: integer()
        }

  defmodule StateData do
    defstruct allowed_methods: nil,
              allowed_formats: nil,
              controller_module: nil,
              controller_state: nil,
              remote_address: nil,
              socket: nil,
              transport: nil,
              method: nil,
              format: nil,
              username: nil,
              password: nil,
              mount: nil,
              headers: [],
              server_string: nil,
              request_timeout: nil,
              body_timeout: nil,
              timeout_ref: nil
  end

  @impl true
  @spec init(opts()) :: no_return
  def init(
        %{
          socket: socket,
          transport: transport,
          controller_module: controller_module,
          controller_arg: controller_arg,
          allowed_methods: allowed_methods,
          allowed_formats: allowed_formats,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout
        } = arg
      ) do
    {:ok, controller_state} = controller_module.handle_init(controller_arg)
    {:ok, remote_address} = :inet.peername(socket)

    log(
      "Initializing input machine on transport #{inspect(transport)} with #{
        inspect(controller_module)
      }.init(#{inspect(controller_arg)})"
    )

    log("Input machine init argument: #{inspect(arg)}", :debug)

    case controller_module.handle_incoming(remote_address, controller_state) do
      {:ok, {:allow, new_controller_state}} ->
        timeout_ref = Process.send_after(self(), :timeout, request_timeout)

        data = %StateData{
          controller_module: controller_module,
          controller_state: new_controller_state,
          remote_address: remote_address,
          socket: socket,
          transport: transport,
          allowed_methods: allowed_methods,
          allowed_formats: allowed_formats,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout,
          timeout_ref: timeout_ref
        }

        :ok =
          :inet.setopts(socket,
            active: :once,
            packet: :http_bin,
            packet_size: http_packet_size(),
            keepalive: true,
            send_timeout: body_timeout,
            send_timeout_close: true
          )

        :gen_statem.enter_loop(__MODULE__, [], :request, data)

      {:ok, {:deny, code}} ->
        data = %StateData{
          controller_module: controller_module,
          remote_address: remote_address,
          socket: socket,
          transport: transport,
          allowed_methods: allowed_methods,
          allowed_formats: allowed_formats,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout
        }

        shutdown_deny!(code, data)

      _ ->
        shutdown_internal(%StateData{socket: socket, transport: transport})
    end
  end

  @impl true
  def callback_mode, do: :handle_event_function

  ## REQUEST LINE HANDLING

  # Handle the request line of the incoming connection if it is
  # PUT /mount HTTP/1.1 (for the new icecast2 protocol)
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_request, :PUT, {:abs_path, mount}, {1, 1}}},
        :request,
        data
      ) do
    %StateData{allowed_methods: allowed_methods} = data

    if Enum.member?(allowed_methods, :put) do
      handle_request!(:put, mount, data)
    else
      shutdown_method_not_allowed!(:put, data.allowed_methods, data)
    end
  end

  # Handle the request line of the incoming connection if it is
  # SOURCE /mount HTTP/1.0 (for the older icecast2 protocol). TODO make sure it is NOT 1.0 only (also 1.1)
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_request, "SOURCE", {:abs_path, mount}, {1, _}}},
        :request,
        data
      ) do
    %StateData{allowed_methods: allowed_methods} = data

    if Enum.member?(allowed_methods, :source) do
      handle_request!(:source, mount, data)
    else
      shutdown_method_not_allowed!(:source, data.allowed_methods, data)
    end
  end

  # Handle the request line if it is not recognized.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_request, method, {:abs_path, mount}, version}},
        :request,
        data
      ) do
    shutdown_bad_request!({:request, {method, mount, version}}, data)
  end

  # Handle HTTP error while reading request line.
  @impl true
  def handle_event(:info, {:http, _socket, {:http_error, request}}, :request, data) do
    shutdown_bad_request!({:request, request}, data)
  end

  ## HEADERS HANDLING

  # Handle too many headers being sent by the client to avoid DoS.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_header, _, _key, _, _value}},
        :headers,
        %StateData{headers: headers} = data
      )
  when length(headers) >
         @http_max_headers do
           shutdown_invalid!(:too_many_headers, data)
         end

  # Handle correct header event
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_header, _, key, _, val}},
        :headers,
        state_data
      ) do
    next_state_data = handle_header(key, val, state_data)
    {:next_state, :headers, next_state_data}
  end

  # Handle HTTP error while reading headers.
  @impl true
  def handle_event(:info, {:http, _socket, {:http_error, header}}, :headers, data) do
    shutdown_bad_request!({:header, header}, data)
  end

  ## END OF HEADERS HANDLING

  # Handle end of headers if username was not given.
  @impl true
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, %StateData{username: nil} = data) do
    shutdown_invalid!(:unauthorized, data)
  end

  # Handle end of headers if password was not given.
  @impl true
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, %StateData{password: nil} = data) do
    shutdown_invalid!(:unauthorized, data)
  end

  # Handle end of headers if format was recognized and username/password are given.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, :http_eoh},
        :headers,
        data
      ) do
    %StateData{
      transport: transport,
      socket: socket,
      method: method,
      format: format,
      mount: mount,
      username: username,
      password: password,
      headers: headers,
      remote_address: remote_address,
      controller_module: controller_module,
      controller_state: controller_state,
      allowed_formats: allowed_formats,
      body_timeout: body_timeout,
      timeout_ref: timeout_ref
    } = data

    # Original icecast assumes mp3 if no content-type was given
    format = format || @default_format

    Process.cancel_timer(timeout_ref)
    new_timeout_ref = Process.send_after(self(), :timeout, body_timeout)

    controller_opts = %{
      format: format,
      mount: mount,
      username: username,
      password: password,
      headers: headers
    }

    with {_, true} <- {:allowed_format?, Enum.member?(allowed_formats, format)},
         {:ok, {:allow, new_controller_state}} <-
           controller_module.handle_source(
             remote_address,
             method,
             controller_state,
             controller_opts
           ) do
      # TODO use 100-Continue?
      log("Source client accepted")
      :ok = send_line(transport, socket, "#{@http_and_version} #{get_status_line(200)}")
      :ok = send_line(transport, socket, "Connection: close")
      :ok = send_line(transport, socket)
      :ok = :inet.setopts(socket, active: true, packet: :raw, packet_size: 0, keepalive: true)

      {:next_state, :body,
       %StateData{data | controller_state: new_controller_state, timeout_ref: new_timeout_ref}}
    else
      {:ok, {:deny, code}} ->
        log("Source client denied")
        shutdown_deny!(code, data)

      {:allowed_format?, false} ->
        shutdown_invalid!({:format_not_allowed, format}, data)
    end
  end

  ## SOCKET HANDLING

  @impl true
  # Handle payload arriving from the client size.
  def handle_event(
        :info,
        {:tcp, _, payload},
        :body,
        data
      ) do
    %StateData{
      controller_module: controller_module,
      controller_state: controller_state,
      remote_address: remote_address,
      body_timeout: body_timeout,
      timeout_ref: timeout_ref
    } = data

    Process.cancel_timer(timeout_ref)
    new_timeout_ref = Process.send_after(self(), :timeout, body_timeout)

    case controller_module.handle_payload(remote_address, payload, controller_state) do
      {:ok, {:continue, new_controller_state}} ->
        {:next_state, :body,
         %StateData{data | controller_state: new_controller_state, timeout_ref: new_timeout_ref}}

      {:ok, :drop} ->
        shutdown_drop!(data)
    end
  end

  @impl true
  # Handle connection closed from the client size.
  def handle_event(
        :info,
        {:tcp_closed, _},
        _state,
        data
      ) do
    %StateData{
      controller_module: controller_module,
      controller_state: controller_state,
      remote_address: remote_address
    } = data

    :ok = controller_module.handle_closed(remote_address, controller_state)
    {:stop, :normal}
  end

  ## TIMEOUTS HANDLING

  @impl true
  def handle_event(
        :info,
        :timeout,
        _state,
        data
      ) do
    %StateData{
      controller_module: controller_module,
      controller_state: controller_state,
      remote_address: remote_address
    } = data

    :ok = controller_module.handle_timeout(remote_address, controller_state)
    send_response_and_close!(502, data)
  end

  ## HELPERS

  defp handle_request!(method, mount, data) do
    %StateData{socket: socket} = data

    if valid_mount?(mount) do
      :ok = activate_once(socket)

      {:next_state, :headers, %StateData{data | method: method, mount: mount}}
    else
      shutdown_invalid!({:mount, mount}, data)
    end
  end

  defp handle_header(
         :"Content-Type" = key,
         format,
         data
       )
       when format in @known_format_headers do
    %StateData{socket: socket, headers: headers} = data
    :ok = activate_once(socket)
    format_atom = format_header_to_atom(format)
    %StateData{data | format: format_atom, headers: [{key, format} | headers]}
  end

  defp handle_header(
         :Authorization = key,
         "Basic " <> credentials_encoded = val,
         data
       ) do
    %StateData{socket: socket, headers: headers} = data
    :ok = activate_once(socket)

    with {:ok, {username, password}} <- base64_to_credentials(credentials_encoded) do
      %StateData{
        data
        | username: username,
          password: password,
          headers: [{key, val} | headers]
      }
    else
      _ ->
        %StateData{data | username: nil, password: nil, headers: [{key, val} | headers]}
    end
  end

  defp handle_header(key, val, data) do
    %StateData{socket: socket, headers: headers} = data
    :ok = activate_once(socket)
    %StateData{data | headers: [{key, val} | headers]}
  end

  defp format_header_to_atom("audio/mpeg"), do: :mp3
  defp format_header_to_atom("audio/ogg"), do: :ogg

  defp base64_to_credentials(credentials_encoded) do
    case Base.decode64(credentials_encoded) do
      {:ok, credentials} ->
        case String.split(credentials, ":", parts: 2) do
          [username, password] ->
            {:ok, {username, password}}

          _ ->
            :error
        end

      :error ->
        :error
    end
  end
end

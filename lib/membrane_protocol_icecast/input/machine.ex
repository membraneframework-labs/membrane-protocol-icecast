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

  import Membrane.Protocol.Icecast.Helpers

  alias Membrane.Protocol.Transport
  alias Membrane.Protocol.Icecast.Types
  alias Membrane.Protocol.Icecast.Input

  # Maximum line length while while reading HTTP part of the protocol
  @http_packet_size 8192
  # Maximum amount of headers while reading HTTP part of the protocol
  @http_max_headers 64

  @http_and_version "HTTP/1.0"
  @default_format :mp3

  @known_format_headers ["audio/mpeg", "audio/ogg"]

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
  @spec init(%{
        socket: Transport.socket(),
        transport: Transport.t(),
        controller_module: Input.Controller.t(),
        controller_arg: any(),
        allowed_methods: [Types.method_t()],
        allowed_formats: [Types.format_t()],
        server_string: String.t,
        request_timeout: integer(),
        body_timeout: integer()
      }) :: no_return
  def init(%{
        socket: socket,
        transport: transport,
        controller_module: controller_module,
        controller_arg: controller_arg,
        allowed_methods: allowed_methods,
        allowed_formats: allowed_formats,
        server_string: server_string,
        request_timeout: request_timeout,
        body_timeout: body_timeout
      }) do
    {:ok, controller_state} = controller_module.handle_init(controller_arg)
    {:ok, remote_address} = :inet.peername(socket)

    case try_handle(controller_module, :handle_incoming, [remote_address, controller_state]) do
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
            packet_size: @http_packet_size,
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

      :error ->
        shutdown_internal(%StateData{socket: socket, transport: transport})
    end
  end

  @impl true
  def callback_mode, do: :handle_event_function

  ## REQUEST LINE HANDLING

  @impl true
  # Handle the request line of the incoming connection if it is
  # PUT /mount HTTP/1.1 (for the new icecast2 protocol)
  def handle_event(
        :info,
        {:http, _socket, {:http_request, :PUT, {:abs_path, mount}, {1, 1}}},
        :request,
        %StateData{allowed_methods: allowed_methods} = data
      ) do
    if Enum.member?(allowed_methods, :put) do
      handle_request!(:put, mount, data)
    else
      shutdown_method_not_allowed!(:put, data)
    end
  end

  # Handle the request line of the incoming connection if it is
  # SOURCE /mount HTTP/1.0 (for the older icecast2 protocol). TODO make sure it is NOT 1.0 only (also 1.1)
  def handle_event(
        :info,
        {:http, _socket, {:http_request, "SOURCE", {:abs_path, mount}, {1, _}}},
        :request,
        %StateData{allowed_methods: allowed_methods} = data
      ) do
    if Enum.member?(allowed_methods, :source) do
      handle_request!(:source, mount, data)
    else
      shutdown_method_not_allowed!(:source, data)
    end
  end

  # Handle the request line if it is not recognized.
  def handle_event(
        :info,
        {:http, _socket, {:http_request, method, {:abs_path, mount}, version}},
        :request,
        data
      ) do
    shutdown_bad_request!({:request, {method, mount, version}}, data)
  end

  # Handle HTTP error while reading request line.
  def handle_event(:info, {:http, _socket, {:http_error, request}}, :request, data) do
    shutdown_bad_request!({:request, request}, data)
  end

  ## HEADERS HANDLING

  # Handle too many headers being sent by the client to avoid DoS.
  def handle_event(
        :info,
        {:http, _socket, {:http_header, _, _key, _, _value}},
        :headers,
        %StateData{headers: headers} = data
      )
      when length(headers) > @http_max_headers do
    shutdown_invalid!(:too_many_headers, data)
  end

  # Handle correct header event
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
  def handle_event(:info, {:http, _socket, {:http_error, header}}, :headers, data) do
    shutdown_bad_request!({:header, header}, data)
  end

  ## END OF HEADERS HANDLING

  # Handle end of headers if username was not given.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, %StateData{username: nil} = data) do
    shutdown_invalid!(:unauthorized, data)
  end

  # Handle end of headers if password was not given.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, %StateData{password: nil} = data) do
    shutdown_invalid!(:unauthorized, data)
  end

  # Handle end of headers if format was recognized and username/password are given.
  def handle_event(
        :info,
        {:http, _socket, :http_eoh},
        :headers,
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
      ) do
    # Original icecast assumes mp3 if no content-type was given
    format = format || @default_format

    Process.cancel_timer(timeout_ref)
    new_timeout_ref = Process.send_after(self(), :timeout, body_timeout)

    if Enum.member?(allowed_formats, format) do
      case controller_module.handle_source(
             remote_address,
             method,
             controller_state,
             format: format,
             mount: mount,
             username: username,
             password: password,
             headers: headers
           ) do
        {:ok, {:allow, new_controller_state}} ->
          # TODO use 100-Continue?
          :ok = send_line(transport, socket, "#{@http_and_version} #{get_status_line(200)}")
          :ok = send_line(transport, socket, "Connection: close")
          :ok = send_line(transport, socket)
          :ok = :inet.setopts(socket, active: true, packet: :raw, packet_size: 0, keepalive: true)

          {:next_state, :body,
           %StateData{data | controller_state: new_controller_state, timeout_ref: new_timeout_ref}}

        {:ok, {:deny, code}} ->
          shutdown_deny!(code, data)
      end
    else
      shutdown_invalid!({:format_not_allowed, format}, data)
    end
  end

  ## SOCKET HANDLING

  # Handle payload arriving from the client size.
  def handle_event(
        :info,
        {:tcp, _, payload},
        :body,
        %StateData{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address,
          body_timeout: body_timeout,
          timeout_ref: timeout_ref
        } = data
      ) do
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

  # Handle connection closed from the client size.
  def handle_event(
        :info,
        {:tcp_closed, _},
        _state,
        %StateData{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address
        }
      ) do
    :ok = controller_module.handle_closed(remote_address, controller_state)
    {:stop, :normal}
  end

  ## TIMEOUTS HANDLING

  def handle_event(
        :info,
        :timeout,
        _state,
        %StateData{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address
        } = data
      ) do
    :ok = controller_module.handle_timeout(remote_address, controller_state)
    send_response_and_close!(502, data)
  end

  ## HELPERS

  defp handle_request!(method, mount, %StateData{socket: socket} = data) do
    if valid_mount?(mount) do
      :ok = activate_once(socket)

      {:next_state, :headers, %StateData{data | method: method, mount: mount}}
    else
      shutdown_invalid!({:mount, mount}, data)
    end
  end

  defp valid_mount?(mount), do: Regex.match?(~r/^\/[a-zA-Z0-9\._-]+/, to_string(mount))

  defp shutdown_invalid!(
         :unauthorized = reason,
         %StateData{
           controller_module: controller_module,
           controller_state: controller_state,
           remote_address: remote_address
         } = data
       ) do
    :ok = controller_module.handle_invalid(remote_address, reason, controller_state)
    send_response_and_close!(401, data)
  end

  defp shutdown_invalid!(
         reason,
         %StateData{
           controller_module: controller_module,
           controller_state: controller_state,
           remote_address: remote_address
         } = data
       ) do
    :ok = controller_module.handle_invalid(remote_address, reason, controller_state)
    send_response_and_close!(422, data)
  end

  defp shutdown_bad_request!(
         reason,
         %StateData{
           controller_module: controller_module,
           controller_state: controller_state,
           remote_address: remote_address
         } = data
       ) do
    :ok = controller_module.handle_invalid(remote_address, {:request, reason}, controller_state)
    send_response_and_close!(400, data)
  end

  defp shutdown_method_not_allowed!(
         method,
         %StateData{
           controller_module: controller_module,
           controller_state: controller_state,
           remote_address: remote_address,
           allowed_methods: allowed_methods
         } = data
       ) do
    :ok = controller_module.handle_invalid(remote_address, {:method, method}, controller_state)

    allowed_methods_header =
      allowed_methods
      |> Enum.map(fn
        :put -> "PUT"
        :source -> "SOURCE"
      end)
      |> Enum.join(", ")

    send_response_and_close!(405, [{"Allow", allowed_methods_header}], data)
  end

  defp shutdown_deny!(:forbidden, data) do
    send_response_and_close!(403, data)
  end

  defp shutdown_deny!(:unauthorized, data) do
    send_response_and_close!(401, data)
  end

  defp shutdown_internal(data) do
    send_response_and_close!(500, data)
  end

  defp shutdown_drop!(%StateData{transport: transport, socket: socket}) do
    :ok = transport.close(socket)
    {:stop, :normal}
  end

  defp send_response_and_close!(
         status,
         extra_headers \\ [],
         %StateData{transport: transport, socket: socket, server_string: server_string}
       ) do
    status_line = get_status_line(status)
    :ok = send_line(transport, socket, "#{@http_and_version} #{status_line}")
    :ok = send_line(transport, socket, "Connection: close")
    :ok = send_line(transport, socket, "Server: #{server_string}")

    extra_headers
    |> Enum.each(fn {key, value} ->
      :ok = send_line(transport, socket, "#{key}: #{value}")
    end)

    # TODO add date header

    :ok = send_line(transport, socket)
    :ok = transport.close(socket)
    {:stop, :normal}
  end

  defp try_handle(m, f, a) do
    try do
      :erlang.apply(m, f, a)
    rescue
      _ -> :error
    end
  end

  # TODO move to common functions (when this exists)
  defp get_status_line(200), do: "200 OK"
  defp get_status_line(400), do: "400 Bad Request"
  defp get_status_line(401), do: "401 Unauthorized"
  defp get_status_line(403), do: "403 Forbidden"
  defp get_status_line(404), do: "404 Not Found"
  defp get_status_line(405), do: "405 Method Not Allowed"
  defp get_status_line(422), do: "422 Unprocessable Entity"
  defp get_status_line(500), do: "500 Internal Server Error"
  defp get_status_line(502), do: "502 Gateway Timeout"

  defp handle_header(
         :"Content-Type" = key,
         format,
         %StateData{socket: socket, headers: headers} = data
       )
       when format in @known_format_headers do
    :ok = activate_once(socket)
    format_atom = format_header_to_atom(format)
    %StateData{data | format: format_atom, headers: [{key, format} | headers]}
  end

  defp handle_header(
         :Authorization = key,
         "Basic " <> credentials_encoded = val,
         %StateData{socket: socket, headers: headers} = data
       ) do
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

  defp handle_header(key, val, %StateData{socket: socket, headers: headers} = data) do
    :ok = activate_once(socket)
    %StateData{data | headers: [{key, val} | headers]}
  end

  defp format_header_to_atom("audio/mpeg"), do: :mp3
  defp format_header_to_atom("audio/ogg"), do: :ogg

  defp activate_once(socket),
    do: :inet.setopts(socket, active: :once, packet: :httph_bin, packet_size: @http_packet_size)

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

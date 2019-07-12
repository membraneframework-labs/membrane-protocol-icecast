defmodule Membrane.Protocol.Icecast.Output.Machine do
  @behaviour :gen_statem

  import Membrane.Protocol.Icecast.Helpers

  alias Membrane.Protocol.Transport
  alias Membrane.Protocol.Icecast.Output

  # Maximum amount of headers while reading HTTP part of the protocol
  @http_max_headers 64

  defmodule StateData do
    defstruct controller_module: nil,
              controller_state: nil,
              remote_address: nil,
              socket: nil,
              transport: nil,
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
          controller_module: Output.Controller.t(),
          controller_arg: any(),
          server_string: String.t(),
          request_timeout: integer(),
          body_timeout: integer()
        }) :: no_return
  def init(%{
        socket: socket,
        transport: transport,
        controller_module: controller_module,
        controller_arg: controller_arg,
        server_string: server_string,
        request_timeout: request_timeout,
        body_timeout: body_timeout
      }) do
    {:ok, controller_state} = controller_module.handle_init(controller_arg)
    {:ok, remote_address} = :inet.peername(socket)

    case controller_module.handle_incoming(remote_address, controller_state) do
      {:ok, {:allow, new_controller_state}} ->
        timeout_ref = Process.send_after(self(), :timeout, request_timeout)

        data = %StateData{
          controller_module: controller_module,
          controller_state: new_controller_state,
          remote_address: remote_address,
          socket: socket,
          transport: transport,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout,
          timeout_ref: timeout_ref
        }

        :ok =
          transport.setopts(socket,
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
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout
        }

        shutdown_deny!(code, data)
    end
  end

  @impl true
  def callback_mode, do: :handle_event_function

  ## REQUEST LINE HANDLING

  # Handle the request line of the incoming connection. Support only GET via HTTP/1.1.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_request, :GET, {:abs_path, mount}, {1, _}}},
        :request,
        data
      ) do
    handle_request!(mount, data)
  end

  # Handle the request line if method was not GET
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_request, method, _path, {1, _}}},
        :request,
        data
      ) do
    shutdown_method_not_allowed!(method, [:get], data)
  end

  # Handle the request line if it is not recognized.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_request, method, {:abs_path, mount}, version}},
        :request,
        data
      ) do
    # FIXME use shutdown_method_not_allowed instead?
    shutdown_invalid!({:request, {method, mount, version}}, data)
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
      when length(headers) > @http_max_headers do
    shutdown_invalid!(:too_many_headers, data)
  end

  # Handle each extra header being sent from the client that was not handled before.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, {:http_header, _, key, _, value}},
        :headers,
        %StateData{transport: transport, socket: socket, headers: headers} = data
      ) do
    :ok =
      transport.setopts(socket, active: :once, packet: :httph_bin, packet_size: http_packet_size())

    {:next_state, :headers, %StateData{data | headers: [{key, value} | headers]}}
  end

  # Handle HTTP error while reading headers.
  @impl true
  def handle_event(:info, {:http, _socket, {:http_error, header}}, :headers, data) do
    shutdown_bad_request!({:header, header}, data)
  end

  ## END OF HEADERS HANDLING

  # Handle end of headers if format was recognized and username/password are given.
  @impl true
  def handle_event(
        :info,
        {:http, _socket, :http_eoh},
        :headers,
        %StateData{
          transport: transport,
          socket: socket,
          mount: mount,
          headers: headers,
          remote_address: remote_address,
          controller_module: controller_module,
          controller_state: controller_state,
          timeout_ref: timeout_ref,
          body_timeout: body_timeout
        } = data
      ) do
    Process.cancel_timer(timeout_ref)

    case controller_module.handle_listener(remote_address, mount, headers, controller_state) do
      {:ok, {:allow, new_controller_state}, format} ->
        tref = Process.send_after(self(), :timeout, body_timeout)
        content_type = format_to_content_type(format)
        # Connection: close\r\n") # TODO make sure this connection close is not intended here.
        :ok = send_line(transport, socket, "HTTP/1.0 #{get_status_line(200)}")
        :ok = send_line(transport, socket, content_type)
        :ok = transport.setopts(socket, active: true, packet: :raw, packet_size: 0)

        {:next_state, :body,
         %StateData{data | controller_state: new_controller_state, timeout_ref: tref}}

      {:ok, {:deny, code}} ->
        shutdown_deny!(code, data)
    end
  end

  ## SOCKET HANDLING

  # Handle connection closed from the client size.
  @impl true
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

  # Handle payload being sent
  @impl true
  def handle_event(
        :info,
        {:payload, payload},
        :body,
        %StateData{
          transport: transport,
          body_timeout: body_timeout,
          socket: socket,
          timeout_ref: tref
        } = data
      ) do
    Process.cancel_timer(tref)
    tref = Process.send_after(self(), :timeout, body_timeout)
    :ok = transport.send(socket, payload)
    {:next_state, :body, %StateData{data | timeout_ref: tref}}
  end

  ## TIMEOUTS HANDLING

  @impl true
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

  defp handle_request!(mount, %StateData{socket: socket} = data) do
    if valid_mount?(mount) do
      :ok = activate_once(socket)

      {:next_state, :headers, %StateData{data | mount: mount}}
    else
      shutdown_invalid!({:mount, mount}, data)
    end
  end

  defp format_to_content_type(:mp3), do: "Content-Type: audio/mpeg\r\n"
  defp format_to_content_type(:ogg), do: "Content-Type: audio/ogg\r\n"
end

defmodule Membrane.Protocol.Icecast.Output.Machine do
  @behaviour :gen_statem

  @http_packet_size 8192 # Maximum line length while while reading HTTP part of the protocol
  @http_max_headers 64 # Maximum amount of headers while reading HTTP part of the protocol

  require Record
  Record.defrecord(
    :state_data,
    controller_module: nil,
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
  )

  @impl true
  def init({socket, transport, controller_module, controller_arg, server_string, request_timeout, body_timeout}) do
    {:ok, controller_state} = controller_module.handle_init(controller_arg)
    {:ok, remote_address} = :inet.peername(socket)

    case controller_module.handle_incoming(remote_address, controller_state) do
      {:ok, {:allow, new_controller_state}} ->
        timeout_ref = Process.send_after(self(), :timeout, request_timeout)

        data = state_data(
          controller_module: controller_module,
          controller_state: new_controller_state,
          remote_address: remote_address,
          socket: socket,
          transport: transport,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout,
          timeout_ref: timeout_ref
        )

        :ok = transport.setopts(socket, [
          active: :once,
          packet: :http_bin,
          packet_size: @http_packet_size,
          keepalive: true,
          send_timeout: body_timeout,
          send_timeout_close: true
        ])
        :gen_statem.enter_loop(__MODULE__, [], :request, data)

      {:ok, {:deny, code}} ->
        data = state_data(
          controller_module: controller_module,
          remote_address: remote_address,
          socket: socket,
          transport: transport,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout
        )

        shutdown_deny!(code, data)
    end
  end

  @impl true
  def callback_mode, do: :handle_event_function


  ## REQUEST LINE HANDLING

  @impl true
  # Handle the request line of the incoming connection. Support only GET via HTTP/1.1.
  def handle_event(:info, {:http, _socket, {:http_request, :GET, {:abs_path, mount}, {1, _}}}, :request, data) do
    handle_request!(mount, data)
  end

  # Handle the request line if method was not GET
  def handle_event(:info, {:http, _socket, {:http_request, method, _path, {1, _}}}, :request, data) do
    shutdown_method_not_allowed!(method, data)
  end

  # Handle the request line if it is not recognized.
  def handle_event(:info, {:http, _socket, {:http_request, method, {:abs_path, mount}, version}}, :request, data) do
    shutdown_invalid!({:request, {method, mount, version}}, data) # FIXME use shutdown_method_not_allowed instead?
  end

  # Handle HTTP error while reading request line.
  def handle_event(:info, {:http, _socket, {:http_error, request}}, :request, data) do
    shutdown_bad_request!({:request, request}, data)
  end


  ## HEADERS HANDLING

  # Handle too many headers being sent by the client to avoid DoS.
  def handle_event(:info, {:http, _socket, {:http_header, _, _key, _, _value}}, :headers, state_data(headers: headers) = data) when length(headers) > @http_max_headers do
    shutdown_invalid!(:too_many_headers, data)
  end

  # Handle each extra header being sent from the client that was not handled before.
  def handle_event(:info, {:http, _socket, {:http_header, _, key, _, value}}, :headers, state_data(transport: transport, socket: socket, headers: headers) = data) do
    :ok = transport.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])
    {:next_state, :headers, state_data(data, headers: [{key,value}|headers])}
  end

  # Handle HTTP error while reading headers.
  def handle_event(:info, {:http, _socket, {:http_error, header}}, :headers, data) do
    shutdown_bad_request!({:header, header}, data)
  end


  ## END OF HEADERS HANDLING

  # Handle end of headers if format was recognized and username/password are given.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, state_data(transport: transport, socket: socket, mount: mount, headers: headers, remote_address: remote_address, controller_module: controller_module, controller_state: controller_state, timeout_ref: timeout_ref, body_timeout: body_timeout) = data) do
    Process.cancel_timer(timeout_ref)

    case controller_module.handle_listener(remote_address, mount, headers, controller_state) do
      {:ok, {:allow, new_controller_state}, format} ->
        tref = Process.send_after(self(), :timeout, body_timeout)
        content_type = format_to_content_type(format)
        :ok = transport.send(socket, "HTTP/1.0 200 OK\r\n")#Connection: close\r\n") # TODO make sure this connection close is not intended here.
        :ok = transport.send(socket, "#{content_type}\r\n")
        :ok = transport.setopts(socket, [active: true, packet: :raw, packet_size: 0])
        {:next_state, :body, state_data(data, controller_state: new_controller_state, timeout_ref: tref)}

      {:ok, {:deny, code}} ->
        shutdown_deny!(code, data)
    end
  end


  ## SOCKET HANDLING

  # Handle connection closed from the client size.
  def handle_event(:info, {:tcp_closed, _}, _state, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address)) do
    :ok = controller_module.handle_closed(remote_address, controller_state)
    :stop
  end

  # Handle payload being sent
  def handle_event(:info, {:payload, payload}, :body, state_data(transport: transport, body_timeout: body_timeout, socket: socket, timeout_ref: tref) = data) do
    Process.cancel_timer(tref)
    Process.send_after(self(), :timeout, body_timeout)
    :ok = transport.send(socket, payload)
    {:next_state, :body, data}
  end


  ## TIMEOUTS HANDLING

  def handle_event(:info, :timeout, _state, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address) = data) do
    :ok = controller_module.handle_timeout(remote_address, controller_state)
    send_response_and_close!("502 Gateway Timeout", data)
  end


  ## HELPERS

  defp handle_request!(mount, state_data(transport: transport, socket: socket) = data) do
    if Regex.match?(~r/^\/[a-zA-Z0-9\._-]+/, to_string(mount)) do
      :ok = transport.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])
      {:next_state, :headers, state_data(data, mount: mount)}
    else
      shutdown_invalid!({:mount, mount}, data)
    end
  end

  defp shutdown_invalid!(:unauthorized = reason, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address) = data) do
    :ok = controller_module.handle_invalid(remote_address, reason, controller_state)
    send_response_and_close!("401 Unauthorized", data)
  end

  defp shutdown_invalid!(reason, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address) = data) do
    :ok = controller_module.handle_invalid(remote_address, reason, controller_state)
    send_response_and_close!("422 Unprocessable Entity", data)
  end

  defp shutdown_bad_request!(reason, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address) = data) do
    :ok = controller_module.handle_invalid(remote_address, {:request, reason}, controller_state)
    send_response_and_close!("400 Bad Request", data)
  end

  defp shutdown_method_not_allowed!(method, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address) = data) do
    :ok = controller_module.handle_invalid(remote_address, {:method, method}, controller_state)
    send_response_and_close!("405 Method Not Allowed", [{"Allow", "GET"}], data)
  end

  defp shutdown_deny!(:unauthorized, data) do
    send_response_and_close!("401 Unauthorized", data)
  end

  defp shutdown_deny!(:forbidden, data) do
    send_response_and_close!("403 Forbidden", data)
  end

  defp shutdown_deny!(:not_found, data) do
    send_response_and_close!("404 Not Found", data)
  end

  defp shutdown_drop!(state_data(transport: transport, socket: socket)) do
    :ok = transport.close(socket)
    :stop
  end

  defp send_response_and_close!(status, data) do
    send_response_and_close!(status, [], data)
  end

  defp send_response_and_close!(status, extra_headers, state_data(transport: transport, socket: socket, server_string: server_string)) do
    :ok = transport.send(socket, "HTTP/1.1 #{status}\r\n")
    :ok = transport.send(socket, "Connection: close\r\n")
    :ok = transport.send(socket, "Server: #{server_string}\r\n")
    extra_headers
    |> Enum.each(fn({key, value}) ->
      :ok = transport.send(socket, "#{key}: #{value}\r\n")
    end)
    # TODO add date header

    :ok = transport.send(socket, "\r\n")
    :ok = transport.close(socket)
    :stop
  end
end

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

  @http_packet_size 8192 # Maximum line length while while reading HTTP part of the protocol
  @http_max_headers 64 # Maximum amount of headers while reading HTTP part of the protocol

  require Record
  Record.defrecord(
    :state_data,
    allowed_methods: nil,
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
  )

  @impl true
  def init({socket, transport, controller_module, controller_arg, allowed_methods, allowed_formats, server_string, request_timeout, body_timeout}) do
    {:ok, controller_state} = controller_module.handle_init(controller_arg)
    {:ok, remote_address} = :inet.peername(socket)

    case try_handle(controller_module, :handle_incoming, [remote_address, controller_state]) do
      {:ok, {:allow, new_controller_state}} ->
        timeout_ref = Process.send_after(self(), :timeout, request_timeout)

        data = state_data(
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
        )

        :ok = :inet.setopts(socket, [
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
          allowed_methods: allowed_methods,
          allowed_formats: allowed_formats,
          server_string: server_string,
          request_timeout: request_timeout,
          body_timeout: body_timeout
        )

        shutdown_deny!(code, data)
      :error ->
        shutdown_internal(state_data(socket: socket, transport: transport))
    end
  end

  @impl true
  def callback_mode, do: :handle_event_function

  ## REQUEST LINE HANDLING

  @impl true
  # Handle the request line of the incoming connection if it is
  # PUT /mount HTTP/1.1 (for the new icecast2 protocol)
  def handle_event(:info, {:http, _socket, {:http_request, :PUT, {:abs_path, mount}, {1, 1}}}, :request, state_data(allowed_methods: allowed_methods) = data) do
    if Enum.member?(allowed_methods, :put) do
      handle_request!(:put, mount, data)
    else
      shutdown_method_not_allowed!(:put, data)
    end
  end

  # Handle the request line of the incoming connection if it is
  # SOURCE /mount HTTP/1.0 (for the older icecast2 protocol).
  def handle_event(:info, {:http, _socket, {:http_request, 'SOURCE', {:abs_path, mount}, {1, 0}}}, :request, state_data(allowed_methods: allowed_methods) = data) do
    if Enum.member?(allowed_methods, :source) do
      handle_request!(:source, mount, data)
    else
      shutdown_method_not_allowed!(:source, data)
    end
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

  # Handle Content-Type header if the format is MP3.
  def handle_event(:info, {:http, _socket, {:http_header, _, :"Content-Type" = key, _, "audio/mpeg" = value}}, :headers, state_data(transport: transport, socket: socket, headers: headers) = data) do
    :ok = :inet.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])
    {:next_state, :headers, state_data(data, format: :mp3, headers: [{key,value}|headers])}
  end

  # Handle Content-Type header if the format is Ogg audio.
  def handle_event(:info, {:http, _socket, {:http_header, _, :"Content-Type" = key, _, "audio/ogg" = value}}, :headers, state_data(transport: transport, socket: socket, headers: headers) = data) do
    :ok = :inet.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])
    {:next_state, :headers, state_data(data, format: :ogg, headers: [{key,value}|headers])}
  end

  # Handle Authorization header if it is using HTTP Basic Auth.
  def handle_event(:info, {:http, _socket, {:http_header, _, :"Authorization" = key, _, "Basic " <> credentials_encoded = value}}, :headers, state_data(transport: transport, socket: socket, headers: headers) = data) do
    :ok = :inet.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])

    case Base.decode64(credentials_encoded) do
      {:ok, credentials} ->
        case String.split(credentials, ":", parts: 2) do
          [username, password] ->
            {:next_state, :headers, state_data(data, username: username, password: password, headers: [{key,value}|headers])}

          _ ->
            {:next_state, :headers, state_data(data, username: nil, password: nil, headers: [{key,value}|headers])}
        end

      :error ->
        {:next_state, :headers, state_data(data, username: nil, password: nil, headers: [{key,value}|headers])}
    end
  end

  # Handle each extra header being sent from the client that was not handled before.
  def handle_event(:info, {:http, _socket, {:http_header, _, key, _, value}}, :headers, state_data(transport: transport, socket: socket, headers: headers) = data) do
    :ok = :inet.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])
    {:next_state, :headers, state_data(data, headers: [{key,value}|headers])}
  end

  # Handle HTTP error while reading headers.
  def handle_event(:info, {:http, _socket, {:http_error, header}}, :headers, data) do
    shutdown_bad_request!({:header, header}, data)
  end


  ## END OF HEADERS HANDLING

  # Handle end of headers if format was not recognized.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, state_data(format: nil, headers: headers) = data) do
    shutdown_invalid!({:format_unknown, headers[:"Content-Type"]}, data)
  end

  # Handle end of headers if username was not given.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, state_data(username: nil) = data) do
    shutdown_invalid!(:unauthorized, data)
  end

  # Handle end of headers if password was not given.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, state_data(password: nil) = data) do
    shutdown_invalid!(:unauthorized, data)
  end

  # Handle end of headers if format was recognized and username/password are given.
  def handle_event(:info, {:http, _socket, :http_eoh}, :headers, state_data(transport: transport, socket: socket, method: method, format: format, mount: mount, username: username, password: password, headers: headers, remote_address: remote_address, controller_module: controller_module, controller_state: controller_state, allowed_formats: allowed_formats, body_timeout: body_timeout, timeout_ref: timeout_ref) = data) do
    Process.cancel_timer(timeout_ref)
    new_timeout_ref = Process.send_after(self(), :timeout, body_timeout)

    if Enum.member?(allowed_formats, format) do
      case controller_module.handle_source(remote_address, method, format, mount, username, password, headers, controller_state) do
        {:ok, {:allow, new_controller_state}} ->
          :ok = transport.send(socket, "HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n") # TODO use 100-Continue?
          :ok = :inet.setopts(socket, [active: true, packet: :raw, packet_size: 0, keepalive: true])
          {:next_state, :body, state_data(data, controller_state: new_controller_state, timeout_ref: new_timeout_ref)}

        {:ok, {:deny, code}} ->
          shutdown_deny!(code, data)
      end
    else
      shutdown_invalid!({:format_not_allowed, format}, data)
    end
  end


  ## SOCKET HANDLING

  # Handle payload arriving from the client size.
  def handle_event(:info, {:tcp, _, payload}, :body, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address, body_timeout: body_timeout, timeout_ref: timeout_ref) = data) do
    Process.cancel_timer(timeout_ref)
    new_timeout_ref = Process.send_after(self(), :timeout, body_timeout)

    case controller_module.handle_payload(remote_address, payload, controller_state) do
      {:ok, {:continue, new_controller_state}} ->
        {:next_state, :body, state_data(data, controller_state: new_controller_state, timeout_ref: new_timeout_ref)}

      {:ok, :drop} ->
        shutdown_drop!(data)
    end
  end

  # Handle connection closed from the client size.
  def handle_event(:info, {:tcp_closed, _}, _state, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address)) do
    :ok = controller_module.handle_closed(remote_address, controller_state)
    :stop
  end


  ## TIMEOUTS HANDLING

  def handle_event(:info, :timeout, _state, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address) = data) do
    :ok = controller_module.handle_timeout(remote_address, controller_state)
    send_response_and_close!("502 Gateway Timeout", data)
  end


  ## HELPERS

  defp handle_request!(method, mount, state_data(transport: transport, socket: socket) = data) do
    if valid_mount?(mount) do
      :ok = :inet.setopts(socket, [active: :once, packet: :httph_bin, packet_size: @http_packet_size])
      {:next_state, :headers, state_data(data, method: method, mount: mount)}
    else
      shutdown_invalid!({:mount, mount}, data)
    end
  end

  defp valid_mount?(mount), do: Regex.match?(~r/^\/[a-zA-Z0-9\._-]+/, to_string(mount))

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

  defp shutdown_method_not_allowed!(method, state_data(controller_module: controller_module, controller_state: controller_state, remote_address: remote_address, allowed_methods: allowed_methods) = data) do
    :ok = controller_module.handle_invalid(remote_address, {:method, method}, controller_state)
    allowed_methods_header =
      allowed_methods
      |> Enum.map(fn
        :put -> "PUT"
        :source -> "SOURCE"
      end)
      |> Enum.join(", ")

    send_response_and_close!("405 Method Not Allowed", [{"Allow", allowed_methods_header}], data)
  end

  defp shutdown_deny!(:forbidden, data) do
    send_response_and_close!("403 Forbidden", data)
  end

  defp shutdown_deny!(:unauthorized, data) do
    send_response_and_close!("401 Unauthorized", data)
  end

  defp shutdown_internal(data) do
    send_response_and_close!("500 Internal Server Error", data)
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

  defp try_handle(m, f, a) do
    try do
      :erlang.apply(m, f, a)
    rescue
        _ -> :error
    end
  end


end

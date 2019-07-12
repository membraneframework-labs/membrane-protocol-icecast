defmodule Membrane.Protocol.Icecast.Helpers do
  @eof "\r\n"

  require Logger

  # Maximum line length while while reading HTTP part of the protocol
  def http_packet_size, do: 8192

  def send_line(transport, socket, msg), do: transport.send(socket, "#{msg}#{@eof}")

  def send_line(transport, socket), do: transport.send(socket, "#{@eof}")

  def valid_mount?(mount), do: Regex.match?(~r/^\/[a-zA-Z0-9\._-]+/, to_string(mount))

  def send_response_and_close!(status, data) do
    send_response_and_close!(status, [], "", data)
  end

  def send_response_and_close!(status, extra_headers, data) do
    send_response_and_close!(status, extra_headers, "", data)
  end

  def send_response_and_close!(
        status,
        extra_headers,
        body,
        %{transport: transport, socket: socket, server_string: server_string}
      ) do
    log("Closing machine with status #{inspect(status)}", :info)
    status_line = get_status_line(status)
    :ok = send_line(transport, socket, "HTTP/1.1 #{status_line}")
    :ok = send_line(transport, socket, "Connection: close")
    :ok = send_line(transport, socket, "Server: #{server_string}")

    extra_headers
    |> Enum.each(fn {key, value} ->
      :ok = send_line(transport, socket, "#{key}: #{value}")
    end)

    # TODO add date header
    case body do
      "" ->
        :ok

      _ ->
        :ok = send_line(transport, socket)
        transport.send(socket, body)
    end

    :ok = send_line(transport, socket)
    :ok = transport.close(socket)
    {:stop, :normal}
  end

  def get_status_line(200), do: "200 OK"
  def get_status_line(400), do: "400 Bad Request"
  def get_status_line(401), do: "401 Unauthorized"
  def get_status_line(403), do: "403 Forbidden"
  def get_status_line(404), do: "404 Not Found"
  def get_status_line(405), do: "405 Method Not Allowed"
  def get_status_line(422), do: "422 Unprocessable Entity"
  def get_status_line(500), do: "500 Internal Server Error"
  def get_status_line(502), do: "502 Gateway Timeout"

  def activate_once(socket),
    do: :inet.setopts(socket, active: :once, packet: :httph_bin, packet_size: http_packet_size())

  def shutdown_invalid!(
        :unauthorized = reason,
        %{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address
        } = data
      ) do
    :ok = controller_module.handle_invalid(remote_address, reason, controller_state)
    send_response_and_close!(401, data)
  end

  def shutdown_invalid!(
        reason,
        %{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address
        } = data
      ) do
    :ok = controller_module.handle_invalid(remote_address, reason, controller_state)
    send_response_and_close!(422, data)
  end

  def shutdown_bad_request!(
        reason,
        %{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address
        } = data
      ) do
    :ok = controller_module.handle_invalid(remote_address, {:request, reason}, controller_state)
    send_response_and_close!(400, data)
  end

  def shutdown_method_not_allowed!(
        method,
        allowed_methods,
        %{
          controller_module: controller_module,
          controller_state: controller_state,
          remote_address: remote_address
        } = data
      ) do
    :ok = controller_module.handle_invalid(remote_address, {:method, method}, controller_state)

    allowed_methods_header =
      allowed_methods
      |> Enum.map(fn
        :put -> "PUT"
        :source -> "SOURCE"
        :get -> "GET"
      end)
      |> Enum.join(", ")

    send_response_and_close!(405, [{"Allow", allowed_methods_header}], data)
  end

  def shutdown_drop!(%{transport: transport, socket: socket}) do
    :ok = transport.close(socket)
    {:stop, :normal}
  end

  def shutdown_deny!(:unauthorized, data) do
    send_response_and_close!(401, data)
  end

  def shutdown_deny!(:forbidden, data) do
    send_response_and_close!(403, data)
  end

  def shutdown_deny!(:not_found, data) do
    body = """
    <html>
      <head>
        <title>
          Error 404
        </title>
      </head>
      <body>
        <b>404 - The file you requested could not be found</b>
      </body>
    </html>
    """

    send_response_and_close!(404, [{"content-type", "text/html"}], body, data)
  end

  def shutdown_internal(data) do
    send_response_and_close!(500, data)
  end

  def log(msg), do: log(msg, :info)

  def log(msg, :info) do
    me = inspect(self())
    Logger.info("(#{me}) #{msg}")
  end

  def log(msg, :debug) do
    me = inspect(self())
    Logger.debug("(#{me}) #{msg}")
  end
end

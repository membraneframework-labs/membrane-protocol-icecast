defmodule Membrane.Protocol.Icecast.Helpers do
  @eof "\r\n"

  def send_line(transport, socket, msg), do: transport.send(socket, "#{msg}#{@eof}")

  def send_line(transport, socket), do: transport.send(socket, "#{@eof}")

end

defmodule Membrane.Protocol.Icecast.Types do
  @type remote_address_t :: {:inet.ip_address(), :inet.port_number()}

  @type format_t :: :mp3 | :ogg
  @type method_t :: :put | :source
  @type mount_t :: String.t()
  @type metadata_t :: binary | %{String.t() => String.t()}
  @type headers_t :: [] | [{String.t(), String.t()}]
  @type username :: String.t
  @type password :: String.t
end

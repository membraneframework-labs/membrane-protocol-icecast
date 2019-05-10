defmodule Membrane.Server.Icecast.Types do
  @type remote_address_t :: {:inet.ip, :inet.port}

  @type format_t :: :mp3 | :ogg
  @type method_t :: :put | :source
  @type mount_t :: String.t
  @type metadata_t :: binary | %{String.t => String.t}
  @type headers_t :: [] | [{String.t, String.t}]

end

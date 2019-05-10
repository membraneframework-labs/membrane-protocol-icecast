defmodule Membrane.Server.Icecast do
  @doc """
  Returns this application's version.
  """
  @spec version! :: String.t
  def version! do
    {:ok, version} = :application.get_key(:membrane_server_icecast, :vsn)
    version
  end
end

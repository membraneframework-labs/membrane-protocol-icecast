defmodule Membrane.Protocol.Transport do
  @type t :: module()
  @type socket :: term()

  @callback send(socket(), String.t()) :: :ok | {:error, reason :: any()}
  @callback close(socket()) :: :ok
end

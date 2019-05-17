defmodule Membrane.Protocol.Icecast.Utils do

  
  defmodule Recorder do

    @receive_timeout 1000
    # TODO change it so that it does not
    # send messages to testcase process

    def start_link(pid) do
      Agent.start_link(fn -> pid end, name: __MODULE__)
    end

    def push(info) do
      pid = Agent.get(__MODULE__, fn(p) -> p end)
      send pid, {:'$recorder', info}
    end

    def get do
      receive do
        {:'$recorder', e} -> e
      after
        @receive_timeout ->
          :timeout_in_recorder
      end
    end

    def no_messages? do
      receive do
        {:'$recorder', _} ->
          false
      after
        @receive_timeout ->
          true
      end
    end

    def flush(0) do
      :ok
    end
    def flush(n) do
      receive do
        {:'$recorder', _} -> flush(n - 1)
      after
        100 -> :ok
      end
    end

    def flush() do
      receive do
        {:'$recorder', _} ->
          flush()
      after
        100 -> :ok
      end
    end
  end

end

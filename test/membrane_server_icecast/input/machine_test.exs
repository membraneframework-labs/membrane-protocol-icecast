defmodule Membrane.Server.Icecast.Input.MachineTest do
  use ExUnit.Case, async: true
  alias Membrane.Server.Icecast.Input.Machine

  defmodule Recorder do
    def start_link do
      Agent.start_link(fn -> [] end, name: __MODULE__)
    end

    def push(info) do
      Agent.update(__MODULE__, fn(log) -> [info|log] end)
    end

    def get do
      Agent.get(__MODULE__, fn(log) -> Enum.reverse(log) end)
    end
  end

  setup do
    {:ok, recorder} = Recorder.start_link()
    []
  end

  describe "controller's callback" do
    defmodule TestController do
      use Membrane.Server.Icecast.Input.Controller

      def handle_init(arg) do
        IO.puts "handle_init"
        Recorder.push({:handle_init, arg})
        {:ok, :somestate}
      end
    end

    test "handle_init/1 is being called with argument that was passed to the Machine.init/1" do
      {:ok, listen_socket} = :gen_tcp.listen(1236, [:binary])
      {:ok, _conn} = :gen_tcp.connect({127, 0, 0, 1}, 1236, [active: false])
      {:ok, socket} = :gen_tcp.accept(listen_socket)

      {:ok, machine} = :gen_statem.start_link(Machine, {socket, :gen_tcp, TestController, "test controler arg", [:put, :source], [:mp3], "Some Server", 10000, 10000}, [])

      IO.puts "2"
      assert Recorder.get() == [
        {:handle_info, "test controler arg"}
      ]
      IO.puts "3"

      :gen_statem.stop(machine)
      IO.puts "4"
    end
  end
end

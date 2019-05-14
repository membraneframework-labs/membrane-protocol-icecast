defmodule Membrane.Protocol.Icecast.Input.MachineTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine

  @test_port 1237

  defmodule Recorder do
    def start_link(pid) do
      Agent.start_link(fn -> pid end, name: __MODULE__)
    end

    def push(info) do
      pid = Agent.get(__MODULE__, fn(p) -> p end)
      send pid, info
    end

    def get do
      receive do
        e -> e
      end
    end
  end


  setup_all do
    {:ok, listen_socket} = :gen_tcp.listen(@test_port, [:binary])

    on_exit fn ->
      :gen_tcp.close(listen_socket)
    end

    %{listen_socket: listen_socket}
  end


  describe "Controller's callbacks" do

    defmodule TestController do
      use Membrane.Protocol.Icecast.Input.Controller

      def handle_init({_, pid} = arg) do
        Recorder.push({:handle_init, arg})
        {:ok, :somestate}
      end
    end

    setup %{listen_socket: ls} do
      {:ok, _recorder} = Recorder.start_link(self())
      {:ok, conn} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [active: false])
      {:ok, socket} = :gen_tcp.accept(ls)

      on_exit fn ->
        :gen_tcp.close(conn)
        :gen_tcp.close(socket)
      end

      %{socket: socket}
    end

    test "handle_init/1 is being called with argument that was passed to the Machine.init/1", %{socket: socket} do
      me = self()
      argument = {"test controler arg", me}
      machine =
        :proc_lib.spawn_link(:gen_statem, :start_link,
          [
            Machine,
            {socket,
              :gen_tcp,
              TestController,
              argument,
              [:put, :source],
              [:mp3],
              "Some Server",
              10000,
              10000
            },
            []
          ]
        )

      assert Recorder.get() == {:handle_init, {"test controler arg", me}}
    end
  end
end

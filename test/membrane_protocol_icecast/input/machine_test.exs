defmodule Membrane.Protocol.Icecast.Input.MachineTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine

  @test_port 1237

  defmodule Recorder do

    @receive_timeout 1000

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
      after
        @receive_timeout ->
          :timeout_in_recorder
      end
    end

    def flush(0) do
      :ok
    end
    def flush(n) do
      receive do
        _ -> flush(n - 1)
      after
        100 -> :ok
      end
    end

    def flush() do
      receive do
        _ -> flush(:all)
      after
        100 -> :ok
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

      def handle_init(arg) do
        Recorder.push({:handle_init, arg})
        {:ok, arg}
      end

      def handle_incoming(remote_address, controller_state) do
        Recorder.push({:handle_incoming, remote_address, controller_state})
        case controller_state do
          %{raise_handle_incoming: e} -> raise e
          _ -> :ok
        end
        case controller_state do
          %{let_in?: {false, code}} ->
            {:ok, {:deny, code}}
          %{let_in?: true} ->
            {:ok, {:allow, controller_state}}
        end
      end

    end

    setup %{listen_socket: ls} do
      {:ok, _recorder} = Recorder.start_link(self())
      {:ok, conn} = :gen_tcp.connect({127, 0, 0, 1}, @test_port, [active: false])
      :inet.setopts(conn, [packet: :http])
      {:ok, socket} = :gen_tcp.accept(ls)

      on_exit fn ->
        :gen_tcp.close(conn)
        :gen_tcp.close(socket)
        Recorder.flush()
      end

      %{socket: socket, conn: conn}
    end

    test "handle_init/1 is being called with argument that was passed to the Machine.init/1", %{socket: socket} do
      argument = %{let_in?: true}
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

      assert Recorder.get() == {:handle_init, argument}
    end

    test "handle_incoming/2 is called right after handle_init/1", %{socket: socket} do
      argument = %{let_in?: true}
      state = argument
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

      {:handle_init, _} = Recorder.get()
      {:ok, address} = :inet.peername(socket)
      assert Recorder.get() == {:handle_incoming, address, state}
    end

    test "handle_incoming/2 can decide not to let the connection in", %{socket: socket, conn: conn} do
      argument = %{let_in?: {false, :forbidden}}
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

      resp = :gen_tcp.recv(conn, 0)
      assert {:ok, {:http_response, _, 403, 'Forbidden'}} = resp
    end

    test "machine exits and connection is closed if handle_incoming/2 raises", %{socket: socket, conn: conn} do
      :erlang.process_flag(:trap_exit, true)
      argument = %{raise_handle_incoming: "some runtime error"}

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

      Recorder.flush(2)
      # TODO Why we get :normal from machine? As (<0.194.0>) exception_from {gen_statem,init_it,6} {error,{case_clause,#{}}}
      # This should be called: https://github.com/erlang/otp/blob/master/lib/stdlib/src/gen_statem.erl#L723
      # and end the process of gen_statem sending EXIT signal to test process with reason `{case_clause, %{}}` (?)

      assert {:EXIT, ^socket, :normal} = Recorder.get() # machine will close the socket first
      assert {:EXIT, ^machine, :normal} = Recorder.get() # and then shut down itself

      # Client connection get 500 and closes
      assert {:ok, {:http_response, _, 500, 'Internal Server Error'}} = :gen_tcp.recv(conn, 0)
      assert {:ok, {:http_header, _, :Connection, _, 'close'}} = :gen_tcp.recv(conn, 0)

    end

  end
end

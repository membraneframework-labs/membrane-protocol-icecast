defmodule Membrane.Protocol.Icecast.Input.MachineTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine

  defmodule Users do
    def authorized_user, do: "Juliet"
    def unauthorized_user, do: "Romeo"
  end


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
        _ ->
          flush()
      after
        100 -> :ok
      end
    end
  end

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

    def handle_source(address, method, format, mount, user, pass, headers, state) do
      Recorder.push({:handle_source, address, method, format, mount, user, pass, headers, state})
      if user == Users.authorized_user() do
        {:ok, {:allow, state}}
      else
        {:ok, {:deny, :unauthorized}}
      end
    end

  end


  setup_all do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary])

    on_exit fn ->
      :gen_tcp.close(listen_socket)
    end

    %{listen_socket: listen_socket}
  end


  describe "Machine initialization" do

    setup %{listen_socket: ls} do
      {:ok, _recorder} = Recorder.start_link(self())
      {:ok, listen_port} = :inet.port(ls)
      {:ok, conn} = :gen_tcp.connect({127, 0, 0, 1}, listen_port, [active: false])
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
      _machine =
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
      _machine =
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
      _machine =
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

      assert {:EXIT, ^socket, :normal} = wait_for_EXIT() # machine will close the socket first
      assert {:EXIT, ^machine, :normal} = wait_for_EXIT() # and then shut down itself

      # Client connection get 500 and closes
      assert {:ok, {:http_response, _, 500, 'Internal Server Error'}} = :gen_tcp.recv(conn, 0)
      assert {:ok, {:http_header, _, :Connection, _, 'close'}} = :gen_tcp.recv(conn, 0)

    end


  end

  describe "Client requests" do
    alias Mint.HTTP1

    setup %{listen_socket: ls} do
      {:ok, _recorder} = Recorder.start_link(self())
      {:ok, listen_port} = :inet.port(ls)
      {:ok, conn} = HTTP1.connect(:http, "localhost", listen_port)
      {:ok, socket} = :gen_tcp.accept(ls)

      #:erlang.process_flag(:trap_exit, true)
      argument = %{let_in?: true}

      machine =
        :proc_lib.spawn_link(Machine, :init,
          [
            {socket,
              :gen_tcp,
              TestController,
              argument,
              [:put, :source],
              [:mp3, :ogg],
              "Some Server",
              10000,
              10000
            }
          ]
        )
      # because we spawn machine in a different process (with proc_lib) than the socket is created in.
      :ok = :gen_tcp.controlling_process(socket, machine)
      # We flush all init messages
      Recorder.flush()

      on_exit fn ->
        HTTP1.close(conn)
        :gen_tcp.close(socket)
        Recorder.flush()
      end

      %{socket: socket, conn: conn}
    end

    test "machine accepts SOURCE method and downgrades HTTP version to 1.0", %{conn: conn} do
      basic_auth = encode_user_pass(Users.authorized_user, "i<3Romeo")

      # TODO Source requres 1.0 and PUT 1.1 ??? Was this intentional in Mechine module code?
      # The original icecast accepts 1.1 for sure as well.
      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, conn, responses} = HTTP1.stream(conn, tcp_msg)
      %HTTP1{request: %{version: http_resp_version}} = conn

      assert http_resp_version == {1, 0}
      assert {:status, req_ref, 200} == responses |> List.keyfind(:status, 0)
    end

    test "machine accepts PUT method and downgrades HTTP version to 1.0", %{conn: conn} do
      basic_auth = encode_user_pass(Users.authorized_user, "i<3romeo")

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "PUT", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, conn, responses} = HTTP1.stream(conn, tcp_msg)
      %HTTP1{request: %{version: http_resp_version}} = conn

      assert http_resp_version == {1, 0}
      assert {:status, req_ref, 200} == responses |> List.keyfind(:status, 0)
    end


    test "machine returns 405 upon receiving unkown method request", %{conn: conn} do
      basic_auth = encode_user_pass(Users.authorized_user, "i<3romeo")

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "POST", "/my_mountpoint", [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 400} == responses |> List.keyfind(:status, 0)
    end

    test "Content-Type header is not mandatory", %{conn: conn} do
      basic_auth = encode_user_pass(Users.authorized_user, "i<3romeo")

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 200} == responses |> List.keyfind(:status, 0)
    end

    test "Lack of Authorization header results in 401", %{conn: conn} do
      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 401} == responses |> List.keyfind(:status, 0)
    end

    test "Improper encoding of user and password results in 401", %{conn: conn} do
      basic_auth = "wrongencoding"

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 401} == responses |> List.keyfind(:status, 0)
    end

    test "handle_source/8 is called with metadata about the connection", %{socket: socket, conn: conn} do
      user = Users.authorized_user
      pass = "i<3romeo"
      basic_auth = encode_user_pass(user, pass)
      content_type = "audio/ogg"

      {:ok, _conn, _req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}, {"Content-Type", content_type}], "")

      conn |> wait_for_tcp()

      {:ok, remote_addr} = :inet.peername(socket)

      assert {:handle_source, ^remote_addr, :source, :ogg, "/my_mountpoint", ^user, ^pass, headers, _state} =
        Recorder.get()

      assert auth_header = List.keyfind(headers, :Authorization, 0)
      assert auth_header == {:Authorization, basic_auth}

      assert content_type_header = List.keyfind(headers, :"Content-Type", 0)
      assert content_type_header == {:"Content-Type", content_type}
    end

    test "handle_source/8 will get the default format (mp3) if not specified", %{conn: conn} do
      basic_auth = encode_user_pass(Users.authorized_user, "i<3romeo")
      default_format = :mp3

      {:ok, conn, _req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      conn |> wait_for_tcp()

      assert {:handle_source, _, _, ^default_format, _, _, _, _, _} =
        Recorder.get()
    end

    test "handle_source/8 can deny the connection", %{conn: conn} do
      basic_auth = encode_user_pass(Users.unauthorized_user, "i<3juliet")

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:handle_source, _, _, _, _, _, _, _, _} = Recorder.get()

      assert {:status, req_ref, 401} == responses |> List.keyfind(:status, 0)
    end

  end

  defp encode_user_pass(user, pass) do
    plain = "#{user}:#{pass}"
    "Basic #{Base.encode64(plain)}"
  end

  defp wait_for_EXIT do
    receive do
      {:EXIT, _, _} = e -> e
    end
  end

  defp wait_for_tcp(%Mint.HTTP1{socket: socket}) do
    wait_for_tcp(socket)
  end
  defp wait_for_tcp(socket) do
    receive do
      {:tcp, ^socket, _} = e -> e
    end
  end

  
end

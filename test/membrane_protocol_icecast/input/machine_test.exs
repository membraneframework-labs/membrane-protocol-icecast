defmodule Membrane.Protocol.Icecast.Input.MachineTest do
  use ExUnit.Case, async: true
  alias Membrane.Protocol.Icecast.Input.Machine
  alias Membrane.Protocol.Icecast.Utils.Recorder

  @receive_timeout 1000
  @body_timeout 300

  defmodule TestControllerUtils do
    def authorized_user, do: "Juliet"

    def unauthorized_user, do: "Romeo"

    def end_payload, do: "For never was a story of more woe, Than this of Juliet and her Romeo."
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
        %{return_error: e} ->
          {:error, e}

        %{let_in?: {false, code}} ->
          {:ok, {:deny, code}}

        %{let_in?: true} ->
          {:ok, {:allow, controller_state}}
      end
    end

    def handle_source(address, method, state, %{
          format: format,
          mount: mount,
          username: user,
          password: pass,
          headers: headers
        }) do
      Recorder.push({:handle_source, address, method, format, mount, user, pass, headers, state})

      if user == TestControllerUtils.authorized_user() do
        {:ok, {:allow, state}}
      else
        {:ok, {:deny, :unauthorized}}
      end
    end

    def handle_payload(address, payload, state) do
      Recorder.push({:handle_payload, address, payload, state})

      case payload == TestControllerUtils.end_payload() do
        true -> {:ok, :drop}
        false -> {:ok, {:continue, state}}
      end
    end

    def handle_invalid(address, reason, state) do
      Recorder.push({:handle_invalid, address, reason, state})
      :ok
    end

    def handle_timeout(address, state) do
      Recorder.push({:handle_timeout, address, state})
      :ok
    end

    def handle_closed(address, state) do
      Recorder.push({:handle_closed, address, state})
      :ok
    end
  end

  setup_all do
    {:ok, listen_socket} = :gen_tcp.listen(0, [:binary])

    on_exit(fn ->
      :gen_tcp.close(listen_socket)
    end)

    %{listen_socket: listen_socket}
  end

  describe "Machine initialization" do
    setup %{listen_socket: ls} do
      {:ok, _recorder} = Recorder.start_link(self())
      {:ok, listen_port} = :inet.port(ls)
      {:ok, conn} = :gen_tcp.connect({127, 0, 0, 1}, listen_port, active: false)
      :inet.setopts(conn, packet: :http)
      {:ok, socket} = :gen_tcp.accept(ls)

      on_exit(fn ->
        :gen_tcp.close(conn)
        :gen_tcp.close(socket)
        Recorder.flush()
      end)

      %{socket: socket, conn: conn}
    end

    test "handle_init/1 is being called with argument that was passed to the Machine.init/1", %{
      socket: socket
    } do
      argument = %{let_in?: true}

      _machine =
        :proc_lib.spawn_link(:gen_statem, :start_link, [
          Machine,
          init_parameter(socket, argument),
          []
        ])

      assert Recorder.get() == {:handle_init, argument}
    end

    test "handle_incoming/2 is called right after handle_init/1", %{socket: socket} do
      argument = %{let_in?: true}
      state = argument

      _machine =
        :proc_lib.spawn_link(:gen_statem, :start_link, [
          Machine,
          init_parameter(socket, argument),
          []
        ])

      {:handle_init, _} = Recorder.get()
      {:ok, address} = :inet.peername(socket)
      assert Recorder.get() == {:handle_incoming, address, state}
    end

    test "handle_incoming/2 can decide not to let the connection in", %{
      socket: socket,
      conn: conn
    } do
      argument = %{let_in?: {false, :forbidden}}

      _machine =
        :proc_lib.spawn_link(:gen_statem, :start_link, [
          Machine,
          init_parameter(socket, argument),
          []
        ])

      resp = :gen_tcp.recv(conn, 0)
      assert {:ok, {:http_response, _, 403, 'Forbidden'}} = resp
    end

    test "machine exits and connection is closed if handle_incoming/2 returns error", %{
      socket: socket,
      conn: conn
    } do
      :erlang.process_flag(:trap_exit, true)
      argument = %{return_error: "some error"}

      machine =
        :proc_lib.spawn_link(:gen_statem, :start_link, [
          Machine,
          init_parameter(socket, argument),
          []
        ])

      Recorder.flush(2)

      # TODO Why we get :normal from machine? As (<0.194.0>) exception_from {gen_statem,init_it,6} {error,{case_clause,#{}}}
      # This should be called: https://github.com/erlang/otp/blob/master/lib/stdlib/src/gen_statem.erl#L723
      # and end the process of gen_statem sending EXIT signal to test process with reason `{case_clause, %{}}` (?)

      # machine will close the socket first
      assert :normal = wait_for_EXIT(socket)
      # and then shut down itself
      assert :normal = wait_for_EXIT(machine)

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
      # As we want to get tcp even after getting reponse
      conn |> HTTP1.get_socket() |> :inet.setopts(active: true)
      {:ok, socket} = :gen_tcp.accept(ls)

      argument = %{let_in?: true}

      machine =
        :proc_lib.spawn_link(Machine, :init, [
          init_parameter(socket, argument, 300, [:mp3, :ogg])
        ])

      # because we spawn machine in a different process (with proc_lib) than the socket is created in.
      :ok = :gen_tcp.controlling_process(socket, machine)
      # We flush all init messages
      Recorder.flush()

      on_exit(fn ->
        HTTP1.close(conn)
        :gen_tcp.close(socket)
        Recorder.flush()
      end)

      %{machine: machine, conn: conn}
    end

    test "machine accepts SOURCE method and downgrades HTTP version to 1.0", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.authorized_user(), "i<3Romeo")

      # TODO Source requres 1.0 and PUT 1.1 ??? Was this intentional in Mechine module code?
      # The original icecast accepts 1.1 for sure as well.
      {:ok, conn, req_ref} =
        HTTP1.request(
          conn,
          "SOURCE",
          "/my_mountpoint",
          [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}],
          ""
        )

      tcp_msg = conn |> wait_for_tcp()
      {:ok, conn, responses} = HTTP1.stream(conn, tcp_msg)
      %HTTP1{request: %{version: http_resp_version}} = conn

      assert http_resp_version == {1, 0}
      assert {:status, req_ref, 200} == responses |> List.keyfind(:status, 0)
    end

    test "machine accepts PUT method and downgrades HTTP version to 1.0", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.authorized_user(), "i<3romeo")

      {:ok, conn, req_ref} =
        HTTP1.request(
          conn,
          "PUT",
          "/my_mountpoint",
          [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}],
          ""
        )

      tcp_msg = conn |> wait_for_tcp()
      {:ok, conn, responses} = HTTP1.stream(conn, tcp_msg)
      %HTTP1{request: %{version: http_resp_version}} = conn

      assert http_resp_version == {1, 0}
      assert {:status, req_ref, 200} == responses |> List.keyfind(:status, 0)
    end

    test "machine returns 405 upon receiving unkown method request", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.authorized_user(), "i<3romeo")

      {:ok, conn, req_ref} =
        HTTP1.request(
          conn,
          "POST",
          "/my_mountpoint",
          [{"Content-Type", "audio/mpeg"}, {"Authorization", basic_auth}],
          ""
        )

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 400} == responses |> List.keyfind(:status, 0)
    end

    test "Content-Type header is not mandatory", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.authorized_user(), "i<3romeo")

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 200} == responses |> List.keyfind(:status, 0)
    end

    test "Lack of Authorization header results in 401", %{conn: conn} do
      {:ok, conn, req_ref} = HTTP1.request(conn, "SOURCE", "/my_mountpoint", [], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:status, req_ref, 401} == responses |> List.keyfind(:status, 0)
    end

    test "Improper encoding of user and password results in 401 and handle_invalid/3 being called",
         %{machine: machine, conn: conn} do
      :erlang.process_flag(:trap_exit, true)
      basic_auth = "wrongencoding"

      {:ok, remote_addr} = conn |> HTTP1.get_socket() |> :inet.sockname()

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:handle_invalid, ^remote_addr, unauthorized, _state} = Recorder.get()
      assert {:status, req_ref, 401} == responses |> List.keyfind(:status, 0)
      assert Recorder.no_messages?()
      assert :normal == wait_for_EXIT(machine)
    end

    test "handle_source/8 is called with metadata about the connection", %{conn: conn} do
      user = TestControllerUtils.authorized_user()
      pass = "i<3romeo"
      basic_auth = encode_user_pass(user, pass)
      content_type = "audio/ogg"

      {:ok, _conn, _req_ref} =
        HTTP1.request(
          conn,
          "SOURCE",
          "/my_mountpoint",
          [{"Authorization", basic_auth}, {"Content-Type", content_type}],
          ""
        )

      conn |> wait_for_tcp()

      {:ok, remote_addr} = conn |> HTTP1.get_socket() |> :inet.sockname()

      assert {:handle_source, ^remote_addr, :source, :ogg, "/my_mountpoint", ^user, ^pass,
              headers, _state} = Recorder.get()

      assert auth_header = List.keyfind(headers, :Authorization, 0)
      assert auth_header == {:Authorization, basic_auth}

      assert content_type_header = List.keyfind(headers, :"Content-Type", 0)
      assert content_type_header == {:"Content-Type", content_type}
    end

    test "handle_source/8 will get the default format (mp3) if not specified", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.authorized_user(), "i<3romeo")
      default_format = :mp3

      {:ok, conn, _req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      conn |> wait_for_tcp()

      assert {:handle_source, _, _, ^default_format, _, _, _, _, _} = Recorder.get()
    end

    test "Default format is taken when unknown format is provided", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.authorized_user(), "i<3romeo")
      default_format = :mp3

      {:ok, conn, _req_ref} =
        HTTP1.request(
          conn,
          "SOURCE",
          "/my_mountpoint",
          [{"Authorization", basic_auth}, {"Content-Type", "some-unknown-format"}],
          ""
        )

      conn |> wait_for_tcp()

      assert {:handle_source, _, _, ^default_format, _, _, _, _, _} = Recorder.get()
    end

    test "handle_source/8 can deny the connection", %{conn: conn} do
      basic_auth = encode_user_pass(TestControllerUtils.unauthorized_user(), "i<3juliet")

      {:ok, conn, req_ref} =
        HTTP1.request(conn, "SOURCE", "/my_mountpoint", [{"Authorization", basic_auth}], "")

      tcp_msg = conn |> wait_for_tcp()
      {:ok, _conn, responses} = HTTP1.stream(conn, tcp_msg)

      assert {:handle_source, _, _, _, _, _, _, _, _} = Recorder.get()
      assert {:status, req_ref, 401} == responses |> List.keyfind(:status, 0)
    end

    test "handle_closed/2 is called when client closes the connection", %{conn: conn} do
      user = TestControllerUtils.authorized_user()
      pass = "i<3romeo"
      basic_auth = encode_user_pass(user, pass)
      content_type = "audio/ogg"

      {:ok, _conn, _req_ref} =
        HTTP1.request(
          conn,
          "SOURCE",
          "/my_mountpoint",
          [{"Authorization", basic_auth}, {"Content-Type", content_type}],
          ""
        )

      conn |> wait_for_tcp()

      {:ok, remote_addr} = conn |> HTTP1.get_socket() |> :inet.sockname()
      # lushing handle_source
      Recorder.flush(1)
      {:ok, _} = HTTP1.close(conn)

      assert {:handle_closed, ^remote_addr, _state} = Recorder.get()
    end

    test "handle_payload/2 is called when client sends data", %{conn: conn, machine: machine} do
      :erlang.process_flag(:trap_exit, true)
      user = TestControllerUtils.authorized_user()
      pass = "i<3romeo"
      basic_auth = encode_user_pass(user, pass)
      content_type = "audio/mpeg"

      {:ok, _conn, _req_ref} =
        HTTP1.request(
          conn,
          "SOURCE",
          "/my_mountpoint",
          [{"Authorization", basic_auth}, {"Content-Type", content_type}],
          ""
        )

      conn |> wait_for_tcp()

      # handle_source
      Recorder.flush(1)

      payload = "These violent delights have violent ends
                 And in their triump die, like fire and powder
                 Which, as they kiss, consume"

      {:ok, remote_addr} = conn |> HTTP1.get_socket() |> :inet.sockname()

      conn
      |> HTTP1.get_socket()
      |> :gen_tcp.send(payload)

      assert {:handle_payload, ^remote_addr, ^payload, _state} = Recorder.get()

      end_payload = TestControllerUtils.end_payload()

      conn
      |> HTTP1.get_socket()
      |> :gen_tcp.send(end_payload)

      assert {:handle_payload, ^remote_addr, ^end_payload, _state} = Recorder.get()

      assert :ok = wait_for_tcp_close(conn)
      assert :normal = wait_for_EXIT(machine)
    end

    test "handle_timeout/2 is called client does not send any payload", %{
      conn: conn,
      machine: machine
    } do
      :erlang.process_flag(:trap_exit, true)
      user = TestControllerUtils.authorized_user()
      pass = "i<3romeo"
      basic_auth = encode_user_pass(user, pass)
      content_type = "audio/mpeg"

      {:ok, _conn, _req_ref} =
        HTTP1.request(
          conn,
          "SOURCE",
          "/my_mountpoint",
          [{"Authorization", basic_auth}, {"Content-Type", content_type}],
          ""
        )

      conn |> wait_for_tcp()

      # handle_source
      Recorder.flush(1)

      payload = "These violent delights have violent ends
                 And in their triump die, like fire and powder
                 Which, as they kiss, consume"

      {:ok, remote_addr} = conn |> HTTP1.get_socket() |> :inet.sockname()

      conn
      |> HTTP1.get_socket()
      |> :gen_tcp.send(payload)

      assert {:handle_payload, ^remote_addr, ^payload, _state} = Recorder.get()

      :timer.sleep(@body_timeout)

      assert {:handle_timeout, ^remote_addr, _state} = Recorder.get()
      assert :ok = wait_for_tcp_close(conn)
      assert :normal = wait_for_EXIT(machine)
    end
  end

  defp encode_user_pass(user, pass) do
    plain = "#{user}:#{pass}"
    "Basic #{Base.encode64(plain)}"
  end

  defp wait_for_EXIT(source) do
    receive do
      {:EXIT, ^source, reason} -> reason
    after
      @receive_timeout -> {:error, :timeout_waiting_for_EXIT}
    end
  end

  defp wait_for_tcp(%Mint.HTTP1{socket: socket}) do
    wait_for_tcp(socket)
  end

  defp wait_for_tcp(socket) do
    receive do
      {:tcp, ^socket, _} = e -> e
    after
      @receive_timeout -> {:error, :timeout_when_waiting_for_tcp}
    end
  end

  defp wait_for_tcp_close(%Mint.HTTP1{socket: socket}) do
    wait_for_tcp_close(socket)
  end

  defp wait_for_tcp_close(socket) do
    receive do
      {:tcp_closed, ^socket} -> :ok
    after
      @receive_timeout -> {:error, :timeout_when_waiting_for_tcp_close}
    end
  end

  defp init_parameter(
         socket,
         controller_argument,
         request_timeout \\ 1000,
         allowed_foramts \\ [:mp3]
       ) do
    %{
      socket: socket,
      transport: :gen_tcp,
      controller_module: TestController,
      controller_arg: controller_argument,
      allowed_methods: [:put, :source],
      allowed_formats: allowed_foramts,
      server_string: "Some Server",
      request_timeout: request_timeout,
      body_timeout: @body_timeout
    }
  end
end

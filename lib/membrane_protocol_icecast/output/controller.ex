defmodule Membrane.Protocol.Icecast.Output.Controller do
  alias Membrane.Protocol.Icecast.Types

  @type t :: module()

  @type state_t :: any

  @type invalid_reason_t ::
          {:request, {:request, any} | {:header, binary}}
          | {:method, atom | charlist}
          | {:mount, binary}
          | :format_unknown
          | :format_not_allowed
          | :request
          | :too_many_headers
          | :unauthorized
  # FIXME method -> method_*

  @type incoming_reply_t :: {:ok, {:allow, any} | {:deny, :forbidden}}
  @type listener_reply_t ::
          {:ok, {:allow, any}, Types.format_t()} | {:ok, {:deny, :forbidden, :not_found}}

  # Initial actions
  @callback handle_init(any) :: {:ok, state_t}

  # Connecting actions
  @callback handle_incoming(Types.remote_address_t(), state_t) :: incoming_reply_t
  @callback handle_listener(Types.remote_address_t(), Types.mount_t(), Types.headers_t(), state_t) ::
              listener_reply_t

  # Terminal actions
  @callback handle_closed(Types.remote_address_t(), state_t) :: :ok
  @callback handle_timeout(Types.remote_address_t(), state_t) :: :ok
  @callback handle_invalid(Types.remote_address_t(), invalid_reason_t, state_t) :: :ok

  defmacro __using__(_) do
    quote do
      @behaviour Membrane.Protocol.Icecast.Output.Controller
    end
  end
end

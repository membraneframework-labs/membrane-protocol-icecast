defmodule Membrane.Protocol.Icecast.Input.Controller do
  alias Membrane.Protocol.Icecast.Types

  @type state_t :: any

  @type payload_t :: binary
  @type invalid_reason_t ::
    {:request, {:request, any} | {:header, binary}} |
    {:method, atom | charlist} |
    {:mount, binary} |
    :format_unknown |
    :format_not_allowed |
    :request |
    :too_many_headers |
    :unauthorized
    # FIXME method -> method_*

  @type incoming_reply_t :: {:ok, {:allow, any} | {:deny, :forbidden}}
  @type source_reply_t :: {:ok, {:allow, any} | {:deny, :unauthorized | :forbidden}}

  @type payload_reply_t :: {:ok, {:continue, any} | :drop}
  @type metadata_reply_t :: {:ok, {:continue, any} | :drop}

  # Initial actions
  @callback handle_init(any) :: {:ok, state_t}

  # Connecting actions
  @callback handle_incoming(Types.remote_address_t, state_t) :: incoming_reply_t
  @callback handle_source(Types.remote_address_t, Types.method_t, Types.format_t, Types.mount_t, String.t, String.t, Types.headers_t, state_t) :: source_reply_t # TODO add SSL & metadata info

  # Ongoing actions
  @callback handle_payload(Types.remote_address_t, payload_t, state_t) :: payload_reply_t
  @callback handle_metadata(Types.remote_address_t, Types.metadata_t, state_t) :: metadata_reply_t

  # Terminal actions
  @callback handle_closed(Types.remote_address_t, state_t) :: :ok
  @callback handle_timeout(Types.remote_address_t, state_t) :: :ok
  @callback handle_invalid(Types.remote_address_t, invalid_reason_t, state_t) :: :ok

  defmacro __using__(_) do
    quote do
      @behaviour Membrane.Protocol.Icecast.Input.Controller

      # Default implementations

      @doc false
      def handle_incoming(_remote_address, state) do
        {:ok, {:allow, state}}
      end


    end
  end
end

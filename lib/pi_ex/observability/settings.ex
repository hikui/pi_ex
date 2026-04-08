defmodule PiEx.Observability.Settings do
  @moduledoc """
  Runtime settings controlling `pi_ex` OpenTelemetry instrumentation.
  """

  @enforce_keys []
  defstruct enabled: false,
            capture_sensitive_data: false,
            conversation_id: nil,
            agent_name: nil,
            agent_description: nil,
            agent_id: nil,
            agent_version: nil

  @type t :: %__MODULE__{
          enabled: boolean(),
          capture_sensitive_data: boolean(),
          conversation_id: String.t() | nil,
          agent_name: String.t() | nil,
          agent_description: String.t() | nil,
          agent_id: String.t() | nil,
          agent_version: String.t() | nil
        }
end

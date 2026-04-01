defmodule PiEx.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  ## Required fields
  - `:model` — `%PiEx.AI.Model{}` to use for completions
  - `:system_prompt` — system prompt string

  ## Optional fields
  - `:tools` — list of `%PiEx.Agent.Tool{}`; default `[]`

  ## Hooks (all optional)
  - `:before_tool_call` — `(call_id, tool_name, args) -> :ok | {:block, reason_string}`
    Called before executing a tool. Return `{:block, reason}` to abort the call with an error result.
  - `:after_tool_call` — `(call_id, tool_name, result) -> result`
    Called after a tool executes. May return a modified result map.
  - `:get_steering_messages` — `() -> [Message.t()]`
    Polled after each turn. Returned messages are injected before the next LLM call.
  - `:get_follow_up_messages` — `() -> [Message.t()]`
    Polled when the agent would otherwise stop. Returned messages restart the loop.
  - `:transform_context` — `(context) -> context`
    Called just before each LLM call. Use for pruning or injecting context.
  - `:convert_to_llm` — `([AgentMessage.t()]) -> [Message.t()]`
    Converts the agent message list to LLM-level messages. Default: identity.

  ## Compaction (optional)
  - `:compaction` — `%PiEx.Agent.Compaction.Settings{}` to enable auto compaction; `nil` disables it (default).
    Requires `:model` to have a `context_window` set.
  - `:compact_fn` — override the compaction implementation. Receives `(messages, model, settings, api_key)`
    and must return `{:ok, new_messages}` or `{:error, reason}`. Useful for testing without real API calls.
  """

  alias PiEx.AI.Model

  @enforce_keys [:model]
  defstruct [
    :model,
    :system_prompt,
    tools: [],
    before_tool_call: nil,
    after_tool_call: nil,
    get_steering_messages: nil,
    get_follow_up_messages: nil,
    transform_context: nil,
    convert_to_llm: nil,
    stream_fn: nil,
    compaction: nil,
    compact_fn: nil
  ]

  @type t :: %__MODULE__{
          model: Model.t(),
          system_prompt: String.t() | nil,
          tools: [PiEx.Agent.Tool.t()],
          before_tool_call: (String.t(), String.t(), map() -> :ok | {:block, String.t()}) | nil,
          after_tool_call: (String.t(), String.t(), map() -> map()) | nil,
          get_steering_messages: (-> [PiEx.AI.Message.t()]) | nil,
          get_follow_up_messages: (-> [PiEx.AI.Message.t()]) | nil,
          transform_context: (PiEx.AI.Context.t() -> PiEx.AI.Context.t()) | nil,
          convert_to_llm: ([PiEx.AI.Message.t()] -> [PiEx.AI.Message.t()]) | nil,
          stream_fn: (PiEx.AI.Model.t(), PiEx.AI.Context.t(), keyword() -> Enumerable.t()) | nil,
          compaction: PiEx.Agent.Compaction.Settings.t() | nil,
          compact_fn:
            ([PiEx.AI.Message.t()],
             PiEx.AI.Model.t(),
             PiEx.Agent.Compaction.Settings.t(),
             String.t()
             | nil ->
               {:ok, [PiEx.AI.Message.t()]} | {:error, term()})
            | nil
        }
end

defmodule PiEx.Agent.Config do
  @moduledoc """
  Configuration for an agent run.

  ## Required fields
  - `:model` — `%PiEx.AI.Model{}` to use for completions

  ## Optional fields
  - `:system_prompt` — system prompt string
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

  ## Subagent support
  - `:depth` — current nesting depth; 0 for main agents. Set automatically by the `run_agent` tool.
  - `:max_depth` — maximum allowed nesting depth; `nil` = unlimited. When `depth < max_depth` (or
    `max_depth` is `nil`), the `run_agent` tool is automatically injected into `:tools`.
  - `:parent_pid` — pid of the parent `Agent.Server`, if this agent was spawned as a subagent.
  - `:subagents` — inline `%PiEx.SubAgent.Definition{}` list. Checked before `PiEx.SubAgent.Registry`
    when resolving a named agent in `run_agent`.

  ## Observability (optional)
  - `:observability` — `%PiEx.Observability.Settings{}` or keyword/map overrides merged with
    `config :pi_ex, :observability, ...`
  """

  alias PiEx.AI.Model
  alias PiEx.Observability.Settings

  @enforce_keys [:model]
  defstruct [
    :model,
    :system_prompt,
    :parent_pid,
    tools: [],
    before_tool_call: nil,
    after_tool_call: nil,
    get_steering_messages: nil,
    get_follow_up_messages: nil,
    transform_context: nil,
    convert_to_llm: nil,
    stream_fn: nil,
    compaction: nil,
    compact_fn: nil,
    observability: nil,
    depth: 0,
    max_depth: nil,
    subagents: []
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
            | nil,
          observability: Settings.t() | map() | keyword() | nil,
          depth: non_neg_integer(),
          max_depth: non_neg_integer() | nil,
          parent_pid: pid() | nil,
          subagents: [PiEx.SubAgent.Definition.t()]
        }
end

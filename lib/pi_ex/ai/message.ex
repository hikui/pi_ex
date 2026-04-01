defmodule PiEx.AI.Message do
  @moduledoc """
  Message types exchanged in a conversation.
  """

  alias PiEx.AI.Content

  defmodule UserMessage do
    @moduledoc "A message from the user."
    @enforce_keys [:content, :timestamp]
    defstruct [:content, :timestamp]

    @type t :: %__MODULE__{
            content: String.t() | [Content.user_block()],
            timestamp: integer()
          }
  end

  defmodule Usage do
    @moduledoc "Token usage for an assistant turn."
    defstruct input_tokens: 0, output_tokens: 0

    @type t :: %__MODULE__{input_tokens: non_neg_integer(), output_tokens: non_neg_integer()}
  end

  defmodule AssistantMessage do
    @moduledoc "A response from the model."
    @enforce_keys [:content, :model, :usage, :stop_reason, :timestamp]
    defstruct [:content, :model, :usage, :stop_reason, :timestamp, :error_message]

    @type stop_reason :: :stop | :length | :tool_use | :error | :aborted
    @type t :: %__MODULE__{
            content: [Content.assistant_block()],
            model: String.t(),
            usage: Usage.t(),
            stop_reason: stop_reason(),
            timestamp: integer(),
            error_message: String.t() | nil
          }
  end

  defmodule ToolResultMessage do
    @moduledoc "The result of a tool call, sent back to the model."
    @enforce_keys [:tool_call_id, :tool_name, :content, :is_error, :timestamp]
    defstruct [:tool_call_id, :tool_name, :content, :is_error, :timestamp, :details]

    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            tool_name: String.t(),
            content: [Content.tool_result_block()],
            is_error: boolean(),
            timestamp: integer(),
            details: term()
          }
  end

  defmodule CompactionSummaryMessage do
    @moduledoc "A synthetic message injected after compaction, summarizing prior context."
    @enforce_keys [:summary, :tokens_before, :timestamp]
    defstruct [:summary, :tokens_before, :timestamp]

    @type t :: %__MODULE__{
            summary: String.t(),
            tokens_before: non_neg_integer(),
            timestamp: integer()
          }
  end

  @type t :: UserMessage.t() | AssistantMessage.t() | ToolResultMessage.t() | CompactionSummaryMessage.t()

  @doc "Build a UserMessage with the current timestamp."
  @spec user(String.t() | [Content.user_block()]) :: UserMessage.t()
  def user(content) do
    %UserMessage{content: content, timestamp: System.system_time(:millisecond)}
  end
end

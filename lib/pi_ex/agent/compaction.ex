defmodule PiEx.Agent.Compaction do
  @moduledoc """
  Auto context compaction for long-running agents.

  When the context token count approaches the model's context window limit,
  compaction summarizes older history with an LLM call and replaces it with a
  `CompactionSummaryMessage`, allowing the agent to run indefinitely.

  ## Usage

  Enable by setting `compaction: %PiEx.Agent.Compaction.Settings{}` in `PiEx.Agent.Config`
  and setting `context_window` on the `PiEx.AI.Model`.
  """

  alias PiEx.AI.{Model, Context}
  alias PiEx.AI.Message.{UserMessage, AssistantMessage, ToolResultMessage, CompactionSummaryMessage}
  alias PiEx.AI.Content.{TextContent, ThinkingContent, ToolCall}

  defmodule Settings do
    @moduledoc "Configuration for auto compaction."
    defstruct enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000

    @type t :: %__MODULE__{
            enabled: boolean(),
            reserve_tokens: pos_integer(),
            keep_recent_tokens: pos_integer()
          }
  end

  # ---------------------------------------------------------------------------
  # Summarization prompts (ported from pi-mono)
  # ---------------------------------------------------------------------------

  @summarization_system_prompt """
  You are a context summarization assistant. Your task is to read a conversation between a user and an AI coding assistant, then produce a structured summary following the exact format specified.

  Do NOT continue the conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary.\
  """

  @summarization_prompt """
  The messages above are a conversation to summarize. Create a structured context checkpoint summary that another LLM will use to continue the work.

  Use this EXACT format:

  ## Goal
  [What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

  ## Constraints & Preferences
  - [Any constraints, preferences, or requirements mentioned by user]
  - [Or "(none)" if none were mentioned]

  ## Progress
  ### Done
  - [x] [Completed tasks/changes]

  ### In Progress
  - [ ] [Current work]

  ### Blocked
  - [Issues preventing progress, if any]

  ## Key Decisions
  - **[Decision]**: [Brief rationale]

  ## Next Steps
  1. [Ordered list of what should happen next]

  ## Critical Context
  - [Any data, examples, or references needed to continue]
  - [Or "(none)" if not applicable]

  Keep each section concise. Preserve exact file paths, function names, and error messages.\
  """

  @update_summarization_prompt """
  The messages above are NEW conversation messages to incorporate into the existing summary provided in <previous-summary> tags.

  Update the existing structured summary with new information. RULES:
  - PRESERVE all existing information from the previous summary
  - ADD new progress, decisions, and context from the new messages
  - UPDATE the Progress section: move items from "In Progress" to "Done" when completed
  - UPDATE "Next Steps" based on what was accomplished
  - PRESERVE exact file paths, function names, and error messages
  - If something is no longer relevant, you may remove it

  Use this EXACT format:

  ## Goal
  [Preserve existing goals, add new ones if the task expanded]

  ## Constraints & Preferences
  - [Preserve existing, add new ones discovered]

  ## Progress
  ### Done
  - [x] [Include previously done items AND newly completed items]

  ### In Progress
  - [ ] [Current work - update based on progress]

  ### Blocked
  - [Current blockers - remove if resolved]

  ## Key Decisions
  - **[Decision]**: [Brief rationale] (preserve all previous, add new)

  ## Next Steps
  1. [Update based on current state]

  ## Critical Context
  - [Preserve important context, add new if needed]

  Keep each section concise. Preserve exact file paths, function names, and error messages.\
  """

  @tool_result_max_chars 2000

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Estimate the token count for a single message using a chars/4 heuristic.
  """
  @spec estimate_tokens(PiEx.AI.Message.t()) :: non_neg_integer()
  def estimate_tokens(%UserMessage{content: content}) when is_binary(content) do
    ceil(String.length(content) / 4)
  end

  def estimate_tokens(%UserMessage{content: blocks}) when is_list(blocks) do
    chars =
      Enum.reduce(blocks, 0, fn
        %TextContent{text: t}, acc -> acc + String.length(t)
        _, acc -> acc
      end)

    ceil(chars / 4)
  end

  def estimate_tokens(%AssistantMessage{content: blocks}) do
    chars =
      Enum.reduce(blocks, 0, fn
        %TextContent{text: t}, acc -> acc + String.length(t)
        %ThinkingContent{thinking: t}, acc -> acc + String.length(t)
        %ToolCall{name: name, arguments: args}, acc -> acc + String.length(name) + String.length(Jason.encode!(args))
        _, acc -> acc
      end)

    ceil(chars / 4)
  end

  def estimate_tokens(%ToolResultMessage{content: blocks}) do
    chars =
      Enum.reduce(blocks, 0, fn
        %TextContent{text: t}, acc -> acc + String.length(t)
        _, acc -> acc
      end)

    ceil(chars / 4)
  end

  def estimate_tokens(%CompactionSummaryMessage{summary: summary}) do
    ceil(String.length(summary) / 4)
  end

  @doc """
  Estimate total context tokens from a message list.

  Uses the last valid AssistantMessage usage (input + output tokens) as an anchor,
  then adds char-estimated tokens for any trailing messages after it.

  Returns `%{tokens: integer, last_usage_index: integer | nil}`.
  """
  @spec estimate_context_tokens([PiEx.AI.Message.t()]) :: %{
          tokens: non_neg_integer(),
          last_usage_index: non_neg_integer() | nil
        }
  def estimate_context_tokens(messages) do
    case find_last_assistant_usage(messages) do
      nil ->
        estimated = messages |> Enum.map(&estimate_tokens/1) |> Enum.sum()
        %{tokens: estimated, last_usage_index: nil}

      {usage_tokens, index} ->
        trailing =
          messages
          |> Enum.drop(index + 1)
          |> Enum.map(&estimate_tokens/1)
          |> Enum.sum()

        %{tokens: usage_tokens + trailing, last_usage_index: index}
    end
  end

  @doc """
  Returns true when compaction should trigger.
  """
  @spec should_compact?(non_neg_integer(), pos_integer(), Settings.t()) :: boolean()
  def should_compact?(_tokens, _context_window, %Settings{enabled: false}), do: false

  def should_compact?(tokens, context_window, %Settings{reserve_tokens: reserve}) do
    tokens > context_window - reserve
  end

  @doc """
  Find the index of the first message to keep, leaving `keep_recent_tokens` worth
  of recent history intact. Never cuts at a `ToolResultMessage`.

  Returns the 0-based index of the first kept message.
  """
  @spec find_cut_point([PiEx.AI.Message.t()], pos_integer()) :: non_neg_integer()
  def find_cut_point(messages, keep_recent_tokens) do
    indexed = messages |> Enum.with_index() |> Enum.reverse()

    {_, cut_index} =
      Enum.reduce_while(indexed, {0, 0}, fn {msg, idx}, {acc_tokens, _cut} ->
        new_tokens = acc_tokens + estimate_tokens(msg)

        if new_tokens >= keep_recent_tokens do
          # Find nearest valid cut at or after this index (not a ToolResultMessage)
          valid_idx = find_valid_cut_from(messages, idx)
          {:halt, {new_tokens, valid_idx}}
        else
          {:cont, {new_tokens, idx}}
        end
      end)

    cut_index
  end

  @doc """
  Serialize messages to plain text for summarization.
  ToolResultMessage content is truncated to #{@tool_result_max_chars} characters.
  """
  @spec serialize_messages([PiEx.AI.Message.t()]) :: String.t()
  def serialize_messages(messages) do
    messages
    |> Enum.flat_map(&serialize_message/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Generate a summary of `messages_to_summarize` using the LLM.

  Options:
  - `:previous_summary` — if set, uses the iterative update prompt
  """
  @spec generate_summary([PiEx.AI.Message.t()], Model.t(), Settings.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def generate_summary(messages_to_summarize, model, settings, api_key, opts \\ []) do
    previous_summary = Keyword.get(opts, :previous_summary)
    max_tokens = floor(0.8 * settings.reserve_tokens)

    base_prompt = if previous_summary, do: @update_summarization_prompt, else: @summarization_prompt
    conversation_text = serialize_messages(messages_to_summarize)

    prompt_text =
      if previous_summary do
        "<conversation>\n#{conversation_text}\n</conversation>\n\n<previous-summary>\n#{previous_summary}\n</previous-summary>\n\n#{base_prompt}"
      else
        "<conversation>\n#{conversation_text}\n</conversation>\n\n#{base_prompt}"
      end

    context = %Context{
      system_prompt: @summarization_system_prompt,
      messages: [%UserMessage{content: prompt_text, timestamp: System.system_time(:millisecond)}],
      tools: []
    }

    api_opts = [max_tokens: max_tokens] ++ if(api_key, do: [api_key: api_key], else: [])

    case PiEx.AI.complete(model, context, api_opts) do
      {:ok, %AssistantMessage{content: content}} ->
        text =
          content
          |> Enum.flat_map(fn
            %TextContent{text: t} -> [t]
            _ -> []
          end)
          |> Enum.join("\n")

        {:ok, text}

      {:error, %AssistantMessage{error_message: reason}} ->
        {:error, reason}
    end
  end

  @doc """
  Compact `messages` by summarizing older history and keeping recent messages.

  Returns `{:ok, new_messages}` where `new_messages` starts with a
  `CompactionSummaryMessage` followed by the kept recent messages.
  """
  @spec compact([PiEx.AI.Message.t()], Model.t(), Settings.t(), String.t() | nil) ::
          {:ok, [PiEx.AI.Message.t()]} | {:error, term()}
  def compact(messages, model, settings, api_key) do
    tokens_before = estimate_context_tokens(messages).tokens
    cut_idx = find_cut_point(messages, settings.keep_recent_tokens)

    messages_to_summarize = Enum.take(messages, cut_idx)
    messages_to_keep = Enum.drop(messages, cut_idx)

    previous_summary = extract_previous_summary(messages_to_summarize)

    with {:ok, summary} <-
           generate_summary(messages_to_summarize, model, settings, api_key,
             previous_summary: previous_summary
           ) do
      summary_msg = %CompactionSummaryMessage{
        summary: summary,
        tokens_before: tokens_before,
        timestamp: System.system_time(:millisecond)
      }

      {:ok, [summary_msg | messages_to_keep]}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp find_last_assistant_usage(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn
      {%AssistantMessage{stop_reason: stop, usage: usage}, idx}
      when stop not in [:aborted, :error] ->
        total = usage.input_tokens + usage.output_tokens
        if total > 0, do: {total, idx}, else: nil

      _ ->
        nil
    end)
  end

  defp find_valid_cut_from(messages, from_idx) do
    messages
    |> Enum.with_index()
    |> Enum.drop(from_idx)
    |> Enum.find_value(from_idx, fn
      {%ToolResultMessage{}, _idx} -> nil
      {_, idx} -> idx
    end)
  end

  defp extract_previous_summary(messages) do
    Enum.find_value(messages, fn
      %CompactionSummaryMessage{summary: s} -> s
      _ -> nil
    end)
  end

  defp serialize_message(%CompactionSummaryMessage{summary: summary}) do
    ["[Context Summary]: #{summary}"]
  end

  defp serialize_message(%UserMessage{content: content}) when is_binary(content) do
    if content != "", do: ["[User]: #{content}"], else: []
  end

  defp serialize_message(%UserMessage{content: blocks}) when is_list(blocks) do
    text =
      blocks
      |> Enum.flat_map(fn
        %TextContent{text: t} -> [t]
        _ -> []
      end)
      |> Enum.join()

    if text != "", do: ["[User]: #{text}"], else: []
  end

  defp serialize_message(%AssistantMessage{content: blocks}) do
    blocks
    |> Enum.flat_map(fn
      %ThinkingContent{thinking: t} -> ["[Assistant thinking]: #{t}"]
      %TextContent{text: t} when t != "" -> ["[Assistant]: #{t}"]
      %ToolCall{name: name, arguments: args} ->
        args_str =
          args
          |> Enum.map(fn {k, v} -> "#{k}=#{Jason.encode!(v)}" end)
          |> Enum.join(", ")

        ["[Assistant tool calls]: #{name}(#{args_str})"]

      _ ->
        []
    end)
  end

  defp serialize_message(%ToolResultMessage{content: blocks}) do
    text =
      blocks
      |> Enum.flat_map(fn
        %TextContent{text: t} -> [t]
        _ -> []
      end)
      |> Enum.join()

    if text != "" do
      truncated = truncate(text, @tool_result_max_chars)
      ["[Tool result]: #{truncated}"]
    else
      []
    end
  end

  defp truncate(text, max_chars) do
    len = String.length(text)

    if len <= max_chars do
      text
    else
      "#{String.slice(text, 0, max_chars)}\n\n[... #{len - max_chars} more characters truncated]"
    end
  end
end

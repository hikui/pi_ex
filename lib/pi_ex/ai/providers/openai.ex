defmodule PiEx.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI chat completions streaming provider.

  Implements `stream/3` which returns a lazy `Stream` of `PiEx.AI.StreamEvent.t()` events.
  The stream never raises; all failures are encoded as `{:error, reason, message}` events.
  """

  alias PiEx.AI.Content.{TextContent, ThinkingContent, ToolCall}
  alias PiEx.AI.Message.{UserMessage, AssistantMessage, ToolResultMessage, CompactionSummaryMessage, Usage}
  alias PiEx.AI.Model
  alias PiEx.AI.Context

  @base_url "https://api.openai.com/v1"

  @doc """
  Returns a lazy stream of `PiEx.AI.StreamEvent.t()` events.

  Options:
  - `:api_key` — overrides `OPENAI_API_KEY` env var
  - `:base_url` — overrides the default OpenAI base URL (useful for OpenAI-compatible proxies like LiteLLM)
  - `:temperature` — float (default: model default)
  - `:max_tokens` — integer
  - `:system_prompt` — prepended as a system message (overrides `context.system_prompt`)
  """
  @spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t()
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    parent = self()
    ref = make_ref()

    Stream.resource(
      fn -> start_stream(parent, ref, model, context, opts) end,
      fn task -> receive_events(task, ref) end,
      fn task -> Task.shutdown(task, :brutal_kill) end
    )
  end

  # ---------------------------------------------------------------------------
  # Stream.resource callbacks
  # ---------------------------------------------------------------------------

  defp start_stream(parent, ref, model, context, opts) do
    Task.Supervisor.async_nolink(PiEx.TaskSupervisor, fn ->
      run_request(parent, ref, model, context, opts)
    end)
  end

  defp receive_events(task, ref) do
    receive do
      {^ref, {:event, event}} ->
        {[event], task}

      {^ref, :done} ->
        {:halt, task}

      {^ref, {:error, event}} ->
        {[event], task}

      {:DOWN, _monitor_ref, :process, pid, reason}
      when pid == task.pid and reason != :normal ->
        error_msg = empty_assistant_message("", :error, "Task crashed: #{inspect(reason)}")
        {[{:error, :error, error_msg}], task}
    end
  end

  # ---------------------------------------------------------------------------
  # HTTP request + SSE parsing
  # ---------------------------------------------------------------------------

  defp run_request(parent, ref, model, context, opts) do
    api_key = Keyword.get(opts, :api_key) || PiEx.AI.ProviderConfig.get_api_key("openai") || ""
    body = build_request_body(model, context, opts)
    initial_partial = empty_assistant_message(model.id, :stop, nil)
    send(parent, {ref, {:event, {:start, initial_partial}}})

    # Use process dictionary for SSE buffer/partial state across into: calls.
    # (Req's into: callback receives {request, response} as acc, not a custom value.)
    Process.put(:sse_buffer, "")
    Process.put(:sse_partial, initial_partial)

    req_opts =
      [
        headers: [
          {"authorization", "Bearer #{api_key}"},
          {"content-type", "application/json"}
        ],
        body: Jason.encode!(body),
        receive_timeout: 300_000,
        into: fn {:data, chunk}, {req, resp} ->
          buffer = Process.get(:sse_buffer, "")
          partial = Process.get(:sse_partial, initial_partial)
          {lines, remainder} = split_sse_lines(buffer <> chunk)
          {new_partial, events} = process_sse_lines(lines, partial)
          Process.put(:sse_buffer, remainder)
          Process.put(:sse_partial, new_partial)
          Enum.each(events, &send(parent, {ref, {:event, &1}}))
          {:cont, {req, resp}}
        end,
        raw: true
      ]

    req_opts =
      case Keyword.get(opts, :plug) do
        nil -> req_opts
        plug -> Keyword.put(req_opts, :plug, plug)
      end

    base_url = Keyword.get(opts, :base_url) || PiEx.AI.ProviderConfig.get_base_url("openai") || @base_url
    result = Req.post("#{base_url}/chat/completions", req_opts)

    case result do
      {:ok, %{status: status}} when status in 200..299 ->
        send(parent, {ref, :done})

      {:ok, %{status: status, body: body}} ->
        error_body = try_decode(body)
        msg = empty_assistant_message("", :error, "HTTP #{status}: #{inspect(error_body)}")
        send(parent, {ref, {:error, {:error, :error, msg}}})
        send(parent, {ref, :done})

      {:error, exception} ->
        reason = if match?(%Req.TransportError{reason: :closed}, exception), do: :aborted, else: :error
        msg = empty_assistant_message("", reason, Exception.message(exception))
        send(parent, {ref, {:error, {:error, reason, msg}}})
        send(parent, {ref, :done})
    end
  end

  # ---------------------------------------------------------------------------
  # SSE parsing
  # ---------------------------------------------------------------------------

  # Split accumulated buffer into complete SSE messages (double-newline separated)
  # Returns {[complete_messages], remainder}
  defp split_sse_lines(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [remainder]} = Enum.split(parts, -1)
    {complete, remainder}
  end

  # Process a list of complete SSE messages through the block state machine.
  # Returns {updated_partial, [events]}
  defp process_sse_lines(lines, partial) do
    Enum.reduce(lines, {partial, []}, fn line, {current_partial, acc_events} ->
      data = extract_data(line)

      cond do
        is_nil(data) ->
          {current_partial, acc_events}

        data == "[DONE]" ->
          {current_partial, acc_events}

        true ->
          case Jason.decode(data) do
            {:ok, chunk} ->
              {new_partial, events} = process_chunk(chunk, current_partial)
              {new_partial, acc_events ++ events}

            {:error, _} ->
              {current_partial, acc_events}
          end
      end
    end)
  end

  defp extract_data(sse_message) do
    sse_message
    |> String.split("\n")
    |> Enum.find_value(fn line ->
      case String.split(line, "data: ", parts: 2) do
        [_, data] -> String.trim(data)
        _ -> nil
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Block state machine
  #
  # State threaded through processing: we hold state in the partial AssistantMessage
  # plus a separate per-stream state map for incremental tool arg accumulation.
  # Since Stream.resource doesn't support extra state, we embed it in the partial
  # via `__stream_state__` stored in the process dictionary.
  # ---------------------------------------------------------------------------

  defp process_chunk(%{"choices" => [%{"delta" => delta} = choice | _]} = chunk, partial) do
    # Update usage if present at the chunk level
    partial = update_usage(chunk, partial)

    stop_reason = parse_stop_reason(choice["finish_reason"])

    cond do
      stop_reason != nil ->
        # Finish current block and stamp the final stop_reason onto the message
        {partial, block_end_events} = finish_current_block(partial)
        partial = %{partial | stop_reason: stop_reason}
        done_event = {:done, stop_reason, partial}
        {partial, block_end_events ++ [done_event]}

      Map.has_key?(delta, "tool_calls") ->
        process_tool_call_delta(delta["tool_calls"], partial)

      Map.has_key?(delta, "reasoning_content") && delta["reasoning_content"] != nil ->
        process_thinking_delta(delta["reasoning_content"], partial)

      Map.has_key?(delta, "content") && delta["content"] != nil ->
        process_text_delta(delta["content"], partial)

      true ->
        {partial, []}
    end
  end

  defp process_chunk(_, partial), do: {partial, []}

  # --- Text ---

  defp process_text_delta(text, partial) do
    {partial, transition_events} = ensure_block(:text, partial)
    idx = current_block_index(partial)
    partial = append_text(partial, idx, text)
    delta_event = {:text_delta, idx, text, partial}
    {partial, transition_events ++ [delta_event]}
  end

  # --- Thinking ---

  defp process_thinking_delta(text, partial) do
    {partial, transition_events} = ensure_block(:thinking, partial)
    idx = current_block_index(partial)
    partial = append_thinking(partial, idx, text)
    delta_event = {:thinking_delta, idx, text, partial}
    {partial, transition_events ++ [delta_event]}
  end

  # --- Tool calls ---

  defp process_tool_call_delta(tool_call_deltas, partial) do
    Enum.reduce(tool_call_deltas, {partial, []}, fn tc_delta, {acc_partial, acc_evts} ->
      tc_index = tc_delta["index"]
      {acc_partial, transition_events} = ensure_tool_call_block(tc_index, acc_partial)

      # Accumulate raw argument string in process dictionary
      existing_args = Process.get({:tool_args, tc_index}, "")
      new_args = existing_args <> (tc_delta["function"]["arguments"] || "")
      Process.put({:tool_args, tc_index}, new_args)

      # Patch name/id if present in this delta
      acc_partial =
        update_tool_call_block(acc_partial, tc_index, fn tc ->
          %{tc | id: tc_delta["id"] || tc.id, name: get_in(tc_delta, ["function", "name"]) || tc.name}
        end)

      content_idx = find_tool_call_content_index(acc_partial, tc_index)
      delta_event = {:toolcall_delta, content_idx, tc_delta["function"]["arguments"] || "", acc_partial}
      {acc_partial, acc_evts ++ transition_events ++ [delta_event]}
    end)
  end

  # ---------------------------------------------------------------------------
  # Block management helpers
  # ---------------------------------------------------------------------------

  # Ensure the current open block is of `type`. If not, close the old one and open a new one.
  defp ensure_block(type, partial) do
    current = Process.get(:current_block_type)

    if current == type do
      {partial, []}
    else
      {partial, end_events} = finish_current_block(partial)
      partial = open_new_block(type, partial)
      idx = current_block_index(partial)
      start_event = block_start_event(type, idx, partial)
      {partial, end_events ++ [start_event]}
    end
  end

  defp ensure_tool_call_block(tc_index, partial) do
    current = Process.get(:current_block_type)
    existing = Process.get({:tool_call_content_index, tc_index})

    if current == :tool_call && existing != nil do
      {partial, []}
    else
      {partial, end_events} = finish_current_block(partial)
      partial = open_new_tool_call_block(tc_index, partial)
      Process.put(:current_block_type, :tool_call)
      idx = find_tool_call_content_index(partial, tc_index)
      Process.put({:tool_call_content_index, tc_index}, idx)
      start_event = {:toolcall_start, idx, partial}
      {partial, end_events ++ [start_event]}
    end
  end

  defp finish_current_block(partial) do
    case Process.get(:current_block_type) do
      nil ->
        {partial, []}

      :text ->
        Process.delete(:current_block_type)
        idx = current_block_index(partial)
        content = get_text_at(partial, idx)
        {partial, [{:text_end, idx, content, partial}]}

      :thinking ->
        Process.delete(:current_block_type)
        idx = current_block_index(partial)
        content = get_thinking_at(partial, idx)
        {partial, [{:thinking_end, idx, content, partial}]}

      :tool_call ->
        Process.delete(:current_block_type)
        # Finalize all open tool call blocks
        finalize_tool_call_blocks(partial)
    end
  end

  defp finalize_tool_call_blocks(partial) do
    Process.get_keys()
    |> Enum.filter(fn
      {:tool_call_content_index, _} -> true
      _ -> false
    end)
    |> Enum.reduce({partial, []}, fn {:tool_call_content_index, tc_index} = key, {acc_partial, acc_events} ->
      content_idx = Process.get(key)
      Process.delete(key)
      raw_args = Process.get({:tool_args, tc_index}, "{}")
      Process.delete({:tool_args, tc_index})

      parsed_args =
        case Jason.decode(raw_args) do
          {:ok, args} -> args
          {:error, _} -> %{}
        end

      acc_partial =
        update_tool_call_block(acc_partial, tc_index, fn tc ->
          %{tc | arguments: parsed_args}
        end)

      tool_call = Enum.at(acc_partial.content, content_idx)
      end_event = {:toolcall_end, content_idx, tool_call, acc_partial}
      {acc_partial, acc_events ++ [end_event]}
    end)
  end

  defp open_new_block(:text, partial) do
    idx = length(partial.content)
    Process.put(:current_block_type, :text)
    Process.put(:current_block_index, idx)
    new_content = partial.content ++ [%TextContent{text: ""}]
    %{partial | content: new_content}
  end

  defp open_new_block(:thinking, partial) do
    idx = length(partial.content)
    Process.put(:current_block_type, :thinking)
    Process.put(:current_block_index, idx)
    new_content = partial.content ++ [%ThinkingContent{thinking: ""}]
    %{partial | content: new_content}
  end

  defp open_new_tool_call_block(tc_index, partial) do
    idx = length(partial.content)
    Process.put({:tool_call_content_index, tc_index}, idx)
    new_content = partial.content ++ [%ToolCall{id: "", name: "", arguments: %{}}]
    %{partial | content: new_content}
  end

  defp block_start_event(:text, idx, partial), do: {:text_start, idx, partial}
  defp block_start_event(:thinking, idx, partial), do: {:thinking_start, idx, partial}

  defp current_block_index(partial), do: Process.get(:current_block_index, length(partial.content) - 1)

  defp find_tool_call_content_index(partial, tc_index) do
    Process.get({:tool_call_content_index, tc_index}, length(partial.content) - 1)
  end

  defp append_text(partial, idx, delta) do
    update_content(partial, idx, fn %TextContent{text: t} -> %TextContent{text: t <> delta} end)
  end

  defp append_thinking(partial, idx, delta) do
    update_content(partial, idx, fn %ThinkingContent{thinking: t} -> %ThinkingContent{thinking: t <> delta} end)
  end

  defp get_text_at(partial, idx) do
    case Enum.at(partial.content, idx) do
      %TextContent{text: t} -> t
      _ -> ""
    end
  end

  defp get_thinking_at(partial, idx) do
    case Enum.at(partial.content, idx) do
      %ThinkingContent{thinking: t} -> t
      _ -> ""
    end
  end

  defp update_content(partial, idx, fun) do
    new_content = List.update_at(partial.content, idx, fun)
    %{partial | content: new_content}
  end

  defp update_tool_call_block(partial, tc_index, fun) do
    content_idx = Process.get({:tool_call_content_index, tc_index}, length(partial.content) - 1)
    update_content(partial, content_idx, fun)
  end

  # ---------------------------------------------------------------------------
  # Request building
  # ---------------------------------------------------------------------------

  defp build_request_body(model, context, opts) do
    messages = build_messages(context)

    body = %{
      model: model.id,
      messages: messages,
      stream: true,
      stream_options: %{include_usage: true}
    }

    body
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:max_tokens, Keyword.get(opts, :max_tokens))
    |> maybe_put(:tools, build_tools(context.tools))
  end

  defp build_messages(%Context{system_prompt: system_prompt, messages: messages}) do
    system =
      if system_prompt do
        [%{role: "system", content: system_prompt}]
      else
        []
      end

    user_messages = Enum.flat_map(messages, &convert_message/1)
    system ++ user_messages
  end

  defp convert_message(%CompactionSummaryMessage{summary: summary}) do
    [%{role: "user", content: "[Context Summary]\n\n#{summary}"}]
  end

  defp convert_message(%UserMessage{content: content}) when is_binary(content) do
    [%{role: "user", content: content}]
  end

  defp convert_message(%UserMessage{content: blocks}) when is_list(blocks) do
    [%{role: "user", content: Enum.map(blocks, &convert_user_block/1)}]
  end

  defp convert_message(%AssistantMessage{content: blocks}) do
    text =
      blocks
      |> Enum.flat_map(fn
        %TextContent{text: t} -> [t]
        _ -> []
      end)
      |> Enum.join()

    tool_calls =
      Enum.flat_map(blocks, fn
        %ToolCall{id: id, name: name, arguments: args} ->
          [%{id: id, type: "function", function: %{name: name, arguments: Jason.encode!(args)}}]

        _ ->
          []
      end)

    # OpenAI requires content: null when there are tool_calls and no text
    content = if text == "", do: nil, else: text
    msg = %{role: "assistant", content: content}
    msg = if tool_calls == [], do: msg, else: Map.put(msg, :tool_calls, tool_calls)
    [msg]
  end

  defp convert_message(%ToolResultMessage{tool_call_id: id, content: blocks, is_error: is_error}) do
    text =
      blocks
      |> Enum.filter(&match?(%PiEx.AI.Content.TextContent{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("\n")

    content = if is_error, do: "Error: #{text}", else: text

    [%{role: "tool", tool_call_id: id, content: content}]
  end

  defp convert_user_block(%PiEx.AI.Content.TextContent{text: t}), do: %{type: "text", text: t}

  defp convert_user_block(%PiEx.AI.Content.ImageContent{data: data, mime_type: mime}) do
    %{
      type: "image_url",
      image_url: %{url: "data:#{mime};base64,#{data}"}
    }
  end

  defp build_tools([]), do: nil

  defp build_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        function: %{
          name: tool.name,
          description: tool.description,
          parameters: tool.parameters
        }
      }
    end)
  end

  # ---------------------------------------------------------------------------
  # Utilities
  # ---------------------------------------------------------------------------

  defp update_usage(%{"usage" => %{"prompt_tokens" => input, "completion_tokens" => output}}, partial) do
    %{partial | usage: %Usage{input_tokens: input, output_tokens: output}}
  end

  defp update_usage(_, partial), do: partial

  defp parse_stop_reason("stop"), do: :stop
  defp parse_stop_reason("length"), do: :length
  defp parse_stop_reason("tool_calls"), do: :tool_use
  defp parse_stop_reason(nil), do: nil
  defp parse_stop_reason(_), do: :stop

  defp empty_assistant_message(model_id, stop_reason, error_message) do
    %AssistantMessage{
      content: [],
      model: model_id,
      usage: %Usage{},
      stop_reason: stop_reason,
      timestamp: System.system_time(:millisecond),
      error_message: error_message
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp try_decode(binary) when is_binary(binary) do
    case Jason.decode(binary) do
      {:ok, decoded} -> decoded
      {:error, _} -> binary
    end
  end

  defp try_decode(other), do: other
end

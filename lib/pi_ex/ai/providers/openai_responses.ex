defmodule PiEx.AI.Providers.OpenAIResponses do
  @moduledoc """
  OpenAI Responses API streaming provider.

  This provider supports GPT-5-style reasoning summaries and function calling
  over the `/v1/responses` endpoint.
  """

  alias PiEx.AI.Content.{TextContent, ThinkingContent, ToolCall}

  alias PiEx.AI.Message.{
    UserMessage,
    AssistantMessage,
    ToolResultMessage,
    CompactionSummaryMessage,
    Usage
  }

  alias PiEx.AI.{Context, Model}
  alias PiEx.AI.ProviderParams.OpenAIResponses, as: OpenAIResponsesParams
  alias PiEx.Observability

  @base_url "https://api.openai.com/v1"
  @default_receive_timeout 300_000

  @doc """
  Returns a lazy stream of `PiEx.AI.StreamEvent.t()` events.

  Options:
  - `:api_key` — overrides `OPENAI_API_KEY` env var
  - `:base_url` — overrides the default OpenAI base URL
  - `:temperature` — float
  - `:max_tokens` — integer, mapped to `max_output_tokens`
  - `:http_receive_timeout` — Req receive timeout in milliseconds (default: `300_000`)
  - `:reasoning_effort` — OpenAI reasoning effort
  - `:reasoning_summary` — summary mode; defaults to `"auto"`
  """
  @spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t()
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    parent = self()
    ref = make_ref()
    parent_ctx = Observability.current_ctx()

    Stream.resource(
      fn -> start_stream(parent, ref, model, context, opts, parent_ctx) end,
      fn task -> receive_events(task, ref) end,
      fn task -> Task.shutdown(task, :brutal_kill) end
    )
  end

  @doc false
  def build_req_options(provider_params, opts \\ [])

  def build_req_options(%OpenAIResponsesParams{} = provider_params, opts) do
    Keyword.put(opts, :receive_timeout, req_receive_timeout(provider_params, opts))
  end

  def build_req_options(nil, opts) do
    Keyword.put(opts, :receive_timeout, req_receive_timeout(nil, opts))
  end

  defp start_stream(parent, ref, model, context, opts, parent_ctx) do
    Task.Supervisor.async_nolink(PiEx.TaskSupervisor, fn ->
      run_request(parent, ref, model, context, opts, parent_ctx)
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

  defp run_request(parent, ref, model, context, opts, parent_ctx) do
    settings = Keyword.get(opts, :observability)

    Observability.with_span(
      Observability.model_span_name(model.id),
      [
        kind: :client,
        parent_ctx: parent_ctx,
        attributes:
          Observability.model_span_attributes(
            model,
            context,
            opts,
            Observability.resolve_settings(settings)
          )
      ],
      settings,
      fn span_ctx ->
        api_key =
          Keyword.get(opts, :api_key) || PiEx.AI.ProviderConfig.get_api_key("openai") || ""

        body = build_request_body(model, context, opts)
        initial_partial = empty_assistant_message(model.id, :stop, nil)
        send(parent, {ref, {:event, {:start, initial_partial}}})

        Process.put(:sse_buffer, "")
        Process.put(:sse_partial, initial_partial)

        req_opts =
          build_req_options(model.provider_params, [])
          |> Keyword.merge(
            headers: [
              {"authorization", "Bearer #{api_key}"},
              {"content-type", "application/json"}
            ],
            body: Jason.encode!(body),
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
          )

        req_opts =
          case Keyword.get(opts, :plug) do
            nil -> req_opts
            plug -> Keyword.put(req_opts, :plug, plug)
          end

        base_url =
          Keyword.get(opts, :base_url) || PiEx.AI.ProviderConfig.get_base_url("openai") ||
            @base_url

        result = Req.post("#{base_url}/responses", req_opts)

        case result do
          {:ok, %{status: status}} when status in 200..299 ->
            final_partial = Process.get(:sse_partial, initial_partial)

            Observability.finish_model_span(
              span_ctx,
              final_partial,
              Observability.resolve_settings(settings)
            )

            send(parent, {ref, :done})

          {:ok, %{status: status, body: body}} ->
            error_body = try_decode(body)
            msg = empty_assistant_message("", :error, "HTTP #{status}: #{inspect(error_body)}")
            Observability.set_error(span_ctx, Integer.to_string(status))
            send(parent, {ref, {:error, {:error, :error, msg}}})
            send(parent, {ref, :done})

          {:error, exception} ->
            reason =
              if match?(%Req.TransportError{reason: :closed}, exception),
                do: :aborted,
                else: :error

            msg = empty_assistant_message("", reason, Exception.message(exception))
            Observability.set_error(span_ctx, reason)
            send(parent, {ref, {:error, {:error, reason, msg}}})
            send(parent, {ref, :done})
        end
      end
    )
  end

  defp split_sse_lines(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [remainder]} = Enum.split(parts, -1)
    {complete, remainder}
  end

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

  defp process_chunk(%{"type" => "response.output_text.delta", "delta" => text}, partial) do
    {partial, transition_events} = ensure_block(:text, partial)
    idx = current_block_index(partial)
    partial = append_text(partial, idx, text)
    {partial, transition_events ++ [{:text_delta, idx, text, partial}]}
  end

  defp process_chunk(
         %{"type" => "response.reasoning_summary_text.delta", "delta" => text},
         partial
       ) do
    {partial, transition_events} = ensure_block(:thinking, partial)
    idx = current_block_index(partial)
    partial = append_thinking(partial, idx, text)
    {partial, transition_events ++ [{:thinking_delta, idx, text, partial}]}
  end

  defp process_chunk(
         %{"type" => "response.reasoning_summary_text.done", "text" => text},
         partial
       ) do
    emit_completed_thinking_text(text, partial)
  end

  defp process_chunk(%{"type" => "response.reasoning_text.delta", "delta" => text}, partial) do
    {partial, transition_events} = ensure_block(:thinking, partial)
    idx = current_block_index(partial)
    partial = append_thinking(partial, idx, text)
    {partial, transition_events ++ [{:thinking_delta, idx, text, partial}]}
  end

  defp process_chunk(%{"type" => "response.reasoning_text.done", "text" => text}, partial) do
    emit_completed_thinking_text(text, partial)
  end

  defp process_chunk(
         %{"type" => "response.output_item.added", "item" => %{"type" => "function_call"} = item},
         partial
       ) do
    item_key = tool_call_key(%{"item_id" => item["id"], "output_index" => item["id"]})
    {partial, transition_events} = ensure_tool_call_block(item_key, partial)

    Process.put({:tool_args, item_key}, Map.get(item, "arguments", ""))

    partial =
      update_tool_call_block(partial, item_key, fn tc ->
        %{
          tc
          | id: Map.get(item, "call_id", tc.id),
            name: Map.get(item, "name", tc.name)
        }
      end)

    {partial, transition_events}
  end

  defp process_chunk(%{"type" => "response.function_call_arguments.delta"} = chunk, partial) do
    item_key = tool_call_key(chunk)
    {partial, transition_events} = ensure_tool_call_block(item_key, partial)

    existing_args = Process.get({:tool_args, item_key}, "")
    delta = Map.get(chunk, "delta", "")
    Process.put({:tool_args, item_key}, existing_args <> delta)

    partial =
      update_tool_call_block(partial, item_key, fn tc ->
        %{
          tc
          | id: Map.get(chunk, "call_id", tc.id),
            name: Map.get(chunk, "name", tc.name)
        }
      end)

    content_idx = find_tool_call_content_index(partial, item_key)
    {partial, transition_events ++ [{:toolcall_delta, content_idx, delta, partial}]}
  end

  defp process_chunk(%{"type" => "response.function_call_arguments.done"} = chunk, partial) do
    item_key = tool_call_key(chunk)

    Process.put({:tool_args, item_key}, Map.get(chunk, "arguments", "{}"))

    partial =
      update_tool_call_block(partial, item_key, fn tc ->
        %{
          tc
          | id: Map.get(chunk, "call_id", tc.id),
            name: Map.get(chunk, "name", tc.name)
        }
      end)

    {partial, []}
  end

  defp process_chunk(%{"type" => "response.completed", "response" => response}, partial) do
    partial = update_usage(response, partial)
    {partial, end_events} = finish_current_block(partial)
    partial = %{partial | stop_reason: infer_stop_reason(partial)}
    {partial, end_events ++ [{:done, partial.stop_reason, partial}]}
  end

  defp process_chunk(%{"type" => "response.incomplete", "response" => response}, partial) do
    partial = update_usage(response, partial)
    {partial, end_events} = finish_current_block(partial)
    partial = %{partial | stop_reason: :length}
    {partial, end_events ++ [{:done, :length, partial}]}
  end

  defp process_chunk(_, partial), do: {partial, []}

  defp emit_completed_thinking_text(text, partial) do
    {partial, transition_events} = ensure_block(:thinking, partial)
    idx = current_block_index(partial)

    current_text = get_thinking_at(partial, idx)

    partial =
      if current_text == "" do
        append_thinking(partial, idx, text)
      else
        partial
      end

    delta_events =
      if current_text == "" and text != "" do
        [{:thinking_delta, idx, text, partial}]
      else
        []
      end

    {partial, transition_events ++ delta_events}
  end

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

  defp ensure_tool_call_block(item_key, partial) do
    current = Process.get(:current_block_type)
    existing = Process.get({:tool_call_content_index, item_key})

    if current == :tool_call && existing != nil do
      {partial, []}
    else
      {partial, end_events} = finish_current_block(partial)
      partial = open_new_tool_call_block(item_key, partial)
      Process.put(:current_block_type, :tool_call)
      idx = find_tool_call_content_index(partial, item_key)
      Process.put({:tool_call_content_index, item_key}, idx)
      {partial, end_events ++ [{:toolcall_start, idx, partial}]}
    end
  end

  defp finish_current_block(partial) do
    case Process.get(:current_block_type) do
      nil ->
        {partial, []}

      :text ->
        Process.delete(:current_block_type)
        idx = current_block_index(partial)
        {partial, [{:text_end, idx, get_text_at(partial, idx), partial}]}

      :thinking ->
        Process.delete(:current_block_type)
        idx = current_block_index(partial)
        {partial, [{:thinking_end, idx, get_thinking_at(partial, idx), partial}]}

      :tool_call ->
        Process.delete(:current_block_type)
        finalize_tool_call_blocks(partial)
    end
  end

  defp finalize_tool_call_blocks(partial) do
    Process.get_keys()
    |> Enum.filter(fn
      {:tool_call_content_index, _} -> true
      _ -> false
    end)
    |> Enum.reduce({partial, []}, fn {:tool_call_content_index, item_key} = key,
                                     {acc_partial, acc_events} ->
      content_idx = Process.get(key)
      Process.delete(key)
      raw_args = Process.get({:tool_args, item_key}, "{}")
      Process.delete({:tool_args, item_key})

      parsed_args =
        case Jason.decode(raw_args) do
          {:ok, args} -> args
          {:error, _} -> %{}
        end

      acc_partial =
        update_tool_call_block(acc_partial, item_key, fn tc ->
          %{tc | arguments: parsed_args}
        end)

      tool_call = Enum.at(acc_partial.content, content_idx)
      {acc_partial, acc_events ++ [{:toolcall_end, content_idx, tool_call, acc_partial}]}
    end)
  end

  defp open_new_block(:text, partial) do
    idx = length(partial.content)
    Process.put(:current_block_type, :text)
    Process.put(:current_block_index, idx)
    %{partial | content: partial.content ++ [%TextContent{text: ""}]}
  end

  defp open_new_block(:thinking, partial) do
    idx = length(partial.content)
    Process.put(:current_block_type, :thinking)
    Process.put(:current_block_index, idx)
    %{partial | content: partial.content ++ [%ThinkingContent{thinking: ""}]}
  end

  defp open_new_tool_call_block(item_key, partial) do
    idx = length(partial.content)
    Process.put({:tool_call_content_index, item_key}, idx)
    %{partial | content: partial.content ++ [%ToolCall{id: "", name: "", arguments: %{}}]}
  end

  defp block_start_event(:text, idx, partial), do: {:text_start, idx, partial}
  defp block_start_event(:thinking, idx, partial), do: {:thinking_start, idx, partial}

  defp current_block_index(partial),
    do: Process.get(:current_block_index, length(partial.content) - 1)

  defp find_tool_call_content_index(partial, item_key),
    do: Process.get({:tool_call_content_index, item_key}, length(partial.content) - 1)

  defp append_text(partial, idx, delta) do
    update_content(partial, idx, fn %TextContent{text: text} ->
      %TextContent{text: text <> delta}
    end)
  end

  defp append_thinking(partial, idx, delta) do
    update_content(partial, idx, fn %ThinkingContent{thinking: thinking} ->
      %ThinkingContent{thinking: thinking <> delta}
    end)
  end

  defp get_text_at(partial, idx) do
    case Enum.at(partial.content, idx) do
      %TextContent{text: text} -> text
      _ -> ""
    end
  end

  defp get_thinking_at(partial, idx) do
    case Enum.at(partial.content, idx) do
      %ThinkingContent{thinking: thinking} -> thinking
      _ -> ""
    end
  end

  defp update_content(partial, idx, fun) do
    %{partial | content: List.update_at(partial.content, idx, fun)}
  end

  defp update_tool_call_block(partial, item_key, fun) do
    content_idx = Process.get({:tool_call_content_index, item_key}, length(partial.content) - 1)
    update_content(partial, content_idx, fun)
  end

  defp tool_call_key(%{"item_id" => item_id}) when is_binary(item_id), do: item_id
  defp tool_call_key(%{"output_index" => output_index}), do: output_index

  defp build_request_body(model, context, opts) do
    %{
      model: model.id,
      input: build_input(context.messages),
      stream: true
    }
    |> maybe_put(:instructions, context.system_prompt)
    |> maybe_put(:temperature, Keyword.get(opts, :temperature))
    |> maybe_put(:max_output_tokens, Keyword.get(opts, :max_tokens))
    |> maybe_put(:tools, build_tools(context.tools))
    |> maybe_put(:reasoning, build_reasoning(opts))
  end

  defp build_input(messages), do: Enum.flat_map(messages, &convert_message/1)

  defp convert_message(%CompactionSummaryMessage{summary: summary}) do
    [%{role: "user", content: summary}]
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

    assistant_msgs =
      if text == "" do
        []
      else
        [%{role: "assistant", content: text}]
      end

    tool_calls =
      Enum.flat_map(blocks, fn
        %ToolCall{id: id, name: name, arguments: args} ->
          [%{type: "function_call", call_id: id, name: name, arguments: Jason.encode!(args)}]

        _ ->
          []
      end)

    assistant_msgs ++ tool_calls
  end

  defp convert_message(%ToolResultMessage{tool_call_id: id, content: blocks, is_error: is_error}) do
    text =
      blocks
      |> Enum.filter(&match?(%TextContent{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join("\n")

    output = if is_error, do: "Error: " <> text, else: text
    [%{type: "function_call_output", call_id: id, output: output}]
  end

  defp convert_user_block(%PiEx.AI.Content.TextContent{text: text}),
    do: %{type: "input_text", text: text}

  defp convert_user_block(%PiEx.AI.Content.ImageContent{data: data, mime_type: mime}) do
    %{
      type: "input_image",
      image_url: "data:#{mime};base64,#{data}"
    }
  end

  defp build_tools([]), do: nil

  defp build_tools(tools) do
    Enum.map(tools, fn tool ->
      %{
        type: "function",
        name: tool.name,
        description: tool.description,
        parameters: tool.parameters
      }
    end)
  end

  defp build_reasoning(opts) do
    effort = Keyword.get(opts, :reasoning_effort)

    case effort do
      nil ->
        nil

      effort ->
        summary = Keyword.get(opts, :reasoning_summary, "auto")
        %{effort: effort, summary: summary}
    end
  end

  defp update_usage(%{"usage" => usage}, partial) when is_map(usage) do
    input_tokens = Map.get(usage, "input_tokens", Map.get(usage, "prompt_tokens", 0))
    output_tokens = Map.get(usage, "output_tokens", Map.get(usage, "completion_tokens", 0))
    %{partial | usage: %Usage{input_tokens: input_tokens, output_tokens: output_tokens}}
  end

  defp update_usage(_, partial), do: partial

  defp infer_stop_reason(%AssistantMessage{content: content}) do
    if Enum.any?(content, &match?(%ToolCall{}, &1)), do: :tool_use, else: :stop
  end

  defp req_receive_timeout(%OpenAIResponsesParams{http_receive_timeout: timeout}, opts)
       when is_integer(timeout) and timeout > 0 do
    Keyword.get(opts, :http_receive_timeout, timeout)
  end

  defp req_receive_timeout(_provider_params, opts) do
    Keyword.get(opts, :http_receive_timeout, @default_receive_timeout)
  end

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

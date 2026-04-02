defmodule PiEx.Agent.Loop do
  @moduledoc """
  The core agent loop, run inside a supervised Task.

  Mirrors the TypeScript `runLoop` from `packages/agent/src/agent-loop.ts`.

  ## Loop structure

      outer while (follow-up messages available):
        inner while (tool calls pending or messages to process):
          1. Inject steering messages (if any)
          2. Stream a response from the LLM
          3. On :done with tool_use stop_reason: execute tool calls concurrently
          4. On :done with :stop/:length: break inner loop
          5. On :error/:aborted: break both loops
        Poll get_follow_up_messages; if none, break outer loop

  All agent events are sent to `server_pid` as `{:agent_event, event}` messages.

  ## Agent events (tagged tuples)

  ### Lifecycle
  - `{:agent_start}`
  - `{:agent_end, messages}`

  ### Turn lifecycle
  - `{:turn_start}`
  - `{:turn_end, assistant_message, tool_result_messages}`

  ### Streaming (forwarded from PiEx.AI stream events, carrying the raw event)
  - `{:message_start, message}`
  - `{:message_update, message, stream_event}`
  - `{:message_end, message}`

  ### Tool execution
  - `{:tool_execution_start, call_id, tool_name, args}`
  - `{:tool_execution_update, call_id, tool_name, args, partial_result}`
  - `{:tool_execution_end, call_id, tool_name, result, is_error}`
  """

  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.Message.{AssistantMessage, ToolResultMessage}
  alias PiEx.Agent.Config

  @doc """
  Entry point. Called in a supervised Task by the Agent GenServer.

  Sends `{:agent_event, event}` messages to `server_pid`.
  """
  @spec run([PiEx.AI.Message.t()], Config.t(), pid()) :: :ok
  def run(initial_messages, %Config{} = config, server_pid) do
    send(server_pid, {:agent_event, :agent_start})
    messages = initial_messages
    final_messages = outer_loop(messages, config, server_pid)
    send(server_pid, {:agent_event, {:agent_end, final_messages}})
    :ok
  end

  # ---------------------------------------------------------------------------
  # Outer loop — restarts when follow-up messages arrive
  # ---------------------------------------------------------------------------

  defp outer_loop(messages, config, server_pid) do
    messages = inner_loop(messages, config, server_pid, _pending_messages = [])

    case poll_follow_up_messages(config) do
      [] ->
        messages

      follow_up ->
        follow_up_with_timestamps =
          Enum.map(follow_up, fn
            msg when is_struct(msg) -> msg
            msg -> msg
          end)

        outer_loop(messages ++ follow_up_with_timestamps, config, server_pid)
    end
  end

  # ---------------------------------------------------------------------------
  # Inner loop — runs until no more tool calls or error
  # ---------------------------------------------------------------------------

  defp inner_loop(messages, config, server_pid, pending_messages) do
    # Inject any pending messages first
    messages = messages ++ pending_messages

    # Check for steering messages
    steering = poll_steering_messages(config)
    messages = messages ++ steering

    send(server_pid, {:agent_event, :turn_start})

    case stream_assistant_response(messages, config, server_pid) do
      {:ok, assistant_message, messages} ->
        tool_calls = extract_tool_calls(assistant_message)

        if tool_calls == [] do
          send(server_pid, {:agent_event, {:turn_end, assistant_message, []}})
          messages
        else
          {tool_results, messages} = execute_tool_calls(tool_calls, config, server_pid, messages)
          send(server_pid, {:agent_event, {:turn_end, assistant_message, tool_results}})
          inner_loop(messages, config, server_pid, [])
        end

      {:halt, messages} ->
        messages

      {:error, messages} ->
        messages
    end
  end

  # ---------------------------------------------------------------------------
  # Stream one LLM response turn
  # ---------------------------------------------------------------------------

  defp stream_assistant_response(messages, config, server_pid) do
    context = build_context(messages, config)

    stream_opts =
      case PiEx.AI.ProviderParams.to_opts(config.model) do
        {:ok, opts} -> opts
        {:error, _reason} -> []
      end

    stream_fn = config.stream_fn || fn m, c, o -> PiEx.AI.stream(m, c, o) end
    stream = stream_fn.(config.model, context, stream_opts)

    Enum.reduce_while(stream, {nil, messages}, fn event, {partial, acc_messages} ->
      case event do
        {:start, partial} ->
          send(server_pid, {:agent_event, {:message_start, partial}})
          {:cont, {partial, acc_messages}}

        {type, _, _, partial}
        when type in [
               :text_delta,
               :text_start,
               :text_end,
               :thinking_delta,
               :thinking_start,
               :thinking_end,
               :toolcall_delta,
               :toolcall_start,
               :toolcall_end
             ] ->
          send(server_pid, {:agent_event, {:message_update, partial, event}})
          {:cont, {partial, acc_messages}}

        {:done, _reason, final_message} ->
          send(server_pid, {:agent_event, {:message_end, final_message}})
          new_messages = acc_messages ++ [final_message]
          {:halt, {:ok, final_message, new_messages}}

        {:error, reason, error_message} ->
          send(server_pid, {:agent_event, {:agent_error, {reason, error_message.error_message}}})
          send(server_pid, {:agent_event, {:message_end, error_message}})
          tag = if reason == :aborted, do: :halt, else: :error
          {:halt, {tag, acc_messages ++ [error_message]}}

        _ ->
          {:cont, {partial, acc_messages}}
      end
    end)
    |> case do
      {:ok, msg, msgs} -> {:ok, msg, msgs}
      {:halt, msgs} -> {:halt, msgs}
      {:error, msgs} -> {:error, msgs}
      # Reduce_while returns the accumulator value on halt
      {final_tag, final_msgs} when is_atom(final_tag) -> {final_tag, final_msgs}
    end
  end

  # ---------------------------------------------------------------------------
  # Tool execution
  # ---------------------------------------------------------------------------

  defp execute_tool_calls(tool_calls, config, server_pid, messages) do
    tool_map = Map.new(config.tools, fn t -> {t.name, t} end)

    results =
      tool_calls
      |> Task.async_stream(
        fn %ToolCall{id: call_id, name: tool_name, arguments: args} ->
          execute_single_tool(call_id, tool_name, args, tool_map, config, server_pid)
        end,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          %ToolResultMessage{
            tool_call_id: "unknown",
            tool_name: "unknown",
            content: [%TextContent{text: "Tool failed: #{inspect(reason)}"}],
            is_error: true,
            timestamp: System.system_time(:millisecond)
          }
      end)

    # Emit message events for tool results
    Enum.each(results, fn result ->
      send(server_pid, {:agent_event, {:message_start, result}})
      send(server_pid, {:agent_event, {:message_end, result}})
    end)

    new_messages = messages ++ results
    {results, new_messages}
  end

  defp execute_single_tool(call_id, tool_name, args, tool_map, config, server_pid) do
    # Before-hook check
    blocked =
      case config.before_tool_call do
        nil -> :ok
        f -> f.(call_id, tool_name, args)
      end

    case blocked do
      {:block, reason} ->
        result = blocked_tool_result(call_id, tool_name, reason)
        send(server_pid, {:agent_event, {:tool_execution_end, call_id, tool_name, result, true}})
        result

      :ok ->
        case Map.fetch(tool_map, tool_name) do
          :error ->
            result = error_tool_result(call_id, tool_name, "Unknown tool: #{tool_name}")

            send(
              server_pid,
              {:agent_event, {:tool_execution_end, call_id, tool_name, result, true}}
            )

            result

          {:ok, tool} ->
            send(server_pid, {:agent_event, {:tool_execution_start, call_id, tool_name, args}})

            on_update = fn partial_result ->
              send(
                server_pid,
                {:agent_event, {:tool_execution_update, call_id, tool_name, args, partial_result}}
              )
            end

            case tool.execute.(call_id, args, on_update: on_update) do
              {:ok, %{content: content, details: details}} ->
                result = %ToolResultMessage{
                  tool_call_id: call_id,
                  tool_name: tool_name,
                  content: content,
                  details: details,
                  is_error: false,
                  timestamp: System.system_time(:millisecond)
                }

                final_result =
                  case config.after_tool_call do
                    nil -> result
                    f -> f.(call_id, tool_name, result)
                  end

                send(
                  server_pid,
                  {:agent_event, {:tool_execution_end, call_id, tool_name, final_result, false}}
                )

                final_result

              {:error, reason} ->
                result = error_tool_result(call_id, tool_name, reason)

                send(
                  server_pid,
                  {:agent_event, {:tool_execution_end, call_id, tool_name, result, true}}
                )

                result
            end
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Context building
  # ---------------------------------------------------------------------------

  defp build_context(messages, config) do
    ai_tools = Enum.map(config.tools, &PiEx.Agent.Tool.to_ai_tool/1)

    context = %PiEx.AI.Context{
      system_prompt: config.system_prompt,
      messages: messages,
      tools: ai_tools
    }

    case config.transform_context do
      nil -> context
      f -> f.(context)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp extract_tool_calls(%AssistantMessage{content: content, stop_reason: :tool_use}) do
    Enum.filter(content, &match?(%ToolCall{}, &1))
  end

  defp extract_tool_calls(_), do: []

  defp poll_steering_messages(%Config{get_steering_messages: nil}), do: []
  defp poll_steering_messages(%Config{get_steering_messages: f}), do: f.()

  defp poll_follow_up_messages(%Config{get_follow_up_messages: nil}), do: []
  defp poll_follow_up_messages(%Config{get_follow_up_messages: f}), do: f.()

  defp error_tool_result(call_id, tool_name, reason) do
    %ToolResultMessage{
      tool_call_id: call_id,
      tool_name: tool_name,
      content: [%TextContent{text: "Error: #{reason}"}],
      is_error: true,
      timestamp: System.system_time(:millisecond)
    }
  end

  defp blocked_tool_result(call_id, tool_name, reason) do
    %ToolResultMessage{
      tool_call_id: call_id,
      tool_name: tool_name,
      content: [%TextContent{text: "Tool call blocked: #{reason}"}],
      is_error: true,
      timestamp: System.system_time(:millisecond)
    }
  end
end

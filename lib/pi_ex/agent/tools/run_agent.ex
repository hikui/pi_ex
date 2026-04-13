defmodule PiEx.Agent.Tools.RunAgent do
  @moduledoc """
  Tool that spawns a supervised subagent to handle a delegated subtask.

  Automatically injected into `PiEx.Agent.Server` when the agent's depth is
  below `config.max_depth` (or when `max_depth` is `nil` — unlimited).

  ## Subagent lifecycle

  1. Resolves a `%PiEx.SubAgent.Definition{}` by name (checking `config.subagents`
     inline list, then `PiEx.SubAgent.Registry`). For general (unnamed) subagents,
     all fields are inherited from the calling agent.
  2. Merges the definition with the calling agent's config (inheritance):
     `nil` fields on the definition fall back to the parent's values.
  3. Starts a new supervised `PiEx.Agent.Server` under `PiEx.Agent.Supervisor`.
  4. Subscribes to the subagent's events and forwards them to the parent server
     as `{:agent_event, {:subagent_event, name, depth, original_event}}`.
  5. Returns the subagent's final assistant text as the tool result.
  6. Stops the subagent process after completion.

  ## Concurrency

  Multiple `run_agent` calls in one turn execute concurrently via the loop's
  `Task.async_stream`. Subagent lifetime is managed through the supervised
  process tree and normal Elixir process monitoring.
  """

  alias PiEx.Agent.{Config, Supervisor, Server}
  alias PiEx.AI.Content.TextContent
  alias PiEx.AI.Message.AssistantMessage
  alias PiEx.SubAgent.{Definition, Registry}

  @doc """
  Build a `%PiEx.Agent.Tool{}` that delegates subtasks to subagents.

  - `parent_config` — the calling agent's config (used for inheritance + depth check)
  - `parent_server_pid` — the calling `Agent.Server` pid (receives forwarded subagent events)
  """
  @spec tool(Config.t(), pid()) :: PiEx.Agent.Tool.t()
  def tool(%Config{} = parent_config, parent_server_pid) do
    %PiEx.Agent.Tool{
      name: "run_agent",
      label: "Run Subagent",
      description: build_description(parent_config),
      parameters: parameters_schema(),
      execute: fn _call_id, params, opts ->
        run(params, parent_config, parent_server_pid, opts)
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Private implementation
  # ---------------------------------------------------------------------------

  defp run(params, parent_config, parent_server_pid, opts) do
    prompt_text = Map.fetch!(params, "prompt")
    agent_name = Map.get(params, "agent")
    trace_span = Keyword.get(opts, :trace_span)

    with {:ok, definition} <- resolve_definition(agent_name, parent_config),
         {:ok, sub_config} <- build_subagent_config(definition, parent_config, trace_span),
         {:ok, agent_pid} <- Supervisor.start_agent(sub_config) do
      Server.subscribe(agent_pid, self())
      :ok = Server.prompt(agent_pid, prompt_text)
      result = collect_result(agent_name, sub_config.depth, parent_server_pid)

      Supervisor.stop_agent(agent_pid)

      result
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_definition(nil, _parent_config) do
    {:ok, nil}
  end

  defp resolve_definition(name, parent_config) do
    inline = Enum.find(parent_config.subagents || [], &(&1.name == name))

    case inline do
      %Definition{} = definition ->
        {:ok, definition}

      nil ->
        case Registry.lookup(name) do
          {:ok, definition} -> {:ok, definition}
          :not_found -> {:error, "unknown subagent: #{inspect(name)}"}
        end
    end
  end

  defp build_subagent_config(definition, parent_config, trace_span) do
    new_depth = parent_config.depth + 1
    max_depth = (definition && definition.max_depth) || parent_config.max_depth

    if max_depth != nil and new_depth > max_depth do
      {:error, "maximum subagent depth (#{max_depth}) reached"}
    else
      base_tools =
        ((definition && definition.tools) || parent_config.tools)
        |> Enum.reject(&(&1.name == "run_agent"))

      extra_tools = (definition && definition.extra_tools) || []

      sub_config = %Config{
        model: (definition && definition.model) || parent_config.model,
        system_prompt: (definition && definition.system_prompt) || parent_config.system_prompt,
        tools: base_tools ++ extra_tools,
        depth: new_depth,
        max_depth: max_depth,
        parent_pid: self(),
        subagents: parent_config.subagents,
        transform_context: parent_config.transform_context,
        convert_to_llm: parent_config.convert_to_llm,
        stream_fn: parent_config.stream_fn,
        compaction: parent_config.compaction,
        compact_fn: parent_config.compact_fn,
        trace_context: build_trace_context(parent_config.trace_context, trace_span)
      }

      {:ok, sub_config}
    end
  end

  defp build_trace_context(nil, nil), do: nil
  defp build_trace_context(trace_context, nil), do: trace_context

  defp build_trace_context(trace_context, %PiEx.Tracing.Span{} = trace_span) do
    trace_context =
      case trace_context do
        nil -> PiEx.Tracing.new_context()
        context -> context
      end

    PiEx.Tracing.child_context(trace_context, trace_span)
  end

  # Collect events from the subagent, forward them to the parent server,
  # and return the final assistant text as the tool result.
  defp collect_result(agent_name, depth, parent_server_pid) do
    receive do
      {:agent_event, {:agent_end, messages} = event} ->
        forward_event(parent_server_pid, agent_name, depth, event)
        extract_result(messages)

      {:agent_event, event} ->
        forward_event(parent_server_pid, agent_name, depth, event)
        collect_result(agent_name, depth, parent_server_pid)
    end
  end

  defp forward_event(parent_server_pid, agent_name, depth, event) do
    send(parent_server_pid, {:agent_event, {:subagent_event, agent_name, depth, event}})
  end

  defp extract_result(messages) do
    result_text =
      messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %AssistantMessage{error_message: err} when is_binary(err) ->
          "Subagent error: #{err}"

        %AssistantMessage{content: content} ->
          text =
            content
            |> Enum.filter(&match?(%TextContent{}, &1))
            |> Enum.map(& &1.text)
            |> Enum.join()

          if text != "", do: text, else: nil

        _ ->
          nil
      end) || "Subagent completed with no text output."

    {:ok, %{content: [%TextContent{text: result_text}], details: nil}}
  end

  defp parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "prompt" => %{
          "type" => "string",
          "description" => "The task or question for the subagent."
        },
        "agent" => %{
          "type" => "string",
          "description" =>
            "Optional name of a pre-defined agent. Omit to use a general subagent that inherits the current agent's capabilities."
        }
      },
      "required" => ["prompt"]
    }
  end

  defp build_description(%Config{subagents: subagents, depth: depth, max_depth: max_depth}) do
    depth_info =
      case max_depth do
        nil -> ""
        max -> " (current depth: #{depth}/#{max})"
      end

    all_defs =
      (subagents || [])
      |> Kernel.++(Registry.list())
      |> Enum.uniq_by(& &1.name)

    agent_list =
      case all_defs do
        [] ->
          ""

        defs ->
          entries =
            Enum.map(defs, fn d -> "\n- **#{d.name}**: #{d.description}" end)
            |> Enum.join()

          "\n\nAvailable pre-defined agents:#{entries}"
      end

    """
    Delegate a subtask to a subagent#{depth_info}. The subagent runs independently \
    and returns its final response as text. Use this to parallelize work or to \
    leverage a specialized agent's capabilities.#{agent_list}\
    """
  end
end

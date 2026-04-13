defmodule Example.LangSmithTracingDemo do
  @moduledoc """
  Demonstration of opt-in LangSmith tracing with `PiEx.Agent`.

  This demo is intentionally small and predictable:

  1. A root orchestrator agent receives the user prompt.
  2. The orchestrator delegates to a named `inspector` subagent via `run_agent`.
  3. The subagent calls a custom `project_snapshot` tool to inspect the example project.
  4. The orchestrator summarizes the subagent output for the terminal user.

  When LangSmith tracing is enabled in `:pi_ex` application config, this single
  run produces a useful trace hierarchy:

  - root agent chain
  - orchestrator LLM turn(s)
  - `run_agent` tool span
  - subagent chain
  - subagent LLM turn(s)
  - `project_snapshot` tool span

  ## Running

      cd example
      mix run -e "Example.LangSmithTracingDemo.run()"

  The demo works without LangSmith config, but no traces will be sent until you
  enable tracing in the host `:pi_ex` application.
  """

  alias PiEx.AI.{Model, ProviderParams}
  alias PiEx.AI.Content.TextContent
  alias PiEx.SubAgent.Definition

  @model Model.new("gpt-5.4", "openai_responses",
           provider_params: %ProviderParams.OpenAIResponses{
             http_receive_timeout: 300_000,
             reasoning_effort: "low",
             reasoning_summary: "auto"
           }
         )

  @doc """
  Run the tracing demo and return the final message list.
  """
  @spec run() :: [PiEx.AI.Message.t()]
  def run do
    project_root = project_root()
    config = demo_config(project_root)

    {:ok, agent} = PiEx.Agent.start(config)
    PiEx.Agent.subscribe(agent)
    :ok = PiEx.Agent.prompt(agent, demo_prompt())

    messages = collect_events()
    PiEx.Agent.stop(agent)
    messages
  end

  @doc """
  Build the demo config for the given project root.
  """
  @spec demo_config(String.t()) :: PiEx.Agent.Config.t()
  def demo_config(project_root) do
    inspector = %Definition{
      name: "inspector",
      description: "Inspects the example project using the project_snapshot tool.",
      tools: [project_snapshot_tool(project_root)],
      system_prompt: """
      You are a project inspector. Use the `project_snapshot` tool before answering.
      Report the project root, top-level files, and the dependencies from mix.exs.
      """
    }

    %PiEx.Agent.Config{
      model: @model,
      system_prompt: orchestrator_system_prompt(),
      tools: [],
      subagents: [inspector],
      max_depth: 1
    }
  end

  @doc """
  Return a compact snapshot of the example project for the demo tool.
  """
  @spec project_snapshot(String.t()) :: {:ok, map()} | {:error, term()}
  def project_snapshot(project_root) do
    mix_path = Path.join(project_root, "mix.exs")

    with {:ok, entries} <- File.ls(project_root),
         {:ok, mix_contents} <- File.read(mix_path) do
      {:ok,
       %{
         project_root: project_root,
         top_level_entries: Enum.sort(entries),
         dependencies: extract_dependencies(mix_contents)
       }}
    end
  end

  defp project_snapshot_tool(project_root) do
    %PiEx.Agent.Tool{
      name: "project_snapshot",
      label: "Project Snapshot",
      description: "Inspect the example project and return top-level entries plus Mix deps.",
      parameters: %{
        "type" => "object",
        "properties" => %{},
        "required" => []
      },
      execute: fn _call_id, _params, _opts ->
        with {:ok, snapshot} <- project_snapshot(project_root) do
          {:ok,
           %{
             content: [%TextContent{text: format_snapshot(snapshot)}],
             details: snapshot
           }}
        end
      end
    }
  end

  defp format_snapshot(snapshot) do
    deps =
      case snapshot.dependencies do
        [] -> "(none found)"
        items -> Enum.join(items, ", ")
      end

    """
    Project root: #{snapshot.project_root}
    Top-level entries: #{Enum.join(snapshot.top_level_entries, ", ")}
    Dependencies: #{deps}
    """
    |> String.trim()
  end

  defp extract_dependencies(mix_contents) do
    ~r/\{\s*:(?<name>[a-zA-Z0-9_]+)\s*,/
    |> Regex.scan(mix_contents, capture: :all_names)
    |> Enum.map(&List.first/1)
    |> Enum.reject(&(&1 == "pi_ex"))
    |> Enum.uniq()
  end

  defp demo_prompt do
    """
    Use the `inspector` subagent to inspect this example project, then give me a
    short terminal-friendly summary that covers:

    1. The project root path.
    2. The top-level files/directories.
    3. The dependencies defined in example/mix.exs.

    Delegate first. Do not invent project details.
    """
  end

  defp orchestrator_system_prompt do
    """
    You are an orchestrator agent. Delegate project inspection to the `inspector`
    subagent via `run_agent`, then summarize the result clearly for the user.
    """
  end

  defp collect_events do
    receive do
      {:agent_event, :agent_start} ->
        IO.puts("\n[Tracing demo started]\n")
        collect_events()

      {:agent_event, {:subagent_event, name, depth, :agent_start}} ->
        IO.puts("[Subagent #{agent_label(name, depth)} started]")
        collect_events()

      {:agent_event, {:subagent_event, name, depth, {:tool_execution_start, _id, tool, _args}}} ->
        IO.puts("[#{agent_label(name, depth)} tool → #{tool}]")
        collect_events()

      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_events()

      {:agent_event,
       {:subagent_event, _name, _depth,
        {:message_update, _msg, {:text_delta, _idx, _delta, _partial}}}} ->
        collect_events()

      {:agent_event, {:agent_end, messages}} ->
        IO.puts("\n\n[Tracing demo complete — #{length(messages)} messages]\n")
        messages

      {:agent_event, _other} ->
        collect_events()
    after
      300_000 ->
        IO.puts("\n[Timeout: tracing demo did not finish within 5 minutes]\n")
        []
    end
  end

  defp agent_label(nil, depth), do: "subagent@#{depth}"
  defp agent_label(name, depth), do: "#{name}@#{depth}"

  defp project_root do
    Path.expand("..", __DIR__)
  end
end

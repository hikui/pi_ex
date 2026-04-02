defmodule Example.SubagentDemo do
  @moduledoc """
  Demonstration of the `PiEx` subagent system using direct orchestration.

  ## Architecture

  Three-agent pipeline, all sharing the same OTP supervision tree:

      ┌─────────────────────────────────────────────────────────────────────┐
      │  Orchestrator  (depth 0, max_depth 1)                               │
      │  System prompt: "You are an orchestrator. Delegate via run_agent."  │
      │  Tools: [run_agent]  ← auto-injected by Agent.Server.init/1        │
      │     │                                                                │
      │     ├─── run_agent(agent: "explorer", prompt: "...")                │
      │     │       └── Explorer subagent  (depth 1, max_depth 1)           │
      │     │           Tools: [ls, find, read]  — read-only access         │
      │     │                                                                │
      │     └─── run_agent(agent: "writer", prompt: "...")                  │
      │             └── Writer subagent  (depth 1, max_depth 1)             │
      │                 Tools: [ls, read, write, edit]  — write access      │
      └─────────────────────────────────────────────────────────────────────┘

  Subagents are defined inline in `config.subagents`.  Events from both
  subagents are forwarded to the orchestrator's subscribers as:

      {:agent_event, {:subagent_event, agent_name, depth, original_event}}

  The orchestrator first asks the `explorer` to survey the example project,
  then passes the findings to the `writer` to produce `SUBAGENT_REPORT.md`.

  ## Running

      cd example
      mix run -e "Example.SubagentDemo.run()"

  Requires the OpenAI API key in `config/dev.secret.exs`:

      config :pi_ex, :openai, api_key: "sk-..."
  """

  alias PiEx.SubAgent.Definition
  alias PiEx.AI.{Model, ProviderParams}
  alias PiEx.DeepAgent.Tools.{Edit, Find, Ls, Read, Write}

  @model Model.new("gpt-4o", "openai",
           provider_params: %ProviderParams.OpenAI{
             max_tokens: 4096,
             http_receive_timeout: 300_000
           }
         )

  @doc """
  Run the orchestrator → explorer + writer pipeline.

  Returns the orchestrator's final message list.
  """
  @spec run() :: [PiEx.AI.Message.t()]
  def run do
    project_root = Path.expand(".", __DIR__ |> Path.dirname() |> Path.dirname())
    config = build_config(project_root)

    {:ok, agent} = PiEx.Agent.start(config)
    PiEx.Agent.subscribe(agent)
    :ok = PiEx.Agent.prompt(agent, orchestrator_prompt())

    messages = collect_events()
    PiEx.Agent.stop(agent)
    messages
  end

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  defp build_config(project_root) do
    # Subagents get read-only or read-write tool sets, both sandboxed to project_root
    explorer_tools = [
      Ls.tool(project_root),
      Find.tool(project_root),
      Read.tool(project_root)
    ]

    writer_tools = [
      Ls.tool(project_root),
      Read.tool(project_root),
      Write.tool(project_root),
      Edit.tool(project_root)
    ]

    subagents = [
      %Definition{
        name: "explorer",
        description:
          "Explores and reads files in the project. Use this to gather information " <>
            "about the project structure, source files, or any file contents.",
        tools: explorer_tools,
        system_prompt: """
        You are a file explorer agent. Your job is to read and analyse files in
        a sandboxed project directory. All paths must be relative to the project
        root. Report your findings concisely in plain text — the orchestrator
        will pass them on to the next agent.
        """
      },
      %Definition{
        name: "writer",
        description:
          "Creates and edits files in the project. Use this to write reports, " <>
            "summaries, or any output documents.",
        tools: writer_tools,
        system_prompt: """
        You are a technical report writer agent. Your job is to produce
        well-structured Markdown documents. Write the file using the `write` tool
        and confirm the path when done.
        """
      }
    ]

    %PiEx.Agent.Config{
      model: @model,
      system_prompt: orchestrator_system_prompt(),
      # No file tools for the orchestrator — it delegates everything
      tools: [],
      subagents: subagents,
      max_depth: 1
    }
  end

  # ---------------------------------------------------------------------------
  # Prompts
  # ---------------------------------------------------------------------------

  defp orchestrator_system_prompt do
    """
    You are an orchestrator agent. You coordinate work by delegating to
    specialised subagents via the `run_agent` tool. You do not have direct
    file access — all file operations must go through subagents.

    Workflow:
    1. Use the `explorer` subagent to discover the project structure and
       gather information about the source files.
    2. Use the `writer` subagent to turn those findings into a Markdown report.

    Always pass the full findings from step 1 into the prompt for step 2 so
    the writer has all the context it needs.
    """
  end

  defp orchestrator_prompt do
    """
    Survey this project and produce a file called SUBAGENT_REPORT.md.

    Steps:
    1. Ask the `explorer` to:
       - List the top-level files and directories (path ".").
       - Find all Elixir source files (pattern "**/*.{ex,exs}").
       - Read mix.exs to understand the project's dependencies.
    2. Ask the `writer` to create SUBAGENT_REPORT.md at path "SUBAGENT_REPORT.md"
       containing:
       - A short project overview.
       - A list of all Elixir source files found.
       - The list of dependencies from mix.exs.

    Important: all paths are relative to the project root, so use ".", "lib/", "mix.exs" etc.
    Do NOT prefix paths with "example/".
    """
  end

  # ---------------------------------------------------------------------------
  # Event collection
  # ---------------------------------------------------------------------------

  defp collect_events(indent \\ "") do
    receive do
      # ── Orchestrator lifecycle ─────────────────────────────────────────────
      {:agent_event, :agent_start} ->
        IO.puts("\n#{indent}━━━ Orchestrator started ━━━\n")
        collect_events(indent)

      {:agent_event, :turn_start} ->
        IO.puts("\n#{indent}── Turn start ──")
        collect_events(indent)

      # ── Orchestrator text ──────────────────────────────────────────────────
      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_events(indent)

      # ── Subagent events (forwarded from subagents) ─────────────────────────
      {:agent_event, {:subagent_event, name, depth, :agent_start}} ->
        label = agent_label(name, depth)
        IO.puts("\n#{indent}  ┌── #{label} started")
        collect_events(indent)

      {:agent_event, {:subagent_event, name, depth, {:agent_end, msgs}}} ->
        label = agent_label(name, depth)
        IO.puts("\n#{indent}  └── #{label} done (#{length(msgs)} messages)")
        collect_events(indent)

      {:agent_event,
       {:subagent_event, name, depth, {:message_update, _msg, {:text_start, _idx, _partial}}}} ->
        label = agent_label(name, depth)
        IO.write("\n#{indent}  [#{label}] ")
        collect_events(indent)

      {:agent_event,
       {:subagent_event, _name, _depth,
        {:message_update, _msg, {:text_delta, _idx, delta, _partial}}}} ->
        IO.write(delta)
        collect_events(indent)

      {:agent_event, {:subagent_event, name, depth, {:tool_execution_start, _id, tool, args}}} ->
        label = agent_label(name, depth)
        IO.puts("\n#{indent}  [#{label}] → #{tool} #{inspect(args, limit: 3)}")
        collect_events(indent)

      {:agent_event, {:subagent_event, name, depth, {:tool_execution_end, _id, tool, _, err}}} ->
        label = agent_label(name, depth)
        status = if err, do: "ERROR", else: "ok"
        IO.puts("#{indent}  [#{label}] ← #{tool} #{status}")
        collect_events(indent)

      {:agent_event, {:subagent_event, _name, _depth, _other}} ->
        collect_events(indent)

      # ── Tool execution (orchestrator calling run_agent) ────────────────────
      {:agent_event, {:tool_execution_start, _id, "run_agent", %{"agent" => ag} = args}} ->
        IO.puts(
          "\n#{indent}[run_agent → #{ag}] prompt: #{String.slice(Map.get(args, "prompt", ""), 0, 80)}…"
        )

        collect_events(indent)

      {:agent_event, {:tool_execution_start, _id, "run_agent", args}} ->
        IO.puts(
          "\n#{indent}[run_agent] prompt: #{String.slice(Map.get(args, "prompt", ""), 0, 80)}…"
        )

        collect_events(indent)

      {:agent_event, {:tool_execution_end, _id, "run_agent", _result, false}} ->
        IO.puts("#{indent}[run_agent] ✓ done")
        collect_events(indent)

      {:agent_event, {:tool_execution_end, _id, "run_agent", _result, true}} ->
        IO.puts("#{indent}[run_agent] ✗ error")
        collect_events(indent)

      # ── Completion ─────────────────────────────────────────────────────────
      {:agent_event, {:agent_end, messages}} ->
        IO.puts("\n\n#{indent}━━━ Orchestrator done — #{length(messages)} messages ━━━\n")
        messages

      # ── Errors ─────────────────────────────────────────────────────────────
      {:agent_event, {:agent_error, reason}} ->
        IO.puts("\n#{indent}[Error: #{inspect(reason)}]")
        []

      {:agent_event, _other} ->
        collect_events(indent)
    after
      300_000 ->
        IO.puts("\n[Timeout — agent did not finish within 5 minutes]")
        []
    end
  end

  defp agent_label(nil, depth), do: "subagent@#{depth}"
  defp agent_label(name, depth), do: "#{name}@#{depth}"
end

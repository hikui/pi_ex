defmodule Example.SkillsDemo do
  @moduledoc """
  Demonstration of the `PiEx.DeepAgent` skills feature.

  The agent is given a single `skills_root` pointing at
  `example/skills/`. One skill is present there:

      elixir-code-reviewer/
        SKILL.md          — workflow instructions
        style-guide.md    — coding style rules
        anti-patterns.md  — common Elixir anti-patterns to detect

  The `SKILL.md` is listed in the system prompt (name + description +
  file path). When the task matches the skill's description the LLM
  loads the full `SKILL.md` via the `read` tool, then follows the
  workflow — which in turn directs it to read the two reference
  markdown files, scan the source tree, and write `REVIEW.md`.

  The skill files live outside the sandboxed `project_root`
  (`example/`), so the `read` tool's `allowed_paths` mechanism is
  exercised automatically by `PiEx.DeepAgent`.

  ## Running

      cd example
      mix run -e "Example.SkillsDemo.run()"

  Requires the OpenAI API key in `config/dev.exs` or the environment:

      export OPENAI_API_KEY=sk-...
  """
  alias PiEx.AI.{Model, ProviderParams}

  @model Model.new("gpt-5.4", "openai_responses",
           provider_params: %ProviderParams.OpenAIResponses{
             reasoning_effort: "low",
             reasoning_summary: "auto"
           }
         )

  @doc """
  Start the skills-enabled agent, prompt it to review the codebase,
  stream events to stdout, and return the final messages list.
  """
  @spec run() :: [PiEx.AI.Message.t()]
  def run do
    # The sandbox: only files inside example/ can be written or read by
    # default.  The skills directory sits one level above example/ —
    # DeepAgent automatically allows the LLM to read skill files despite
    # them being outside the sandbox.
    project_root = Path.expand(".", __DIR__ |> Path.dirname() |> Path.dirname())
    skills_root = Path.expand("skills", __DIR__ |> Path.dirname() |> Path.dirname())

    config = %PiEx.DeepAgent.Config{
      model: @model,
      project_root: project_root,
      skills_root: skills_root
    }

    {:ok, agent} = PiEx.DeepAgent.start(config)
    PiEx.Agent.subscribe(agent)
    :ok = PiEx.Agent.prompt(agent, review_prompt())

    messages = collect_events()
    PiEx.Agent.stop(agent)
    messages
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  defp review_prompt do
    """
    Review the Elixir source files in this project and produce a `REVIEW.md` report.

    Use the elixir-code-reviewer skill to guide your workflow.
    """
  end

  # ---------------------------------------------------------------------------
  # Event loop
  # ---------------------------------------------------------------------------

  # Prints every meaningful agent event so the terminal shows the full
  # picture: thinking blocks, streamed text deltas, tool calls with their
  # arguments and results, and the final completion.
  defp collect_events do
    receive do
      # ── Lifecycle ──────────────────────────────────────────────────────────
      {:agent_event, :agent_start} ->
        IO.puts("\n━━━ Agent started ━━━\n")
        collect_events()

      {:agent_event, :turn_start} ->
        IO.puts("\n── Turn start ──")
        collect_events()

      {:agent_event, {:turn_end, _msg, []}} ->
        IO.puts("\n── Turn end (no tool calls) ──")
        collect_events()

      {:agent_event, {:turn_end, _msg, tool_results}} ->
        IO.puts("\n── Turn end (#{length(tool_results)} tool result(s)) ──")
        collect_events()

      # ── Thinking deltas ────────────────────────────────────────────────────
      {:agent_event, {:message_update, _msg, {:thinking_start, _idx, _partial}}} ->
        IO.puts("\n[Thinking ▶]")
        collect_events()

      {:agent_event, {:message_update, _msg, {:thinking_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_events()

      {:agent_event, {:message_update, _msg, {:thinking_end, _idx, _content, _partial}}} ->
        IO.puts("\n[Thinking ◀]")
        collect_events()

      # ── Text deltas ────────────────────────────────────────────────────────
      {:agent_event, {:message_update, _msg, {:text_start, _idx, _partial}}} ->
        IO.puts("\n[Text ▶]")
        collect_events()

      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_events()

      {:agent_event, {:message_update, _msg, {:text_end, _idx, _content, _partial}}} ->
        IO.puts("\n[Text ◀]")
        collect_events()

      # ── Tool call streaming ────────────────────────────────────────────────
      {:agent_event, {:message_update, _msg, {:toolcall_end, _idx, tool_call, _partial}}} ->
        IO.puts(
          "\n[Tool call: #{tool_call.name}] args: #{inspect(tool_call.arguments, pretty: true, limit: 10)}"
        )

        collect_events()

      # ── Tool execution ─────────────────────────────────────────────────────
      {:agent_event, {:tool_execution_start, _id, name, args}} ->
        IO.puts("\n[Executing: #{name}] #{inspect(args, limit: 6)}")
        collect_events()

      {:agent_event, {:tool_execution_end, _id, name, result, false}} ->
        summary = tool_result_summary(result)
        IO.puts("[Done: #{name}] #{summary}")
        collect_events()

      {:agent_event, {:tool_execution_end, _id, name, result, true}} ->
        summary = tool_result_summary(result)
        IO.puts("[ERROR: #{name}] #{summary}")
        collect_events()

      # ── Compaction ─────────────────────────────────────────────────────────
      {:agent_event, :compaction_start} ->
        IO.puts("\n[Compaction: summarising context…]")
        collect_events()

      {:agent_event, {:compaction_end, _msg}} ->
        IO.puts("[Compaction: done]")
        collect_events()

      {:agent_event, {:compaction_error, reason}} ->
        IO.puts("[Compaction error: #{inspect(reason)}]")
        collect_events()

      # ── Errors ─────────────────────────────────────────────────────────────
      {:agent_event, {:message_end, %PiEx.AI.Message.AssistantMessage{error_message: message}}}
      when is_binary(message) ->
        IO.puts("\n[Model error: #{message}]")
        collect_events()

      {:agent_event, {:agent_error, reason}} ->
        IO.puts("\n[Agent error: #{inspect(reason)}]")
        []

      # ── Done ───────────────────────────────────────────────────────────────
      {:agent_event, {:agent_end, messages}} ->
        IO.puts("\n\n━━━ Agent done — #{length(messages)} messages ━━━\n")
        messages

      # ── Ignore everything else (message_start, message_end, unmatched) ────
      {:agent_event, _other} ->
        collect_events()
    after
      300_000 ->
        IO.puts("\n[Timeout — agent did not finish within 5 minutes]")
        []
    end
  end

  # Extract a short human-readable summary from a tool result.
  defp tool_result_summary(%{content: content}) when is_list(content) do
    text =
      content
      |> Enum.filter(&match?(%PiEx.AI.Content.TextContent{}, &1))
      |> Enum.map(& &1.text)
      |> Enum.join()

    preview = String.slice(text, 0, 120)
    if String.length(text) > 120, do: preview <> "…", else: preview
  end

  defp tool_result_summary(other), do: inspect(other, limit: 5)
end

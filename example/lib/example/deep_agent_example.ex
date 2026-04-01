defmodule Example.DeepAgentExample do
  @moduledoc """
  End-to-end demonstration of `PiEx.DeepAgent` as a "Project Code Analyst".

  Demonstrates three key capabilities:

  1. **Built-in filesystem tools** — `ls`, `find`, `read`, `grep`, `write`, `edit`,
     all provided automatically by `PiEx.DeepAgent`.
  2. **Custom tools** — a `mix_test` tool added via `extra_tools` in the config,
     showing how to extend the agent with project-specific capabilities.
  3. **Path security** — every file operation is sandboxed to `project_root` by
     `PiEx.DeepAgent.PathGuard`, which rejects traversal and absolute-path escapes.

  The agent explores the `example/` directory itself, runs `mix test`, and writes
  an `ANALYSIS.md` summary of all its findings.

  ## Running

      mix run -e "Example.DeepAgentExample.run()"

  Requires the OpenAI API key to be set:

      config :pi_ex, :openai, api_key: "sk-..."   # in config/dev.secret.exs
      # or
      export OPENAI_API_KEY=sk-...

  The demo also shows the model-centric provider params API by configuring
  `reasoning_effort` on `PiEx.AI.Model`.
  """

  alias PiEx.DeepAgent.PathGuard
  alias PiEx.AI.{Model, ProviderParams}

  @model Model.new("gpt-5.4", "openai_responses",
           provider_params: %ProviderParams.OpenAIResponses{
             reasoning_effort: "low",
             reasoning_summary: "auto"
           }
         )

  @doc """
  Build config, start the agent, subscribe, send the analyst prompt,
  collect streamed events until completion, then stop the agent.

  Returns the final messages list.
  """
  @spec run() :: [PiEx.AI.Message.t()]
  def run do
    project_root = Path.expand("../..", __DIR__)
    config = build_config(project_root)

    {:ok, agent} = PiEx.DeepAgent.start(config)
    PiEx.Agent.subscribe(agent)
    :ok = PiEx.Agent.prompt(agent, analyst_prompt())

    messages = collect_events()
    PiEx.Agent.stop(agent)
    messages
  end

  # ---------------------------------------------------------------------------
  # Config
  # ---------------------------------------------------------------------------

  defp build_config(project_root) do
    %PiEx.DeepAgent.Config{
      model: @model,
      project_root: project_root,
      extra_tools: [mix_test_tool(project_root)]
    }
  end

  # ---------------------------------------------------------------------------
  # Custom tool: mix_test
  # ---------------------------------------------------------------------------

  # Returns a Tool that runs `mix test` in the project_root directory.
  # Non-zero exits return {:ok, ...} (not {:error, ...}) so the LLM sees the
  # failure output and can reason about it rather than receiving an opaque error.
  defp mix_test_tool(project_root) do
    %PiEx.Agent.Tool{
      name: "mix_test",
      label: "Run Mix Tests",
      description: """
      Run `mix test` in the project root. Returns the full test output.
      Use the optional `filter` param to run a specific file or tag.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "filter" => %{
            "type" => "string",
            "description" =>
              "Optional test file or tag filter (e.g. \"test/example_test.exs\" or \"--only tag:foo\")."
          }
        },
        "required" => []
      },
      execute: fn _call_id, params, _opts ->
        filter = Map.get(params, "filter")
        args = if filter, do: ["test", filter], else: ["test"]

        case System.cmd("mix", args,
               cd: project_root,
               stderr_to_stdout: true,
               env: [{"MIX_ENV", "test"}]
             ) do
          {output, 0} ->
            {:ok, %{content: [%PiEx.AI.Content.TextContent{text: output}], details: nil}}

          {output, code} ->
            {:ok,
             %{
               content: [%PiEx.AI.Content.TextContent{text: "Exit #{code}:\n#{output}"}],
               details: %{exit_code: code}
             }}
        end
      end
    }
  end

  # ---------------------------------------------------------------------------
  # Prompt
  # ---------------------------------------------------------------------------

  defp analyst_prompt do
    """
    You are a Project Code Analyst. Explore this Elixir project and produce a
    thorough summary. Follow these steps **in order**, using the specified tool
    for each step:

    1. Use `ls` to list the project root directory. Pass `path: "."` (or omit the
       path entirely). Do NOT use an absolute path like "/".
    2. Use `find` with pattern `**/*.ex` to discover all Elixir source files.
    3. Use `read` to read `mix.exs`.
    4. Use `grep` to search for `defmodule` across all source files.
    5. Use `mix_test` to run the full test suite and record the outcome.
    6. Use `write` to create `ANALYSIS.md` with a well-structured summary that
       covers: project structure, mix.exs contents, all module names, and test results.

    Important: all paths must be relative to the project root (e.g. "." or "lib/foo.ex"),
    never absolute paths like "/etc" or "/".

    Complete all 6 steps before finishing.
    """
  end

  # ---------------------------------------------------------------------------
  # Event collection
  # ---------------------------------------------------------------------------

  # Tail-recursive receive loop. Prints streamed text and tool activity to stdout,
  # and returns the final messages list when the agent ends or times out.
  defp collect_events do
    receive do
      {:agent_event, :agent_start} ->
        IO.puts("\n[Agent started]\n")
        collect_events()

      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_events()

      {:agent_event, {:tool_execution_start, _id, name, args}} ->
        IO.puts("\n\n[Tool call: #{name}] #{inspect(args, limit: 3)}")
        collect_events()

      {:agent_event, {:tool_execution_end, _id, name, _result, is_error}} ->
        status = if is_error, do: "ERROR", else: "ok"
        IO.puts("[Tool done: #{name}] → #{status}")
        collect_events()

      {:agent_event, {:agent_end, messages}} ->
        IO.puts("\n\n[Agent done — #{length(messages)} messages]\n")
        messages

      {:agent_event, _other} ->
        # Ignore turn_start, turn_end, message_start, message_end, etc.
        collect_events()
    after
      300_000 ->
        IO.puts("\n[Timeout: agent did not finish within 5 minutes]\n")
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Path security note (documentation only — never called from run/0)
  # ---------------------------------------------------------------------------

  # This function exists as executable documentation. It shows how PathGuard
  # sandboxes file access. You can call it manually in IEx to verify the behaviour.
  #
  # Example:
  #   iex> Example.DeepAgentExample.__path_security_demo__()
  defp path_security_note do
    root = Path.expand("../..", __DIR__)

    # Traversal attempt is rejected:
    {:error, "path is outside project root"} = PathGuard.resolve(root, "../etc/passwd")

    # Absolute path outside the root is also rejected:
    {:error, "path is outside project root"} = PathGuard.resolve(root, "/etc/hosts")

    # A valid relative path is allowed:
    {:ok, _} = PathGuard.resolve(root, "mix.exs")

    :ok
  end
end

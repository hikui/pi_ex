defmodule PiEx.DeepAgent do
  @moduledoc """
  Pre-configured agent harness with 6 built-in LLM tools:
  `ls`, `find`, `read`, `grep`, `write`, `edit`.

  All file operations are sandboxed to a `project_root` directory.

  ## Usage

      config = %PiEx.DeepAgent.Config{
        model: %PiEx.AI.Model{provider: :anthropic, model: "claude-opus-4-6"},
        project_root: "/path/to/project"
      }

      {:ok, pid} = PiEx.DeepAgent.start(config)
      PiEx.Agent.prompt(pid, "List the files in the src directory")

  See `PiEx.Agent` for the full interaction API (prompt, subscribe, steer, abort, etc.).
  """

  alias PiEx.DeepAgent.{Config, Skills, SystemPrompt}
  alias PiEx.DeepAgent.Tools.{Edit, Find, Grep, Ls, Read, Write}

  @doc """
  Start a `PiEx.DeepAgent` supervised agent process.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec start(Config.t()) :: {:ok, pid()} | {:error, String.t()}
  def start(%Config{} = config) do
    with {:ok, canonical} <- Config.validate(config),
         {:ok, skills} <- Skills.load_all(canonical.skills_root) do
      root = canonical.project_root
      skill_file_paths = Enum.map(skills, & &1.file_path)
      built_in = built_in_tools(root, allowed_paths: skill_file_paths)
      all_tools = built_in ++ canonical.extra_tools

      system_prompt =
        canonical.system_prompt ||
          SystemPrompt.build(all_tools, skills: skills)

      agent_config = %PiEx.Agent.Config{
        model: canonical.model,
        system_prompt: system_prompt,
        tools: all_tools
      }

      PiEx.Agent.start(agent_config)
    end
  end

  @doc """
  Start a `PiEx.DeepAgent` supervised agent process, raising on error.
  """
  @spec start!(Config.t()) :: pid()
  def start!(%Config{} = config) do
    case start(config) do
      {:ok, pid} -> pid
      {:error, reason} -> raise "PiEx.DeepAgent.start!/1 failed: #{reason}"
    end
  end

  @doc "Return the list of built-in tools for the given `project_root`."
  @spec built_in_tools(String.t(), keyword()) :: [PiEx.Agent.Tool.t()]
  def built_in_tools(project_root, opts \\ []) do
    allowed_paths = Keyword.get(opts, :allowed_paths, [])

    [
      Ls.tool(project_root),
      Find.tool(project_root),
      Read.tool(project_root, allowed_paths: allowed_paths),
      Grep.tool(project_root),
      Write.tool(project_root),
      Edit.tool(project_root)
    ]
  end
end

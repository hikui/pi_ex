defmodule PiEx.DeepAgent.SystemPrompt do
  @moduledoc "Builds the default system prompt for `PiEx.DeepAgent`."

  @doc """
  Build a system prompt string from a list of tools and optional extra content.

  Options:
  - `:append_system_prompt` — string appended at the end
  - `:skills` — list of `%PiEx.DeepAgent.Skill{}` to include in the prompt
  """
  @spec build([PiEx.Agent.Tool.t()], keyword()) :: String.t()
  def build(tools, opts \\ []) do
    append = Keyword.get(opts, :append_system_prompt, "")
    skills = Keyword.get(opts, :skills, [])

    tool_section =
      tools
      |> Enum.map(fn t ->
        "- **#{t.name}**: #{String.trim(t.description)}"
      end)
      |> Enum.join("\n")

    base = """
    You are a general-purpose AI agent with access to tools that let you read and modify
    a software project. You operate within a sandboxed project directory and all file paths
    for project files are relative to the project root.

    ## Available tools

    #{tool_section}

    ## Guidelines

    - Prefer `read`, `grep`, and `find` for discovery before making changes.
    - Use relative paths for project files inside the sandboxed project root.
    - Avoid unnecessary writes; only write when explicitly required.
    - When editing, use the `edit` tool rather than rewriting entire files.
    - Always verify a file exists before attempting to edit it.
    """

    if append != "" do
      String.trim_trailing(base) <> "\n\n" <> append
    else
      base
    end
    |> maybe_append_skills(skills)
  end

  defp maybe_append_skills(prompt, []), do: prompt

  defp maybe_append_skills(prompt, skills) do
    visible =
      Enum.reject(skills, & &1.disable_model_invocation)

    case visible do
      [] ->
        prompt

      _ ->
        skill_entries =
          visible
          |> Enum.map(fn s ->
            """
              <skill>
                <name>#{s.name}</name>
                <description>#{s.description}</description>
                <location>#{s.file_path}</location>
              </skill>\
            """
          end)
          |> Enum.join("\n")

        skills_block = """

        <available_skills>
        #{skill_entries}
        </available_skills>

        Skill `<location>` values are absolute file paths. Pass the `<location>` to the \
        `read` tool exactly as written when loading a skill file.

        When a task matches a skill's description, use the `read` tool to load the \
        SKILL.md file at its `<location>` and follow its instructions.\
        """

        String.trim_trailing(prompt) <> skills_block
    end
  end
end

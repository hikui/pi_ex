defmodule PiEx.DeepAgent.SystemPromptTest do
  use ExUnit.Case, async: true

  alias PiEx.Agent.Tool
  alias PiEx.DeepAgent.Skill
  alias PiEx.DeepAgent.SystemPrompt

  test "explains that project paths are relative and skill locations stay absolute" do
    tools = [
      %Tool{
        name: "read",
        label: "Read File",
        description: "Read files.",
        parameters: %{},
        execute: fn _, _, _ -> {:ok, %{}} end
      }
    ]

    skill = %Skill{
      name: "elixir-code-reviewer",
      description: "Reviews Elixir code.",
      file_path: "/tmp/example/skills/elixir-code-reviewer/SKILL.md",
      base_dir: "/tmp/example/skills/elixir-code-reviewer"
    }

    prompt = SystemPrompt.build(tools, skills: [skill])

    assert prompt =~ "Use relative paths for project files inside the sandboxed project root."

    assert prompt =~
             "Skill `<location>` values are absolute file paths. Pass the `<location>` to the `read` tool exactly as written"

    assert prompt =~ "<location>/tmp/example/skills/elixir-code-reviewer/SKILL.md</location>"
  end
end

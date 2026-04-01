defmodule Example.SkillsDemoTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Example.SkillsDemo

  test "renders the thinking opener before the first thinking delta" do
    output =
      capture_io(fn ->
        SkillsDemo.render_state()
        |> SkillsDemo.render_thinking_delta("Locating skill paths")
        |> SkillsDemo.render_thinking_end()
      end)

    assert output =~ "[Thinking ▶]"
    assert output =~ "Locating skill paths"
    assert output =~ "[Thinking ◀]"
    assert String.contains?(output, "[Thinking ▶]\nLocating skill paths")
  end

  test "does not print the thinking opener twice when delta arrives after start" do
    output =
      capture_io(fn ->
        SkillsDemo.render_state()
        |> SkillsDemo.render_thinking_start()
        |> SkillsDemo.render_thinking_delta("Reasoning")
        |> SkillsDemo.render_thinking_end()
      end)

    assert output =~ "[Thinking ▶]"
    assert output =~ "[Thinking ◀]"
    assert length(Regex.scan(~r/\[Thinking ▶\]/, output)) == 1
  end
end

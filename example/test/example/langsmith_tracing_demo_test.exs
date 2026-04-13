defmodule Example.LangSmithTracingDemoTest do
  use ExUnit.Case, async: true

  alias Example.LangSmithTracingDemo

  describe "project_snapshot/1" do
    test "returns top-level entries and dependencies for the example project" do
      project_root = Path.expand("../..", __DIR__)

      assert {:ok, snapshot} = LangSmithTracingDemo.project_snapshot(project_root)
      assert snapshot.project_root == project_root
      assert "lib" in snapshot.top_level_entries
      assert "mix.exs" in snapshot.top_level_entries
      assert "jason" not in snapshot.dependencies
    end
  end

  describe "demo_config/1" do
    test "builds an orchestrator with one tracing-oriented subagent" do
      project_root = Path.expand("../..", __DIR__)
      config = LangSmithTracingDemo.demo_config(project_root)

      assert config.max_depth == 1
      assert config.tools == []
      assert length(config.subagents) == 1

      [inspector] = config.subagents
      assert inspector.name == "inspector"
      assert String.contains?(inspector.description, "project")
      assert Enum.any?(inspector.tools, &(&1.name == "project_snapshot"))
    end
  end
end

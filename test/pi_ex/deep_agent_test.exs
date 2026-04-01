defmodule PiEx.DeepAgentTest do
  use ExUnit.Case, async: false

  alias PiEx.DeepAgent
  alias PiEx.DeepAgent.Config
  alias PiEx.AI.ProviderParams

  @model %PiEx.AI.Model{provider: "anthropic", id: "claude-haiku-4-5-20251001"}

  setup do
    dir = System.tmp_dir!() |> Path.join("deep_agent_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  describe "start/1" do
    test "returns {:ok, pid} with valid config", %{dir: dir} do
      config = %Config{model: @model, project_root: dir}
      assert {:ok, pid} = DeepAgent.start(config)
      assert is_pid(pid)
      PiEx.Agent.stop(pid)
    end

    test "returns {:error, _} with non-existent project_root" do
      config = %Config{
        model: @model,
        project_root: "/nonexistent/path/#{:erlang.unique_integer()}"
      }

      assert {:error, _reason} = DeepAgent.start(config)
    end

    test "returns {:error, _} when project_root is a file, not a directory", %{dir: dir} do
      file_path = Path.join(dir, "not_a_dir.txt")
      File.write!(file_path, "content")
      config = %Config{model: @model, project_root: file_path}
      assert {:error, _reason} = DeepAgent.start(config)
    end

    test "passes model provider params through to the agent config", %{dir: dir} do
      params = %ProviderParams.OpenAIResponses{api_key: "sk-openai", reasoning_effort: "low"}
      model = PiEx.AI.Model.new("gpt-5.4", "openai_responses", provider_params: params)

      config = %Config{model: model, project_root: dir}
      assert {:ok, pid} = DeepAgent.start(config)

      state = :sys.get_state(pid)
      assert state.config.model.provider_params == params

      PiEx.Agent.stop(pid)
    end
  end

  describe "built-in tools" do
    test "system prompt contains all built-in tool names", %{dir: dir} do
      tools = DeepAgent.built_in_tools(dir)
      tool_names = Enum.map(tools, & &1.name)
      assert "ls" in tool_names
      assert "find" in tool_names
      assert "read" in tool_names
      assert "grep" in tool_names
      assert "write" in tool_names
      assert "edit" in tool_names
    end

    test "system prompt built from built-in tools includes each tool name", %{dir: dir} do
      tools = DeepAgent.built_in_tools(dir)
      prompt = PiEx.DeepAgent.SystemPrompt.build(tools)

      for tool <- tools do
        assert prompt =~ tool.name
      end
    end
  end

  describe "start!/1" do
    test "raises on invalid config" do
      config = %Config{model: @model, project_root: "/nonexistent/#{:erlang.unique_integer()}"}
      assert_raise RuntimeError, ~r/failed/, fn -> DeepAgent.start!(config) end
    end
  end
end

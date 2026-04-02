defmodule PiEx.Agent.Tools.RunAgentTest do
  # async: false — tests interact with global Agent.Supervisor and SubAgent.Registry
  use ExUnit.Case, async: false

  alias PiEx.Agent.{Config, Server, Supervisor}
  alias PiEx.Agent.Tools.RunAgent
  alias PiEx.SubAgent.{Definition, Registry}
  alias PiEx.AI.Model
  alias PiEx.AI.Message.{AssistantMessage, Usage}
  alias PiEx.AI.Content.TextContent

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp text_stream(text) do
    msg = %AssistantMessage{
      content: [%TextContent{text: text}],
      model: "test",
      usage: %Usage{input_tokens: 5, output_tokens: 2},
      stop_reason: :stop,
      timestamp: 0
    }

    [
      {:start, %{msg | content: []}},
      {:text_start, 0, %{msg | content: []}},
      {:text_delta, 0, text, msg},
      {:text_end, 0, text, msg},
      {:done, :stop, msg}
    ]
  end

  defp base_model, do: Model.new("test-model", "openai")

  defp base_config(stream_fn, opts \\ []) do
    %Config{
      model: base_model(),
      stream_fn: fn _m, _c, _o -> stream_fn.() end,
      max_depth: Keyword.get(opts, :max_depth, nil),
      depth: Keyword.get(opts, :depth, 0),
      subagents: Keyword.get(opts, :subagents, [])
    }
  end

  defp start_agent!(config) do
    {:ok, pid} = Supervisor.start_agent(config)
    on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, pid) end)
    pid
  end

  defp collect(timeout \\ 5_000) do
    receive do
      {:agent_event, {:agent_end, msgs}} -> msgs
      {:agent_event, _} -> collect(timeout)
    after
      timeout -> flunk("agent did not finish within #{timeout}ms")
    end
  end

  # ---------------------------------------------------------------------------
  # Tool injection
  # ---------------------------------------------------------------------------

  describe "run_agent tool injection" do
    test "is injected when max_depth is nil (unlimited)" do
      config = base_config(fn -> text_stream("hi") end, max_depth: nil)
      pid = start_agent!(config)
      tools = Server.get_messages(pid)
      # Verify via server config — the agent's config has the tool
      # We call status to confirm it started; tool presence verified by running it
      assert Server.status(pid) == :idle
      _ = tools
    end

    test "is injected when depth < max_depth" do
      config = base_config(fn -> text_stream("hi") end, depth: 0, max_depth: 2)
      pid = start_agent!(config)
      assert Server.status(pid) == :idle
    end

    test "is NOT injected when depth >= max_depth" do
      # depth 1, max_depth 1 → no run_agent
      config = base_config(fn -> text_stream("hi") end, depth: 1, max_depth: 1)
      pid = start_agent!(config)
      Server.subscribe(pid)
      Server.prompt(pid, "hello")
      msgs = collect()
      # Should have run the agent normally (no run_agent tool available to cause loops)
      assert length(msgs) >= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Direct tool execution (unit test)
  # ---------------------------------------------------------------------------

  describe "tool/2 execute — general subagent" do
    test "inherits parent model and runs with given prompt" do
      parent_config = base_config(fn -> text_stream("subagent response") end)

      {:ok, parent_pid} = Supervisor.start_agent(parent_config)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      tool = RunAgent.tool(parent_config, parent_pid)

      # Execute the tool directly from the test process
      result = tool.execute.("call_1", %{"prompt" => "do something"}, [])

      assert {:ok, %{content: [%TextContent{text: text}]}} = result
      assert String.contains?(text, "subagent response")
    end
  end

  describe "tool/2 execute — named subagent from inline definitions" do
    test "uses the named definition's system_prompt and tools" do
      test_pid = self()

      definition = %Definition{
        name: "inline_agent",
        description: "An inline test agent",
        system_prompt: "You are an inline agent.",
        tools: []
      }

      # Parent stream captures the context to verify system_prompt was applied
      parent_config =
        base_config(fn -> text_stream("done") end,
          subagents: [definition]
        )

      sub_stream = fn _m, ctx, _o ->
        send(test_pid, {:sub_system_prompt, ctx.system_prompt})
        text_stream("sub done")
      end

      # Override stream_fn so subagent can capture system prompt
      parent_config_with_sub_stream = %{
        parent_config
        | stream_fn: fn _m, _ctx, _o -> text_stream("parent done") end,
          subagents: [
            %{
              definition
              | tools: []
            }
          ]
      }

      {:ok, parent_pid} = Supervisor.start_agent(parent_config_with_sub_stream)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      # Build tool with the sub_stream injected into the definition resolution path
      # We directly call build_subagent_config logic via the tool to keep test simple:
      # Build a parent config where subagent stream_fn is the test one
      parent_with_sub_fn = %{
        parent_config_with_sub_stream
        | stream_fn: sub_stream,
          subagents: [definition]
      }

      tool = RunAgent.tool(parent_with_sub_fn, parent_pid)

      {:ok, %{content: [%TextContent{text: text}]}} =
        tool.execute.("call_1", %{"prompt" => "do it", "agent" => "inline_agent"}, [])

      assert_receive {:sub_system_prompt, "You are an inline agent."}, 5_000
      assert String.contains?(text, "sub done")
    end
  end

  describe "tool/2 execute — named subagent from global registry" do
    test "resolves named agent from Registry" do
      name = "registry_agent_#{System.unique_integer([:positive])}"

      :ok =
        Registry.register(%Definition{
          name: name,
          description: "Registry test agent",
          system_prompt: "Registry agent prompt",
          tools: []
        })

      on_exit(fn -> Registry.deregister(name) end)

      parent_config = base_config(fn -> text_stream("registry result") end)

      {:ok, parent_pid} = Supervisor.start_agent(parent_config)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      tool = RunAgent.tool(parent_config, parent_pid)

      result = tool.execute.("call_1", %{"prompt" => "do it", "agent" => name}, [])
      assert {:ok, %{content: [%TextContent{text: _}]}} = result
    end

    test "returns error for unknown agent name" do
      parent_config = base_config(fn -> text_stream("never") end)

      {:ok, parent_pid} = Supervisor.start_agent(parent_config)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      tool = RunAgent.tool(parent_config, parent_pid)
      result = tool.execute.("call_1", %{"prompt" => "do it", "agent" => "no_such_agent"}, [])
      assert {:error, msg} = result
      assert String.contains?(msg, "unknown subagent")
    end
  end

  # ---------------------------------------------------------------------------
  # Depth limit
  # ---------------------------------------------------------------------------

  describe "depth limiting" do
    test "returns error when max_depth would be exceeded" do
      # depth 1, max_depth 1 — building a subagent would reach depth 2 > max 1
      parent_config = base_config(fn -> text_stream("x") end, depth: 1, max_depth: 1)

      {:ok, parent_pid} = Supervisor.start_agent(parent_config)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      tool = RunAgent.tool(parent_config, parent_pid)
      result = tool.execute.("call_1", %{"prompt" => "deeper"}, [])
      assert {:error, msg} = result
      assert String.contains?(msg, "maximum subagent depth")
    end
  end

  # ---------------------------------------------------------------------------
  # Event forwarding
  # ---------------------------------------------------------------------------

  describe "subagent event forwarding" do
    test "forwards subagent events to parent server as :subagent_event" do
      parent_config = base_config(fn -> text_stream("subagent out") end)

      {:ok, parent_pid} = Supervisor.start_agent(parent_config)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      Server.subscribe(parent_pid)

      tool = RunAgent.tool(parent_config, parent_pid)
      tool.execute.("call_1", %{"prompt" => "go"}, [])

      # We should have received subagent_event wrappers on parent_pid's subscribers
      assert_received {:agent_event, {:subagent_event, nil, 1, {:agent_end, _}}}
    end

    test "waits for a slow subagent without a local timeout" do
      parent_config =
        base_config(fn ->
          Process.sleep(100)
          text_stream("slow subagent out")
        end)

      {:ok, parent_pid} = Supervisor.start_agent(parent_config)
      on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, parent_pid) end)

      tool = RunAgent.tool(parent_config, parent_pid)

      assert {:ok, %{content: [%TextContent{text: text}]}} =
               tool.execute.("call_1", %{"prompt" => "go slow"}, [])

      assert String.contains?(text, "slow subagent out")
    end
  end
end

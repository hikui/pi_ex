defmodule PiEx.Agent.ServerTest do
  # async: false — tests interact with GenServer processes and shared supervisors
  use ExUnit.Case, async: false

  alias PiEx.Agent.{Config, Server, Supervisor}
  alias PiEx.AI.Model
  alias PiEx.AI.Message
  alias PiEx.AI.Message.{AssistantMessage, Usage}
  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.ProviderParams

  # ---------------------------------------------------------------------------
  # Fake stream helpers
  # ---------------------------------------------------------------------------

  defp text_stream(text) do
    partial_empty = %AssistantMessage{
      content: [],
      model: "test",
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: 0
    }

    partial_done = %AssistantMessage{
      content: [%TextContent{text: text}],
      model: "test",
      usage: %Usage{input_tokens: 5, output_tokens: 2},
      stop_reason: :stop,
      timestamp: 0
    }

    [
      {:start, partial_empty},
      {:text_start, 0, partial_empty},
      {:text_delta, 0, text, partial_done},
      {:text_end, 0, text, partial_done},
      {:done, :stop, partial_done}
    ]
  end

  defp tool_call_stream(call_id, tool_name, args) do
    tc = %ToolCall{id: call_id, name: tool_name, arguments: args}

    partial_empty = %AssistantMessage{
      content: [],
      model: "test",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 0
    }

    partial_done = %AssistantMessage{
      content: [tc],
      model: "test",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 0
    }

    [
      {:start, partial_empty},
      {:toolcall_start, 0, partial_empty},
      {:toolcall_end, 0, tc, partial_done},
      {:done, :tool_use, partial_done}
    ]
  end

  defp error_stream(reason, message) do
    error_message = %AssistantMessage{
      content: [],
      model: "test",
      usage: %Usage{},
      stop_reason: :error,
      timestamp: 0,
      error_message: message
    }

    [
      {:start, error_message},
      {:error, reason, error_message}
    ]
  end

  defp base_config(stream_fn) do
    %Config{
      model: Model.new("test-model", "openai"),
      stream_fn: fn _model, _ctx, _opts -> stream_fn.() end
    }
  end

  defp start_agent!(config) do
    {:ok, pid} = Supervisor.start_agent(config)
    on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, pid) end)
    pid
  end

  # Helper kept for future use if synchronous waiting is needed
  # defp wait_for_idle(server, timeout \ 3000) do ...

  # ---------------------------------------------------------------------------
  # Lifecycle
  # ---------------------------------------------------------------------------

  describe "start_link/1 and status/1" do
    test "starts in :idle status" do
      pid = start_agent!(base_config(fn -> text_stream("hi") end))
      assert Server.status(pid) == :idle
    end
  end

  describe "subscribe/2" do
    test "subscribes the calling process to events" do
      pid = start_agent!(base_config(fn -> text_stream("hi") end))
      assert :ok = Server.subscribe(pid)
    end
  end

  # ---------------------------------------------------------------------------
  # prompt/2
  # ---------------------------------------------------------------------------

  describe "prompt/2" do
    test "returns :ok and transitions to :running" do
      pid = start_agent!(base_config(fn -> text_stream("hi") end))
      Server.subscribe(pid)
      assert :ok = Server.prompt(pid, "Hello")
    end

    test "runs to completion and becomes :idle" do
      pid = start_agent!(base_config(fn -> text_stream("result") end))
      Server.subscribe(pid)
      Server.prompt(pid, "test")
      assert_receive {:agent_event, {:agent_end, _}}, 3000
      assert Server.status(pid) == :idle
    end

    test "broadcasts agent_start and agent_end events to subscribers" do
      pid = start_agent!(base_config(fn -> text_stream("done") end))
      Server.subscribe(pid)
      Server.prompt(pid, "hello")

      assert_receive {:agent_event, :agent_start}, 3000
      assert_receive {:agent_event, {:agent_end, _}}, 3000
    end

    test "stores messages in transcript after run" do
      pid = start_agent!(base_config(fn -> text_stream("assistant response") end))
      Server.subscribe(pid)
      Server.prompt(pid, "user prompt")
      assert_receive {:agent_event, {:agent_end, _}}, 3000

      messages = Server.get_messages(pid)
      assert length(messages) >= 2

      user_msg = hd(messages)
      assert %Message.UserMessage{content: "user prompt"} = user_msg
    end

    test "broadcasts agent_error when the provider stream fails" do
      pid = start_agent!(base_config(fn -> error_stream(:error, "HTTP 400: bad request") end))
      Server.subscribe(pid)
      Server.prompt(pid, "broken")

      assert_receive {:agent_event, {:agent_error, {:error, "HTTP 400: bad request"}}}, 3000
      assert_receive {:agent_event, {:agent_end, messages}}, 3000

      assert %AssistantMessage{error_message: "HTTP 400: bad request"} = List.last(messages)
    end

    test "passes stream opts derived from model provider params" do
      test_pid = self()

      model =
        Model.new("gpt-5.4", "openai_responses",
          provider_params: %ProviderParams.OpenAIResponses{
            api_key: "sk-openai",
            temperature: 0.3,
            max_tokens: 77,
            http_receive_timeout: 12_345,
            reasoning_effort: "low",
            reasoning_summary: "auto"
          }
        )

      pid =
        start_agent!(%Config{
          model: model,
          stream_fn: fn _model, _ctx, opts ->
            send(test_pid, {:stream_opts, opts})
            text_stream("ok")
          end
        })

      Server.subscribe(pid)
      Server.prompt(pid, "hello")

      assert_receive {:stream_opts, opts}, 3000
      assert opts[:api_key] == "sk-openai"
      assert opts[:temperature] == 0.3
      assert opts[:max_tokens] == 77
      assert opts[:http_receive_timeout] == 12_345
      assert opts[:reasoning_effort] == "low"
      assert opts[:reasoning_summary] == "auto"
      assert_receive {:agent_event, {:agent_end, _}}, 3000
    end

    test "returns :error when already running" do
      # Use a stream that blocks until signalled
      test_pid = self()

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          stream_fn: fn _m, _c, _o ->
            # Signal ready then block
            send(test_pid, :stream_started)
            receive do: (:continue -> [])
          end
        })

      Server.subscribe(pid)
      Server.prompt(pid, "first")
      assert_receive :stream_started, 1000

      assert {:error, :already_running} = Server.prompt(pid, "second")

      # Unblock and let it finish
      # Find the task pid and send :continue — just let it timeout naturally
      # or terminate agent
      DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, pid)
    end
  end

  # ---------------------------------------------------------------------------
  # steer/2
  # ---------------------------------------------------------------------------

  describe "steer/2" do
    test "queued steering messages are included in subsequent run turn" do
      received_messages = :ets.new(:steering_msgs, [:set, :public])
      test_pid = self()
      count = :counters.new(1, [])

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          stream_fn: fn _m, ctx, _o ->
            :counters.add(count, 1, 1)
            :ets.insert(received_messages, {:messages, ctx.messages})
            send(test_pid, {:turn, :counters.get(count, 1)})
            text_stream("ok")
          end
        })

      Server.subscribe(pid)
      Server.steer(pid, Message.user("steered"))
      Server.prompt(pid, "initial")

      assert_receive {:agent_event, {:agent_end, _}}, 3000
      [{:messages, msgs}] = :ets.lookup(received_messages, :messages)
      contents = Enum.map(msgs, fn m -> m.content end)
      assert "steered" in contents
    end
  end

  # ---------------------------------------------------------------------------
  # abort/1
  # ---------------------------------------------------------------------------

  describe "abort/1" do
    test "abort on an idle agent is a no-op" do
      pid = start_agent!(base_config(fn -> text_stream("hi") end))
      assert :ok = Server.abort(pid)
      assert Server.status(pid) == :idle
    end

    test "abort stops a running agent" do
      test_pid = self()

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          stream_fn: fn _m, _c, _o ->
            send(test_pid, :loop_started)
            receive do: (:never -> [])
          end
        })

      Server.subscribe(pid)
      Server.prompt(pid, "go")
      assert_receive :loop_started, 1000

      Server.abort(pid)
      Process.sleep(100)
      assert Server.status(pid) == :idle
    end
  end

  # ---------------------------------------------------------------------------
  # Tool execution via loop
  # ---------------------------------------------------------------------------

  describe "tool execution" do
    test "tool is called and result is added to messages" do
      executed = :ets.new(:executed, [:set, :public])
      call_count = :counters.new(1, [])

      echo_tool = %PiEx.Agent.Tool{
        name: "echo",
        description: "echoes input",
        parameters: %{},
        label: "Echo",
        execute: fn call_id, params, _opts ->
          :ets.insert(executed, {:call, call_id, params})
          {:ok, %{content: [%TextContent{text: "echoed"}], details: nil}}
        end
      }

      # First call returns a tool_use, second call (after tool result) returns text
      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          tools: [echo_tool],
          stream_fn: fn _m, _ctx, _o ->
            :counters.add(call_count, 1, 1)
            turn = :counters.get(call_count, 1)

            if turn == 1 do
              tool_call_stream("call_1", "echo", %{"msg" => "hello"})
            else
              text_stream("done")
            end
          end
        })

      Server.subscribe(pid)
      Server.prompt(pid, "use echo tool")
      assert_receive {:agent_event, {:agent_end, _}}, 5000

      assert :ets.member(executed, :call)
    end

    test "tool_execution_start and tool_execution_end events are broadcast" do
      echo_tool = %PiEx.Agent.Tool{
        name: "echo",
        description: "echo",
        parameters: %{},
        label: "Echo",
        execute: fn _id, _params, _opts ->
          {:ok, %{content: [%TextContent{text: "ok"}], details: nil}}
        end
      }

      call_count = :counters.new(1, [])

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          tools: [echo_tool],
          stream_fn: fn _m, _ctx, _o ->
            :counters.add(call_count, 1, 1)

            if :counters.get(call_count, 1) == 1 do
              tool_call_stream("call_1", "echo", %{})
            else
              text_stream("done")
            end
          end
        })

      Server.subscribe(pid)
      Server.prompt(pid, "go")
      assert_receive {:agent_event, {:agent_end, _}}, 5000

      assert_received {:agent_event, {:tool_execution_start, "call_1", "echo", _}}
      assert_received {:agent_event, {:tool_execution_end, "call_1", "echo", _, false}}
    end

    test "waits for a slow tool result without agent-level timeout config" do
      slow_tool = %PiEx.Agent.Tool{
        name: "slow_echo",
        description: "sleeps before replying",
        parameters: %{},
        label: "Slow Echo",
        execute: fn _id, _params, _opts ->
          Process.sleep(100)
          {:ok, %{content: [%TextContent{text: "slow ok"}], details: nil}}
        end
      }

      call_count = :counters.new(1, [])

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          tools: [slow_tool],
          stream_fn: fn _m, _ctx, _o ->
            :counters.add(call_count, 1, 1)

            case :counters.get(call_count, 1) do
              1 -> tool_call_stream("call_1", "slow_echo", %{})
              _ -> text_stream("done")
            end
          end
        })

      Server.subscribe(pid)
      Server.prompt(pid, "go")

      assert_receive {:agent_event, {:agent_end, messages}}, 5_000
      assert Enum.any?(messages, &match?(%Message.ToolResultMessage{}, &1))
    end
  end

  # ---------------------------------------------------------------------------
  # get_messages/1
  # ---------------------------------------------------------------------------

  describe "get_messages/1" do
    test "returns empty list before any prompts" do
      pid = start_agent!(base_config(fn -> text_stream("hi") end))
      assert Server.get_messages(pid) == []
    end

    test "returns full transcript including user and assistant messages" do
      pid = start_agent!(base_config(fn -> text_stream("pong") end))
      Server.subscribe(pid)
      Server.prompt(pid, "ping")
      assert_receive {:agent_event, {:agent_end, _}}, 3000

      messages = Server.get_messages(pid)
      roles = Enum.map(messages, fn m -> m.__struct__ end)
      assert Message.UserMessage in roles
      assert AssistantMessage in roles
    end
  end

  # ---------------------------------------------------------------------------
  # Compaction
  # ---------------------------------------------------------------------------

  describe "compaction" do
    defp compaction_config(stream_fn, compact_fn) do
      alias PiEx.Agent.Compaction.Settings

      %PiEx.Agent.Config{
        model: %PiEx.AI.Model{id: "test-model", provider: "openai", context_window: 100},
        stream_fn: fn _model, _ctx, _opts -> stream_fn.() end,
        compaction: %Settings{enabled: true, reserve_tokens: 50, keep_recent_tokens: 10},
        compact_fn: compact_fn
      }
    end

    defp high_usage_stream(text) do
      # Return an AssistantMessage with high token usage to trigger compaction
      partial_done = %AssistantMessage{
        content: [%TextContent{text: text}],
        model: "test",
        usage: %Usage{input_tokens: 80, output_tokens: 10},
        stop_reason: :stop,
        timestamp: 0
      }

      [
        {:start, partial_done},
        {:text_start, 0, partial_done},
        {:text_delta, 0, text, partial_done},
        {:text_end, 0, text, partial_done},
        {:done, :stop, partial_done}
      ]
    end

    test "broadcasts compaction_start and compaction_end after agent_end" do
      alias PiEx.AI.Message.CompactionSummaryMessage
      test_pid = self()

      summary_msg = %CompactionSummaryMessage{
        summary: "previous work summary",
        tokens_before: 90,
        timestamp: 0
      }

      compact_fn = fn _messages, _model, _settings, _api_key ->
        send(test_pid, :compact_fn_called)
        {:ok, [summary_msg]}
      end

      pid = start_agent!(compaction_config(fn -> high_usage_stream("result") end, compact_fn))
      Server.subscribe(pid)
      Server.prompt(pid, "go")

      assert_receive {:agent_event, {:agent_end, _}}, 3000
      assert_receive :compact_fn_called, 3000
      assert_receive {:agent_event, :compaction_start}, 3000
      assert_receive {:agent_event, {:compaction_end, %CompactionSummaryMessage{}}}, 3000
    end

    test "get_messages returns compacted list after compaction_end" do
      alias PiEx.AI.Message.CompactionSummaryMessage

      summary_msg = %CompactionSummaryMessage{
        summary: "compacted history",
        tokens_before: 90,
        timestamp: 0
      }

      compact_fn = fn _messages, _model, _settings, _api_key ->
        {:ok, [summary_msg]}
      end

      pid = start_agent!(compaction_config(fn -> high_usage_stream("done") end, compact_fn))
      Server.subscribe(pid)
      Server.prompt(pid, "hello")

      assert_receive {:agent_event, {:agent_end, _}}, 3000
      assert_receive {:agent_event, {:compaction_end, _}}, 3000

      messages = Server.get_messages(pid)
      assert [%CompactionSummaryMessage{summary: "compacted history"} | _] = messages
    end

    test "prompt returns :error when compaction is in progress" do
      alias PiEx.AI.Message.CompactionSummaryMessage
      test_pid = self()

      compact_fn = fn _messages, _model, _settings, _api_key ->
        # Signal the test we're inside compaction, then block briefly
        send(test_pid, :compacting)
        Process.sleep(200)
        {:ok, [%CompactionSummaryMessage{summary: "done", tokens_before: 90, timestamp: 0}]}
      end

      pid = start_agent!(compaction_config(fn -> high_usage_stream("hi") end, compact_fn))
      Server.subscribe(pid)
      Server.prompt(pid, "first")

      assert_receive {:agent_event, {:agent_end, _}}, 3000
      assert_receive :compacting, 3000

      assert {:error, :already_running} = Server.prompt(pid, "second")

      # Let compaction finish
      assert_receive {:agent_event, {:compaction_end, _}}, 3000
    end

    test "compaction_error is broadcast when compact_fn returns error" do
      compact_fn = fn _messages, _model, _settings, _api_key ->
        {:error, :summarization_failed}
      end

      pid = start_agent!(compaction_config(fn -> high_usage_stream("hi") end, compact_fn))
      Server.subscribe(pid)
      Server.prompt(pid, "go")

      assert_receive {:agent_event, {:agent_end, _}}, 3000
      assert_receive {:agent_event, {:compaction_error, :summarization_failed}}, 3000
    end

    test "no compaction when tokens are below threshold" do
      # Use low-usage stream so tokens don't exceed context_window - reserve
      pid =
        start_agent!(
          compaction_config(
            fn -> text_stream("small reply") end,
            fn _msgs, _m, _s, _k -> flunk("compact_fn should not be called") end
          )
        )

      Server.subscribe(pid)
      Server.prompt(pid, "hi")
      assert_receive {:agent_event, {:agent_end, _}}, 3000

      # Give a moment to confirm no compaction fires
      refute_receive {:agent_event, :compaction_start}, 200
    end

    test "manual compact/1 triggers compaction regardless of token count" do
      alias PiEx.AI.Message.CompactionSummaryMessage
      test_pid = self()

      compact_fn = fn _messages, _model, _settings, _api_key ->
        send(test_pid, :compact_fn_called)
        {:ok, [%CompactionSummaryMessage{summary: "manual", tokens_before: 0, timestamp: 0}]}
      end

      pid =
        start_agent!(
          compaction_config(
            fn -> text_stream("reply") end,
            compact_fn
          )
        )

      Server.subscribe(pid)
      Server.prompt(pid, "hi")
      assert_receive {:agent_event, {:agent_end, _}}, 3000

      # First compaction from high_usage_stream won't trigger (text_stream has low usage)
      refute_receive {:agent_event, :compaction_start}, 200

      # Manual trigger
      :ok = Server.compact(pid)
      assert_receive :compact_fn_called, 3000
      assert_receive {:agent_event, :compaction_start}, 3000
      assert_receive {:agent_event, {:compaction_end, _}}, 3000
    end

    test "passes the model api key into compact_fn" do
      alias PiEx.AI.Message.CompactionSummaryMessage
      test_pid = self()

      compact_fn = fn _messages, _model, _settings, api_key ->
        send(test_pid, {:compact_api_key, api_key})
        {:ok, [%CompactionSummaryMessage{summary: "done", tokens_before: 90, timestamp: 0}]}
      end

      pid =
        start_agent!(%PiEx.Agent.Config{
          model:
            Model.new("test-model", "openai",
              context_window: 100,
              provider_params: %ProviderParams.OpenAI{api_key: "sk-openai"}
            ),
          stream_fn: fn _m, _c, _o -> high_usage_stream("hi") end,
          compaction: %PiEx.Agent.Compaction.Settings{
            enabled: true,
            reserve_tokens: 50,
            keep_recent_tokens: 10
          },
          compact_fn: compact_fn
        })

      Server.subscribe(pid)
      Server.prompt(pid, "go")

      assert_receive {:agent_event, {:agent_end, _}}, 3000
      assert_receive {:compact_api_key, "sk-openai"}, 3000
      assert_receive {:agent_event, {:compaction_end, _}}, 3000
    end

    test "no compaction when compaction config is nil" do
      pid =
        start_agent!(%PiEx.Agent.Config{
          model: %PiEx.AI.Model{id: "test", provider: "openai", context_window: 100},
          stream_fn: fn _m, _c, _o -> high_usage_stream("hi") end,
          compaction: nil
        })

      Server.subscribe(pid)
      Server.prompt(pid, "hello")
      assert_receive {:agent_event, {:agent_end, _}}, 3000
      refute_receive {:agent_event, :compaction_start}, 200
    end

    test "no compaction when model has no context_window" do
      alias PiEx.Agent.Compaction.Settings

      pid =
        start_agent!(%PiEx.Agent.Config{
          model: %PiEx.AI.Model{id: "test", provider: "openai", context_window: nil},
          stream_fn: fn _m, _c, _o -> high_usage_stream("hi") end,
          compaction: %Settings{enabled: true, reserve_tokens: 50, keep_recent_tokens: 10}
        })

      Server.subscribe(pid)
      Server.prompt(pid, "hello")
      assert_receive {:agent_event, {:agent_end, _}}, 3000
      refute_receive {:agent_event, :compaction_start}, 200
    end
  end
end

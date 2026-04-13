defmodule PiEx.Agent.TracingTest do
  # async: false — these tests mutate app env and use the shared supervisor tree
  use ExUnit.Case, async: false

  alias PiEx.Agent.{Config, Server, Supervisor}
  alias PiEx.AI.Model
  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.Message.AssistantMessage
  alias PiEx.AI.Message.Usage

  defmodule FakeAdapter do
    @behaviour PiEx.Tracing.Adapter

    @impl true
    def start_span(parent_handle, attrs) do
      handle = %{id: System.unique_integer([:positive]), parent: parent_handle}
      send(test_pid(), {:trace_start, handle, parent_handle, attrs})
      {:ok, handle}
    end

    @impl true
    def finish_span(handle, outputs, _opts) do
      send(test_pid(), {:trace_finish, handle, outputs})
      :ok
    end

    @impl true
    def fail_span(handle, error, outputs, _opts) do
      send(test_pid(), {:trace_fail, handle, error, outputs})
      :ok
    end

    defp test_pid do
      Application.fetch_env!(:pi_ex, :tracing_test_pid)
    end
  end

  setup do
    Application.put_env(:pi_ex, :tracing_adapter, FakeAdapter)
    Application.put_env(:pi_ex, :tracing_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:pi_ex, :tracing_adapter)
      Application.delete_env(:pi_ex, :tracing_test_pid)
    end)

    :ok
  end

  defp text_stream(text) do
    partial = %AssistantMessage{
      content: [%TextContent{text: text}],
      model: "test",
      usage: %Usage{input_tokens: 5, output_tokens: 2},
      stop_reason: :stop,
      timestamp: 0
    }

    [
      {:start, %{partial | content: []}},
      {:text_start, 0, %{partial | content: []}},
      {:text_delta, 0, text, partial},
      {:text_end, 0, text, partial},
      {:done, :stop, partial}
    ]
  end

  defp tool_call_stream(call_id, tool_name, args) do
    tool_call = %ToolCall{id: call_id, name: tool_name, arguments: args}

    partial = %AssistantMessage{
      content: [tool_call],
      model: "test",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 0
    }

    [
      {:start, %{partial | content: []}},
      {:toolcall_start, 0, %{partial | content: []}},
      {:toolcall_end, 0, tool_call, partial},
      {:done, :tool_use, partial}
    ]
  end

  defp start_agent!(config) do
    {:ok, pid} = Supervisor.start_agent(config)
    on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, pid) end)
    pid
  end

  defp flush_traces(acc \\ []) do
    receive do
      event when elem(event, 0) in [:trace_start, :trace_finish, :trace_fail] ->
        flush_traces([event | acc])
    after
      50 -> Enum.reverse(acc)
    end
  end

  describe "generic tracing facade integration" do
    test "traces root, llm, and tool spans through the configured adapter" do
      echo_tool = %PiEx.Agent.Tool{
        name: "echo",
        description: "echo",
        parameters: %{},
        label: "Echo",
        execute: fn _id, _params, _opts ->
          {:ok, %{content: [%TextContent{text: "ok"}], details: nil}}
        end
      }

      counter = :counters.new(1, [])

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          tools: [echo_tool],
          stream_fn: fn _m, _ctx, _opts ->
            :counters.add(counter, 1, 1)

            case :counters.get(counter, 1) do
              1 -> tool_call_stream("call_1", "echo", %{"msg" => "hi"})
              _ -> text_stream("done")
            end
          end
        })

      Server.subscribe(pid)
      assert :ok = Server.prompt(pid, "go")
      assert_receive {:agent_event, {:agent_end, _}}, 5_000

      events = flush_traces()

      assert Enum.any?(events, fn
               {:trace_start, _handle, nil, %{name: "pi_ex.agent", type: :chain}} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:trace_start, _handle, %{id: _}, %{name: "pi_ex.llm", type: :llm}} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:trace_start, _handle, %{id: _}, %{name: "echo", type: :tool}} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               {:trace_finish, _handle, %{messages: _messages}} -> true
               _ -> false
             end)
    end

    test "nests subagent root spans under the run_agent tool span" do
      counter = :counters.new(1, [])

      stream_fn = fn _model, ctx, _opts ->
        last_user_text =
          ctx.messages
          |> Enum.reverse()
          |> Enum.find_value(fn
            %{content: content} when is_binary(content) -> content
            _ -> nil
          end)

        cond do
          last_user_text == "sub task" ->
            text_stream("subagent done")

          Enum.any?(ctx.messages, &match?(%PiEx.AI.Message.ToolResultMessage{}, &1)) ->
            text_stream("parent done")

          true ->
            :counters.add(counter, 1, 1)
            tool_call_stream("call_1", "run_agent", %{"prompt" => "sub task"})
        end
      end

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai"),
          stream_fn: stream_fn
        })

      Server.subscribe(pid)
      assert :ok = Server.prompt(pid, "delegate")
      assert_receive {:agent_event, {:agent_end, _}}, 5_000

      events = flush_traces()

      {:trace_start, run_agent_handle, _parent, %{name: "run_agent"}} =
        Enum.find(events, fn
          {:trace_start, _handle, _parent, %{name: "run_agent"}} -> true
          _ -> false
        end)

      assert Enum.any?(events, fn
               {:trace_start, _handle, %{id: parent_id}, %{name: "pi_ex.subagent", type: :chain}} ->
                 parent_id == run_agent_handle.id

               _ ->
                 false
             end)
    end

    test "traces compaction as a child span" do
      summary = %PiEx.AI.Message.CompactionSummaryMessage{
        summary: "compacted",
        tokens_before: 90,
        timestamp: 0
      }

      compact_fn = fn _messages, _model, _settings, _api_key ->
        {:ok, [summary]}
      end

      high_usage_stream = fn ->
        partial = %AssistantMessage{
          content: [%TextContent{text: "result"}],
          model: "test",
          usage: %Usage{input_tokens: 80, output_tokens: 10},
          stop_reason: :stop,
          timestamp: 0
        }

        [
          {:start, partial},
          {:text_start, 0, partial},
          {:text_delta, 0, "result", partial},
          {:text_end, 0, "result", partial},
          {:done, :stop, partial}
        ]
      end

      pid =
        start_agent!(%Config{
          model: Model.new("test-model", "openai", context_window: 100),
          stream_fn: fn _m, _ctx, _opts -> high_usage_stream.() end,
          compaction: %PiEx.Agent.Compaction.Settings{
            enabled: true,
            reserve_tokens: 50,
            keep_recent_tokens: 10
          },
          compact_fn: compact_fn
        })

      Server.subscribe(pid)
      assert :ok = Server.prompt(pid, "compact")
      assert_receive {:agent_event, {:compaction_end, _}}, 5_000

      events = flush_traces()

      assert Enum.any?(events, fn
               {:trace_start, _handle, %{id: _}, %{name: "pi_ex.compaction", type: :llm}} -> true
               _ -> false
             end)
    end
  end
end

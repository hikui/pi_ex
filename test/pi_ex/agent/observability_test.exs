defmodule PiEx.Agent.ObservabilityTest do
  use ExUnit.Case, async: false

  alias PiEx.Agent.{Config, Server, Supervisor}
  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.Message.{AssistantMessage, Usage}
  alias PiEx.AI.Model
  alias PiEx.Observability
  alias PiEx.Observability.Settings
  alias PiEx.OtelTestHelpers
  alias PiEx.TestSpanExporter

  defp text_stream(text) do
    partial_empty = %AssistantMessage{
      content: [],
      model: "gpt-5.4",
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: 0
    }

    partial_done = %AssistantMessage{
      content: [%TextContent{text: text}],
      model: "gpt-5.4",
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
      model: "gpt-5.4",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 0
    }

    partial_done = %AssistantMessage{
      content: [tc],
      model: "gpt-5.4",
      usage: %Usage{input_tokens: 6, output_tokens: 1},
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

  defp start_agent!(config) do
    {:ok, pid} = Supervisor.start_agent(config)
    on_exit(fn -> DynamicSupervisor.terminate_child(PiEx.Agent.Supervisor, pid) end)
    pid
  end

  defp wait_for_spans(expected_count) do
    Enum.reduce_while(1..50, nil, fn _, _acc ->
      spans = TestSpanExporter.spans()

      if length(spans) >= expected_count do
        {:halt, spans}
      else
        Process.sleep(20)
        {:cont, nil}
      end
    end) || TestSpanExporter.spans()
  end

  setup do
    TestSpanExporter.clear()

    Application.put_env(:pi_ex, :observability, enabled: false)

    on_exit(fn ->
      TestSpanExporter.clear()
      Application.delete_env(:pi_ex, :observability)
    end)

    :ok
  end

  describe "agent spans" do
    test "emits invoke_agent and chat spans for a prompt" do
      pid =
        start_agent!(%Config{
          model: Model.new("gpt-5.4", "openai"),
          observability: %Settings{
            enabled: true,
            agent_name: "demo-agent",
            conversation_id: "conv-1"
          },
          stream_fn: fn _model, _context, _opts ->
            settings = Observability.resolve_settings(enabled: true)

            Observability.with_span(
              "chat gpt-5.4",
              [
                kind: :client,
                attributes: %{
                  "gen_ai.operation.name" => "chat",
                  "gen_ai.request.model" => "gpt-5.4",
                  "gen_ai.provider.name" => "openai"
                }
              ],
              settings,
              fn span_ctx ->
                stream = text_stream("hello")
                {:done, :stop, final_message} = List.last(stream)
                Observability.finish_model_span(span_ctx, final_message, settings)
                stream
              end
            )
          end
        })

      Server.subscribe(pid)
      assert :ok = Server.prompt(pid, "hi")
      assert_receive {:agent_event, {:agent_end, _messages}}, 3_000

      spans = wait_for_spans(2)
      names = Enum.map(spans, &to_string(OtelTestHelpers.span_name(&1)))

      assert "invoke_agent demo-agent" in names
      assert "chat gpt-5.4" in names

      agent_span =
        Enum.find(spans, &(to_string(OtelTestHelpers.span_name(&1)) == "invoke_agent demo-agent"))

      chat_span = Enum.find(spans, &(to_string(OtelTestHelpers.span_name(&1)) == "chat gpt-5.4"))

      assert OtelTestHelpers.instrumentation_scope_name(agent_span) == "pi_ex"
      assert OtelTestHelpers.span_kind(agent_span) == :client
      assert OtelTestHelpers.span_kind(chat_span) == :client

      agent_attrs = OtelTestHelpers.span_attributes(agent_span)
      chat_attrs = OtelTestHelpers.span_attributes(chat_span)

      assert agent_attrs["gen_ai.operation.name"] == "invoke_agent"
      assert agent_attrs["gen_ai.agent.name"] == "demo-agent"
      assert agent_attrs["gen_ai.conversation.id"] == "conv-1"
      assert agent_attrs["gen_ai.usage.input_tokens"] == 5
      assert agent_attrs["gen_ai.usage.output_tokens"] == 2
      assert chat_attrs["gen_ai.operation.name"] == "chat"
      assert chat_attrs["gen_ai.request.model"] == "gpt-5.4"
    end

    test "emits a tool span and preserves parent-child relationships" do
      echo_tool = %PiEx.Agent.Tool{
        name: "echo",
        description: "echoes text",
        parameters: %{},
        label: "Echo",
        execute: fn _id, _params, _opts ->
          {:ok, %{content: [%TextContent{text: "ok"}], details: nil}}
        end
      }

      call_count = :counters.new(1, [])

      pid =
        start_agent!(%Config{
          model: Model.new("gpt-5.4", "openai"),
          tools: [echo_tool],
          observability: %Settings{enabled: true, capture_sensitive_data: true},
          stream_fn: fn _model, _context, _opts ->
            :counters.add(call_count, 1, 1)

            case :counters.get(call_count, 1) do
              1 -> tool_call_stream("call_1", "echo", %{"msg" => "hello"})
              _turn -> text_stream("done")
            end
          end
        })

      Server.subscribe(pid)
      assert :ok = Server.prompt(pid, "use tool")
      assert_receive {:agent_event, {:agent_end, _messages}}, 3_000

      spans = wait_for_spans(4)

      agent_span = Enum.find(spans, &(to_string(OtelTestHelpers.span_name(&1)) == "invoke_agent"))

      tool_span =
        Enum.find(spans, &(to_string(OtelTestHelpers.span_name(&1)) == "execute_tool echo"))

      assert tool_span
      assert OtelTestHelpers.parent_span_id(tool_span) == OtelTestHelpers.span_id(agent_span)

      tool_attrs = OtelTestHelpers.span_attributes(tool_span)
      assert tool_attrs["gen_ai.tool.name"] == "echo"
      assert tool_attrs["gen_ai.tool.call.arguments"] =~ "hello"
      assert tool_attrs["gen_ai.tool.call.result"] =~ "ok"
    end
  end
end

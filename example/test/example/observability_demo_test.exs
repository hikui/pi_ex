defmodule Example.ObservabilityDemoTest do
  use ExUnit.Case, async: false

  alias PiEx.AI.Content.TextContent
  alias PiEx.AI.Message.{AssistantMessage, Usage}

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
      usage: %Usage{input_tokens: 3, output_tokens: 2},
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

  describe "run/1" do
    test "returns the conversation transcript" do
      config = %PiEx.Agent.Config{
        model: PiEx.AI.Model.new("test-model", "openai"),
        observability: [enabled: true],
        stream_fn: fn _model, _context, _opts ->
          text_stream("Melbourne has the world's largest tram network.")
        end
      }

      messages = Example.ObservabilityDemo.run(config: config, timeout: 1_000)

      assert Enum.any?(messages, &match?(%PiEx.AI.Message.UserMessage{}, &1))
      assert Enum.any?(messages, &match?(%AssistantMessage{}, &1))
    end
  end
end

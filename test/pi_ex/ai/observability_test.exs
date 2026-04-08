defmodule PiEx.AI.ObservabilityTest do
  use ExUnit.Case, async: false

  alias PiEx.AI.{Context, Message, Model}
  alias PiEx.AI.Providers.{OpenAI, OpenAIResponses}
  alias PiEx.OtelTestHelpers
  alias PiEx.TestSpanExporter

  defp context(text \\ "Hello!") do
    %Context{messages: [Message.user(text)]}
  end

  defp sse_body(chunks) do
    lines =
      Enum.map(chunks, fn chunk ->
        "data: #{Jason.encode!(chunk)}"
      end)

    (lines ++ ["data: [DONE]", ""]) |> Enum.join("\n\n")
  end

  defp stub_openai(stub_name, body) do
    Req.Test.stub(stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp wait_for_span(name) do
    Enum.reduce_while(1..50, nil, fn _, _acc ->
      span =
        TestSpanExporter.spans()
        |> Enum.find(&(to_string(OtelTestHelpers.span_name(&1)) == name))

      if span do
        {:halt, span}
      else
        Process.sleep(20)
        {:cont, nil}
      end
    end)
  end

  setup do
    TestSpanExporter.clear()

    on_exit(fn ->
      TestSpanExporter.clear()
    end)

    :ok
  end

  describe "direct AI spans" do
    test "emits a chat span for OpenAI" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Hi"}, finish_reason: nil}]},
          %{
            choices: [%{delta: %{}, finish_reason: "stop"}],
            usage: %{prompt_tokens: 3, completion_tokens: 1}
          }
        ])

      stub_openai(OpenAIObservability, body)

      OpenAI.stream(
        Model.new("gpt-4o", "openai"),
        context(),
        plug: {Req.Test, OpenAIObservability},
        observability: [enabled: true]
      )
      |> Enum.to_list()

      span = wait_for_span("chat gpt-4o")
      assert span
      assert OtelTestHelpers.span_attributes(span)["gen_ai.operation.name"] == "chat"
      assert OtelTestHelpers.span_attributes(span)["gen_ai.usage.input_tokens"] == 3
      assert OtelTestHelpers.span_attributes(span)["gen_ai.usage.output_tokens"] == 1
    end

    test "emits a chat span for OpenAI Responses" do
      body =
        sse_body([
          %{"type" => "response.output_text.delta", "delta" => "Hello"},
          %{
            "type" => "response.completed",
            "response" => %{"usage" => %{"input_tokens" => 4, "output_tokens" => 2}}
          }
        ])

      stub_openai(OpenAIResponsesObservability, body)

      OpenAIResponses.stream(
        Model.new("gpt-5.4", "openai_responses"),
        context(),
        plug: {Req.Test, OpenAIResponsesObservability},
        observability: [enabled: true]
      )
      |> Enum.to_list()

      span = wait_for_span("chat gpt-5.4")
      assert span
      assert OtelTestHelpers.span_attributes(span)["gen_ai.provider.name"] == "openai"
      assert OtelTestHelpers.span_attributes(span)["gen_ai.response.finish_reasons"] == ["stop"]
    end
  end
end

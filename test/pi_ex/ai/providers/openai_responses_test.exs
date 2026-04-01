defmodule PiEx.AI.Providers.OpenAIResponsesTest do
  use ExUnit.Case, async: false

  alias PiEx.AI.{Context, Message, Model}
  alias PiEx.AI.Content.{TextContent, ThinkingContent, ToolCall}
  alias PiEx.AI.Message.AssistantMessage
  alias PiEx.AI.Providers.OpenAIResponses
  alias PiEx.AI.ProviderParams

  defp model, do: Model.new("gpt-5.4", "openai_responses")
  defp context(text \\ "Hello!"), do: %Context{messages: [Message.user(text)]}

  defp sse_body(chunks) do
    lines =
      Enum.map(chunks, fn chunk ->
        "data: #{Jason.encode!(chunk)}"
      end)

    (lines ++ ["data: [DONE]", ""]) |> Enum.join("\n\n")
  end

  defp stub_openai(stub_name, body, status \\ 200) do
    Req.Test.stub(stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  describe "stream/3" do
    test "emits thinking events from reasoning summary deltas" do
      body =
        sse_body([
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "First"},
          %{"type" => "response.reasoning_summary_text.delta", "delta" => " pass"},
          %{
            "type" => "response.completed",
            "response" => %{"usage" => %{"input_tokens" => 10, "output_tokens" => 4}}
          }
        ])

      stub_openai(OpenAIResponsesThinking, body)

      events =
        OpenAIResponses.stream(model(), context(), plug: {Req.Test, OpenAIResponsesThinking})
        |> Enum.to_list()

      types = Enum.map(events, &elem(&1, 0))

      assert :thinking_start in types
      assert :thinking_delta in types
      assert :thinking_end in types
      assert {:done, :stop, %AssistantMessage{} = final} = List.last(events)
      assert [%ThinkingContent{thinking: "First pass"}] = final.content
      assert final.usage.input_tokens == 10
      assert final.usage.output_tokens == 4
    end

    test "emits thinking when reasoning arrives as a done event without deltas" do
      body =
        sse_body([
          %{"type" => "response.reasoning_summary_text.done", "text" => "Summarized reasoning"},
          %{"type" => "response.completed", "response" => %{}}
        ])

      stub_openai(OpenAIResponsesThinkingDone, body)

      events =
        OpenAIResponses.stream(model(), context(), plug: {Req.Test, OpenAIResponsesThinkingDone})
        |> Enum.to_list()

      types = Enum.map(events, &elem(&1, 0))

      assert :thinking_start in types
      assert :thinking_delta in types
      assert :thinking_end in types
      assert {:done, :stop, final} = List.last(events)
      assert [%ThinkingContent{thinking: "Summarized reasoning"}] = final.content
    end

    test "emits thinking from reasoning_text events" do
      body =
        sse_body([
          %{"type" => "response.reasoning_text.delta", "delta" => "Step"},
          %{"type" => "response.reasoning_text.done", "text" => "Step"},
          %{"type" => "response.completed", "response" => %{}}
        ])

      stub_openai(OpenAIResponsesReasoningText, body)

      events =
        OpenAIResponses.stream(model(), context(), plug: {Req.Test, OpenAIResponsesReasoningText})
        |> Enum.to_list()

      assert {:done, :stop, final} = List.last(events)
      assert [%ThinkingContent{thinking: "Step"}] = final.content
    end

    test "emits text and thinking blocks in order" do
      body =
        sse_body([
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "Plan"},
          %{"type" => "response.output_text.delta", "delta" => "Answer"},
          %{"type" => "response.completed", "response" => %{}}
        ])

      stub_openai(OpenAIResponsesMixed, body)

      events =
        OpenAIResponses.stream(model(), context(), plug: {Req.Test, OpenAIResponsesMixed})
        |> Enum.to_list()

      assert {:done, :stop, final} = List.last(events)
      assert [%ThinkingContent{thinking: "Plan"}, %TextContent{text: "Answer"}] = final.content
    end

    test "emits tool call events and parses final arguments" do
      body =
        sse_body([
          %{
            "type" => "response.output_item.added",
            "output_index" => 0,
            "item" => %{
              "id" => "fc_1",
              "type" => "function_call",
              "call_id" => "call_1",
              "name" => "get_weather",
              "arguments" => ""
            }
          },
          %{
            "type" => "response.function_call_arguments.delta",
            "item_id" => "fc_1",
            "delta" => ~s({"city":"Lon)
          },
          %{
            "type" => "response.function_call_arguments.done",
            "item_id" => "fc_1",
            "arguments" => ~s({"city":"London"})
          },
          %{"type" => "response.completed", "response" => %{}}
        ])

      stub_openai(OpenAIResponsesTool, body)

      events =
        OpenAIResponses.stream(model(), context(), plug: {Req.Test, OpenAIResponsesTool})
        |> Enum.to_list()

      types = Enum.map(events, &elem(&1, 0))

      assert :toolcall_start in types
      assert :toolcall_delta in types
      assert :toolcall_end in types
      assert {:done, :tool_use, final} = List.last(events)

      assert [%ToolCall{id: "call_1", name: "get_weather", arguments: %{"city" => "London"}}] =
               final.content
    end

    test "uses the responses endpoint and reasoning settings" do
      received = :ets.new(:received_responses_body, [:set, :public])

      Req.Test.stub(OpenAIResponsesRequest, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        :ets.insert(received, {:body, body})
        :ets.insert(received, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      model =
        Model.new("gpt-5.4", "openai_responses",
          provider_params: %ProviderParams.OpenAIResponses{
            reasoning_effort: "low",
            reasoning_summary: "auto"
          }
        )

      PiEx.AI.stream(model, context(), plug: {Req.Test, OpenAIResponsesRequest})
      |> Enum.to_list()

      [{:path, path}] = :ets.lookup(received, :path)
      [{:body, raw}] = :ets.lookup(received, :body)
      decoded = Jason.decode!(raw)

      assert path == "/v1/responses"
      assert decoded["reasoning"]["summary"] == "auto"
      assert decoded["reasoning"]["effort"] == "low"
    end
  end
end

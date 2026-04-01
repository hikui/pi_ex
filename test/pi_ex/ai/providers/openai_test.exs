defmodule PiEx.AI.Providers.OpenAITest do
  # async: false because Req.Test stubs are process-based
  use ExUnit.Case, async: false

  alias PiEx.AI.Model
  alias PiEx.AI.Context
  alias PiEx.AI.Message
  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.Message.AssistantMessage
  alias PiEx.AI.Providers.OpenAI

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp model, do: Model.new("gpt-4o", "openai")

  defp context(text \\ "Hello!") do
    %Context{messages: [Message.user(text)]}
  end

  # Build a minimal SSE body from a list of JSON-map chunks.
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

  defp collect_events(stream) do
    Enum.to_list(stream)
  end

  # ---------------------------------------------------------------------------
  # Text streaming
  # ---------------------------------------------------------------------------

  describe "stream/3 - text response" do
    test "emits :start as first event" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Hi"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_openai(OpenAITextStart, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextStart}))

      assert {:start, %AssistantMessage{}} = hd(events)
    end

    test "emits text_start, text_delta, text_end, done for a simple reply" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "He"}, finish_reason: nil}]},
          %{choices: [%{delta: %{content: "llo"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_openai(OpenAITextFlow, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextFlow}))

      types = Enum.map(events, &elem(&1, 0))
      assert :start in types
      assert :text_start in types
      assert :text_delta in types
      assert :text_end in types
      assert :done in types
    end

    test "text_delta events carry the delta string" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Hello"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_openai(OpenAITextDelta, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextDelta}))

      deltas =
        for {:text_delta, _idx, delta, _partial} <- events, do: delta

      assert deltas == ["Hello"]
    end

    test "final AssistantMessage in :done has full text content" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "World"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_openai(OpenAITextFinal, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextFinal}))

      {:done, :stop, final} = List.last(events)
      assert [%TextContent{text: "World"}] = final.content
    end

    test "multi-chunk text is concatenated in final message" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Hel"}, finish_reason: nil}]},
          %{choices: [%{delta: %{content: "lo"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_openai(OpenAITextConcat, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextConcat}))

      {:done, :stop, final} = List.last(events)
      assert [%TextContent{text: "Hello"}] = final.content
    end

    test "stop reason :length is propagated" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Trun"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "length"}]}
        ])

      stub_openai(OpenAITextLength, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextLength}))

      assert {:done, :length, _} = List.last(events)
    end

    test "usage is reflected in the final message" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Hi"}, finish_reason: nil}]},
          %{
            choices: [%{delta: %{}, finish_reason: "stop"}],
            usage: %{prompt_tokens: 10, completion_tokens: 3, total_tokens: 13}
          }
        ])

      stub_openai(OpenAITextUsage, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAITextUsage}))

      {:done, :stop, final} = List.last(events)
      assert final.usage.input_tokens == 10
      assert final.usage.output_tokens == 3
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call streaming
  # ---------------------------------------------------------------------------

  describe "stream/3 - tool call response" do
    test "emits toolcall_start, toolcall_delta, toolcall_end events" do
      body =
        sse_body([
          %{
            choices: [
              %{
                delta: %{
                  tool_calls: [
                    %{index: 0, id: "call_1", function: %{name: "get_weather", arguments: ""}}
                  ]
                },
                finish_reason: nil
              }
            ]
          },
          %{
            choices: [
              %{
                delta: %{
                  tool_calls: [%{index: 0, function: %{arguments: ~s({"city":"London"})}}]
                },
                finish_reason: nil
              }
            ]
          },
          %{choices: [%{delta: %{}, finish_reason: "tool_calls"}]}
        ])

      stub_openai(OpenAIToolCall, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAIToolCall}))

      types = Enum.map(events, &elem(&1, 0))
      assert :toolcall_start in types
      assert :toolcall_delta in types
      assert :toolcall_end in types
    end

    test "final :done carries :tool_use stop reason" do
      body =
        sse_body([
          %{
            choices: [
              %{
                delta: %{
                  tool_calls: [%{index: 0, id: "call_1", function: %{name: "f", arguments: "{}"}}]
                },
                finish_reason: nil
              }
            ]
          },
          %{choices: [%{delta: %{}, finish_reason: "tool_calls"}]}
        ])

      stub_openai(OpenAIToolStop, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAIToolStop}))

      assert {:done, :tool_use, _} = List.last(events)
    end

    test "final ToolCall has parsed arguments" do
      body =
        sse_body([
          %{
            choices: [
              %{
                delta: %{
                  tool_calls: [
                    %{index: 0, id: "call_1", function: %{name: "get_weather", arguments: ~s({"city":"Paris"})}}
                  ]
                },
                finish_reason: nil
              }
            ]
          },
          %{choices: [%{delta: %{}, finish_reason: "tool_calls"}]}
        ])

      stub_openai(OpenAIToolArgs, body)
      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAIToolArgs}))

      {:done, :tool_use, final} = List.last(events)
      assert [%ToolCall{name: "get_weather", arguments: %{"city" => "Paris"}}] = final.content
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "stream/3 - error handling" do
    test "HTTP non-2xx returns :error event" do
      stub_openai(OpenAIHttp401, ~s({"error": "unauthorized"}), 401)

      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAIHttp401}))

      assert Enum.any?(events, &match?({:error, :error, _}, &1))
    end

    test "error message contains HTTP status" do
      stub_openai(OpenAIHttp500, ~s({"error": "server error"}), 500)

      events = collect_events(OpenAI.stream(model(), context(), plug: {Req.Test, OpenAIHttp500}))

      {:error, :error, msg} = Enum.find(events, &match?({:error, :error, _}, &1))
      assert String.contains?(msg.error_message, "500")
    end
  end

  # ---------------------------------------------------------------------------
  # Context conversion
  # ---------------------------------------------------------------------------

  describe "stream/3 - system prompt" do
    test "system prompt is included in the request messages" do
      received = :ets.new(:received_body, [:set, :public])

      Req.Test.stub(OpenAISystemPrompt, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        :ets.insert(received, {:body, body})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      ctx = %Context{
        system_prompt: "You are a test assistant.",
        messages: [Message.user("Hi")]
      }

      OpenAI.stream(model(), ctx, plug: {Req.Test, OpenAISystemPrompt}) |> Enum.to_list()

      [{:body, raw}] = :ets.lookup(received, :body)
      decoded = Jason.decode!(raw)
      system_msgs = Enum.filter(decoded["messages"], &(&1["role"] == "system"))
      assert length(system_msgs) == 1
      assert hd(system_msgs)["content"] == "You are a test assistant."
    end
  end

  # ---------------------------------------------------------------------------
  # Custom base_url
  # ---------------------------------------------------------------------------

  describe "stream/3 - custom base_url" do
    test "uses the provided :base_url for the request" do
      received = :ets.new(:received_url, [:set, :public])

      Req.Test.stub(OpenAICustomBaseUrl, fn conn ->
        :ets.insert(received, {:path, conn.request_path})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      OpenAI.stream(model(), context(),
        plug: {Req.Test, OpenAICustomBaseUrl},
        base_url: "http://custom-litellm-host/v1"
      )
      |> Enum.to_list()

      [{:path, path}] = :ets.lookup(received, :path)
      assert path == "/v1/chat/completions"
    end
  end

  # ---------------------------------------------------------------------------
  # Integration test (only when API key is available)
  # ---------------------------------------------------------------------------

  describe "stream/3 - real OpenAI API" do
    @describetag :integration
    test "streams a simple reply" do
      api_key = System.get_env("OPENAI_API_KEY")

      if is_nil(api_key) do
        IO.puts("Skipping integration test: OPENAI_API_KEY not set")
      else
        ctx = %Context{messages: [Message.user("Say 'pong' and nothing else.")]}
        m = Model.new("gpt-4o-mini", "openai")
        events = OpenAI.stream(m, ctx, api_key: api_key) |> Enum.to_list()
        assert {:done, :stop, final} = List.last(events)
        text = for %TextContent{text: t} <- final.content, do: t
        assert String.contains?(Enum.join(text), "pong")
      end
    end
  end
end

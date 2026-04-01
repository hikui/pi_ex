defmodule PiEx.AITest do
  use ExUnit.Case, async: false

  alias PiEx.AI
  alias PiEx.AI.{Context, Message, Model}
  alias PiEx.AI.Content.ThinkingContent
  alias PiEx.AI.ProviderParams

  defp context(text \\ "Hello!"), do: %Context{messages: [Message.user(text)]}

  defp sse_body(chunks) do
    lines =
      Enum.map(chunks, fn chunk ->
        "data: #{Jason.encode!(chunk)}"
      end)

    (lines ++ ["data: [DONE]", ""]) |> Enum.join("\n\n")
  end

  describe "stream/3" do
    test "dispatches to openai_responses" do
      body =
        sse_body([
          %{"type" => "response.reasoning_summary_text.delta", "delta" => "thinking"},
          %{"type" => "response.completed", "response" => %{}}
        ])

      Req.Test.stub(AIResponsesDispatch, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, body)
      end)

      events =
        AI.stream(Model.new("gpt-5.4", "openai_responses"), context(),
          plug: {Req.Test, AIResponsesDispatch}
        )
        |> Enum.to_list()

      assert {:done, :stop, final} = List.last(events)
      assert [%ThinkingContent{thinking: "thinking"}] = final.content
    end

    test "returns an error event for unknown providers" do
      [event] = AI.stream(Model.new("gpt-5.4", "missing_provider"), context())
      assert {:error, :error, message} = event
      assert message.error_message == "Unknown provider: missing_provider"
    end

    test "returns an error event for mismatched provider params" do
      model =
        Model.new("gpt-5.4", "openai_responses",
          provider_params: %ProviderParams.OpenAI{temperature: 0.2}
        )

      [event] = AI.stream(model, context())
      assert {:error, :error, message} = event
      assert message.error_message =~ "do not match provider openai_responses"
    end
  end
end

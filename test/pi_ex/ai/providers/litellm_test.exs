defmodule PiEx.AI.Providers.LiteLLMTest do
  # async: false because Req.Test stubs are process-based
  use ExUnit.Case, async: false

  alias PiEx.AI.Model
  alias PiEx.AI.Context
  alias PiEx.AI.Message
  alias PiEx.AI.Content.TextContent
  alias PiEx.AI.Message.AssistantMessage
  alias PiEx.AI.Providers.LiteLLM

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp model, do: Model.new("gpt-4o", "litellm")

  defp context(text \\ "Hello!") do
    %Context{messages: [Message.user(text)]}
  end

  defp sse_body(chunks) do
    lines = Enum.map(chunks, fn chunk -> "data: #{Jason.encode!(chunk)}" end)
    (lines ++ ["data: [DONE]", ""]) |> Enum.join("\n\n")
  end

  defp stub_litellm(stub_name, body, status \\ 200) do
    Req.Test.stub(stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/event-stream")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp collect_events(stream), do: Enum.to_list(stream)

  # ---------------------------------------------------------------------------
  # Text streaming (delegates to OpenAI provider)
  # ---------------------------------------------------------------------------

  describe "stream/3 - text response" do
    test "emits :start as first event" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "Hi"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_litellm(LiteLLMTextStart, body)

      events =
        collect_events(
          LiteLLM.stream(model(), context(), plug: {Req.Test, LiteLLMTextStart})
        )

      assert {:start, %AssistantMessage{}} = hd(events)
    end

    test "emits text_start, text_delta, text_end, done for a simple reply" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "He"}, finish_reason: nil}]},
          %{choices: [%{delta: %{content: "llo"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_litellm(LiteLLMTextFlow, body)

      events =
        collect_events(
          LiteLLM.stream(model(), context(), plug: {Req.Test, LiteLLMTextFlow})
        )

      types = Enum.map(events, &elem(&1, 0))
      assert :start in types
      assert :text_start in types
      assert :text_delta in types
      assert :text_end in types
      assert :done in types
    end

    test "final AssistantMessage in :done has full text content" do
      body =
        sse_body([
          %{choices: [%{delta: %{content: "World"}, finish_reason: nil}]},
          %{choices: [%{delta: %{}, finish_reason: "stop"}]}
        ])

      stub_litellm(LiteLLMTextFinal, body)

      events =
        collect_events(
          LiteLLM.stream(model(), context(), plug: {Req.Test, LiteLLMTextFinal})
        )

      {:done, :stop, final} = List.last(events)
      assert [%TextContent{text: "World"}] = final.content
    end
  end

  # ---------------------------------------------------------------------------
  # Base URL and API key resolution
  # ---------------------------------------------------------------------------

  describe "stream/3 - configuration" do
    test "explicit :base_url opt takes precedence over env var" do
      received = :ets.new(:litellm_base_url, [:set, :public])

      Req.Test.stub(LiteLLMBaseUrlOpt, fn conn ->
        :ets.insert(received, {:host, conn.host})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      LiteLLM.stream(model(), context(),
        plug: {Req.Test, LiteLLMBaseUrlOpt},
        base_url: "http://my-litellm-host/v1"
      )
      |> Enum.to_list()

      [{:host, host}] = :ets.lookup(received, :host)
      assert host == "my-litellm-host"
    end

    test "explicit :api_key opt takes precedence over env var" do
      received = :ets.new(:litellm_api_key, [:set, :public])

      Req.Test.stub(LiteLLMApiKeyOpt, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
        :ets.insert(received, {:auth, auth})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      LiteLLM.stream(model(), context(),
        plug: {Req.Test, LiteLLMApiKeyOpt},
        api_key: "sk-explicit-key"
      )
      |> Enum.to_list()

      [{:auth, auth}] = :ets.lookup(received, :auth)
      assert auth == "Bearer sk-explicit-key"
    end

    test "falls back to LITELLM_API_KEY env var when no :api_key opt given" do
      received = :ets.new(:litellm_env_key, [:set, :public])

      Req.Test.stub(LiteLLMEnvApiKey, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
        :ets.insert(received, {:auth, auth})

        conn
        |> Plug.Conn.put_resp_content_type("text/event-stream")
        |> Plug.Conn.send_resp(200, "data: [DONE]\n\n")
      end)

      System.put_env("LITELLM_API_KEY", "sk-env-key")

      try do
        LiteLLM.stream(model(), context(), plug: {Req.Test, LiteLLMEnvApiKey})
        |> Enum.to_list()

        [{:auth, auth}] = :ets.lookup(received, :auth)
        assert auth == "Bearer sk-env-key"
      after
        System.delete_env("LITELLM_API_KEY")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling (delegates to OpenAI provider)
  # ---------------------------------------------------------------------------

  describe "stream/3 - error handling" do
    test "HTTP non-2xx returns :error event" do
      stub_litellm(LiteLLMHttp401, ~s({"error": "unauthorized"}), 401)

      events =
        collect_events(
          LiteLLM.stream(model(), context(), plug: {Req.Test, LiteLLMHttp401})
        )

      assert Enum.any?(events, &match?({:error, :error, _}, &1))
    end
  end
end

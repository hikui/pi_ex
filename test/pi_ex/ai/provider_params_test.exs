defmodule PiEx.AI.ProviderParamsTest do
  use ExUnit.Case, async: true

  alias PiEx.AI.{Model, ProviderParams}

  describe "to_opts/1" do
    test "returns an empty keyword list when provider params are absent" do
      assert {:ok, []} = ProviderParams.to_opts(Model.new("gpt-4o", "openai"))
    end

    test "maps OpenAI Responses params to provider opts" do
      model =
        Model.new("gpt-5.4", "openai_responses",
          provider_params: %ProviderParams.OpenAIResponses{
            api_key: "sk-openai",
            base_url: "https://example.test/v1",
            temperature: 0.3,
            max_tokens: 400,
            reasoning_effort: "low",
            reasoning_summary: "auto"
          }
        )

      assert {:ok, opts} = ProviderParams.to_opts(model)
      assert opts[:api_key] == "sk-openai"
      assert opts[:base_url] == "https://example.test/v1"
      assert opts[:temperature] == 0.3
      assert opts[:max_tokens] == 400
      assert opts[:reasoning_effort] == "low"
      assert opts[:reasoning_summary] == "auto"
    end

    test "maps OpenAI params without unrelated reasoning fields" do
      model =
        Model.new("gpt-4o", "openai",
          provider_params: %ProviderParams.OpenAI{
            api_key: "sk-openai",
            temperature: 0.1,
            max_tokens: 50
          }
        )

      assert {:ok, opts} = ProviderParams.to_opts(model)
      assert opts[:api_key] == "sk-openai"
      assert opts[:temperature] == 0.1
      assert opts[:max_tokens] == 50
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "maps LiteLLM params without unrelated reasoning fields" do
      model =
        Model.new("gpt-4o", "litellm",
          provider_params: %ProviderParams.LiteLLM{
            api_key: "sk-litellm",
            base_url: "http://localhost:4000/v1",
            temperature: 0.4,
            max_tokens: 60
          }
        )

      assert {:ok, opts} = ProviderParams.to_opts(model)
      assert opts[:api_key] == "sk-litellm"
      assert opts[:base_url] == "http://localhost:4000/v1"
      assert opts[:temperature] == 0.4
      assert opts[:max_tokens] == 60
      refute Keyword.has_key?(opts, :reasoning_effort)
    end

    test "returns an error for mismatched provider and params" do
      model =
        Model.new("gpt-5.4", "openai_responses",
          provider_params: %ProviderParams.OpenAI{temperature: 0.2}
        )

      assert {:error, message} = ProviderParams.to_opts(model)
      assert message =~ "do not match provider openai_responses"
    end
  end

  describe "api_key/1" do
    test "returns the explicit api key from provider params" do
      model =
        Model.new("gpt-4o", "openai",
          provider_params: %ProviderParams.OpenAI{api_key: "sk-openai"}
        )

      assert ProviderParams.api_key(model) == "sk-openai"
    end

    test "returns nil when the provider params do not set an api key" do
      assert ProviderParams.api_key(Model.new("gpt-4o", "openai")) == nil
    end
  end
end

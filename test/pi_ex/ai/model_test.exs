defmodule PiEx.AI.ModelTest do
  use ExUnit.Case, async: true

  alias PiEx.AI.Model
  alias PiEx.AI.ProviderParams

  describe "new/2" do
    test "creates a model struct" do
      model = Model.new("gpt-4o", "openai")
      assert model.id == "gpt-4o"
      assert model.provider == "openai"
      assert model.provider_params == nil
    end

    test "stores arbitrary provider names" do
      model = Model.new("claude-3-5-sonnet-20241022", "anthropic")
      assert model.provider == "anthropic"
    end

    test "accepts provider params and context window via opts" do
      params = %ProviderParams.OpenAIResponses{reasoning_effort: "low"}

      model =
        Model.new("gpt-5.4", "openai_responses",
          context_window: 200_000,
          provider_params: params
        )

      assert model.context_window == 200_000
      assert model.provider_params == params
    end
  end

  describe "helpers" do
    test "with_provider_params/2 updates the provider params" do
      params = %ProviderParams.OpenAI{temperature: 0.2}
      model = Model.new("gpt-4o", "openai") |> Model.with_provider_params(params)

      assert model.provider_params == params
    end

    test "with_context_window/2 updates the context window" do
      model = Model.new("gpt-4o", "openai") |> Model.with_context_window(128_000)
      assert model.context_window == 128_000
    end
  end

  describe "struct" do
    test "enforces :id and :provider keys" do
      assert_raise ArgumentError, fn -> struct!(Model, %{id: "gpt-4o"}) end
      assert_raise ArgumentError, fn -> struct!(Model, %{provider: "openai"}) end
    end
  end
end

defmodule PiEx.AI.Providers.LiteLLM do
  @moduledoc """
  LiteLLM provider — delegates to the OpenAI provider with a custom base URL.

  LiteLLM is an OpenAI-compatible proxy server. Configure via:
  - `LITELLM_API_BASE` env var (default: "http://localhost:4000/v1")
  - `LITELLM_API_KEY` env var

  Options passed to `stream/3` take precedence over environment variables.
  """

  alias PiEx.AI.{Model, Context}

  @default_base_url "http://localhost:4000/v1"

  @doc """
  Returns a lazy stream of `PiEx.AI.StreamEvent.t()` events.

  Options:
  - `:api_key` — overrides `LITELLM_API_KEY` env var
  - `:base_url` — overrides `LITELLM_API_BASE` env var and the default base URL
  - `:temperature` — float (default: model default)
  - `:max_tokens` — integer
  - `:http_receive_timeout` — Req receive timeout in milliseconds (forwarded to OpenAI-compatible requests)
  - `:system_prompt` — prepended as a system message (overrides `context.system_prompt`)
  """
  @spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t()
  def stream(%Model{} = model, %Context{} = context, opts \\ []) do
    base_url =
      Keyword.get(opts, :base_url) || PiEx.AI.ProviderConfig.get_base_url("litellm") ||
        @default_base_url

    api_key = Keyword.get(opts, :api_key) || PiEx.AI.ProviderConfig.get_api_key("litellm") || ""

    merged_opts =
      opts
      |> Keyword.put_new(:base_url, base_url)
      |> Keyword.put_new(:api_key, api_key)

    PiEx.AI.Providers.OpenAI.stream(model, context, merged_opts)
  end
end

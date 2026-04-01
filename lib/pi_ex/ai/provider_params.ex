defmodule PiEx.AI.ProviderParams do
  @moduledoc """
  Typed runtime parameters for provider-backed models.
  """

  alias PiEx.AI.Model

  defmodule OpenAI do
    @moduledoc "Runtime params supported by the OpenAI chat completions provider."

    defstruct [:api_key, :base_url, :temperature, :max_tokens]

    @type t :: %__MODULE__{
            api_key: String.t() | nil,
            base_url: String.t() | nil,
            temperature: float() | nil,
            max_tokens: pos_integer() | nil
          }
  end

  defmodule OpenAIResponses do
    @moduledoc "Runtime params supported by the OpenAI Responses provider."

    defstruct [
      :api_key,
      :base_url,
      :temperature,
      :max_tokens,
      :reasoning_effort,
      :reasoning_summary
    ]

    @type t :: %__MODULE__{
            api_key: String.t() | nil,
            base_url: String.t() | nil,
            temperature: float() | nil,
            max_tokens: pos_integer() | nil,
            reasoning_effort: String.t() | nil,
            reasoning_summary: String.t() | nil
          }
  end

  defmodule LiteLLM do
    @moduledoc "Runtime params supported by the LiteLLM provider."

    defstruct [:api_key, :base_url, :temperature, :max_tokens]

    @type t :: %__MODULE__{
            api_key: String.t() | nil,
            base_url: String.t() | nil,
            temperature: float() | nil,
            max_tokens: pos_integer() | nil
          }
  end

  @type t :: OpenAI.t() | OpenAIResponses.t() | LiteLLM.t()

  @doc "Convert a model's provider params into provider stream opts."
  @spec to_opts(Model.t()) :: {:ok, keyword()} | {:error, String.t()}
  def to_opts(%Model{provider_params: nil}), do: {:ok, []}

  def to_opts(%Model{provider: "openai", provider_params: %OpenAI{} = params}) do
    {:ok, common_opts(params)}
  end

  def to_opts(%Model{provider: "openai_responses", provider_params: %OpenAIResponses{} = params}) do
    {:ok,
     params
     |> common_opts()
     |> maybe_put(:reasoning_effort, params.reasoning_effort)
     |> maybe_put(:reasoning_summary, params.reasoning_summary)}
  end

  def to_opts(%Model{provider: "litellm", provider_params: %LiteLLM{} = params}) do
    {:ok, common_opts(params)}
  end

  def to_opts(%Model{provider: provider, provider_params: provider_params}) do
    {:error,
     "Provider params #{inspect(provider_params.__struct__)} do not match provider #{provider}"}
  end

  @doc "Return an explicit API key from the model provider params when one is configured."
  @spec api_key(Model.t()) :: String.t() | nil
  def api_key(%Model{provider_params: %{api_key: api_key}})
      when is_binary(api_key) and api_key != "" do
    api_key
  end

  def api_key(%Model{}), do: nil

  defp common_opts(params) do
    []
    |> maybe_put(:api_key, params.api_key)
    |> maybe_put(:base_url, params.base_url)
    |> maybe_put(:temperature, params.temperature)
    |> maybe_put(:max_tokens, params.max_tokens)
  end

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end

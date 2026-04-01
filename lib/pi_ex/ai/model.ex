defmodule PiEx.AI.Model do
  @moduledoc "Identifies an LLM model from a specific provider."
  @enforce_keys [:id, :provider]
  alias PiEx.AI.ProviderParams

  defstruct [:id, :provider, context_window: nil, provider_params: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t(),
          context_window: pos_integer() | nil,
          provider_params: ProviderParams.t() | nil
        }

  @doc "Construct a Model."
  @spec new(String.t(), String.t(), keyword()) :: t()
  def new(id, provider, opts \\ []) do
    %__MODULE__{
      id: id,
      provider: provider,
      context_window: Keyword.get(opts, :context_window),
      provider_params: Keyword.get(opts, :provider_params)
    }
  end

  @doc "Return a copy of the model with updated provider params."
  @spec with_provider_params(t(), ProviderParams.t() | nil) :: t()
  def with_provider_params(%__MODULE__{} = model, provider_params) do
    %{model | provider_params: provider_params}
  end

  @doc "Return a copy of the model with an updated context window."
  @spec with_context_window(t(), pos_integer() | nil) :: t()
  def with_context_window(%__MODULE__{} = model, context_window) do
    %{model | context_window: context_window}
  end
end

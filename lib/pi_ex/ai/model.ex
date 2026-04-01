defmodule PiEx.AI.Model do
  @moduledoc "Identifies an LLM model from a specific provider."
  @enforce_keys [:id, :provider]
  defstruct [:id, :provider, context_window: nil]

  @type t :: %__MODULE__{
          id: String.t(),
          provider: String.t(),
          context_window: pos_integer() | nil
        }

  @doc "Construct a Model."
  @spec new(String.t(), String.t()) :: t()
  def new(id, provider), do: %__MODULE__{id: id, provider: provider}
end

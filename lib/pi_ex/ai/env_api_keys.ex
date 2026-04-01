defmodule PiEx.AI.EnvApiKeys do
  @moduledoc "Maps provider names to their environment variable API keys."

  @provider_env_vars %{
    "openai" => "OPENAI_API_KEY",
    "litellm" => "LITELLM_API_KEY"
  }

  @doc """
  Returns the API key for the given provider from the environment,
  or `nil` if the environment variable is not set.
  """
  @spec get(String.t()) :: String.t() | nil
  def get(provider) do
    case Map.fetch(@provider_env_vars, provider) do
      {:ok, env_var} -> System.get_env(env_var)
      :error -> nil
    end
  end

  @doc "Returns the environment variable name for the given provider, or `nil`."
  @spec env_var_name(String.t()) :: String.t() | nil
  def env_var_name(provider), do: Map.get(@provider_env_vars, provider)
end

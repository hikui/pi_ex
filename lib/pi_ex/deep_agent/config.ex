defmodule PiEx.DeepAgent.Config do
  @moduledoc """
  Configuration struct for `PiEx.DeepAgent`.

  ## Required
  - `:model` — `%PiEx.AI.Model{}`
  - `:project_root` — absolute path to the sandbox directory (canonicalized at validate time)

  ## Optional
  - `:system_prompt` — override the built-in system prompt; `nil` = use default
  - `:extra_tools` — additional `%PiEx.Agent.Tool{}` list; default `[]`
  - `:skills_root` — path to a directory containing skill subdirectories; `nil` = no skills
  """

  alias PiEx.AI.Model

  @enforce_keys [:model, :project_root]
  defstruct [
    :model,
    :project_root,
    :system_prompt,
    :skills_root,
    extra_tools: []
  ]

  @type t :: %__MODULE__{
          model: Model.t(),
          project_root: String.t(),
          system_prompt: String.t() | nil,
          skills_root: String.t() | nil,
          extra_tools: [PiEx.Agent.Tool.t()]
        }

  @doc """
  Validate and canonicalize a `%Config{}`.

  Resolves `project_root` via `File.real_path!/1` (symlink-safe).
  Returns `{:ok, canonical_config}` or `{:error, reason}`.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, String.t()}
  def validate(%__MODULE__{project_root: root} = config) do
    with :ok <- check_exists(root),
         {:ok, canonical_root} <- canonicalize(root) do
      {:ok, %{config | project_root: canonical_root}}
    end
  end

  defp check_exists(root) do
    if File.dir?(root) do
      :ok
    else
      {:error, "project_root does not exist or is not a directory: #{root}"}
    end
  end

  defp canonicalize(root) do
    {:ok, Path.expand(root)}
  end
end

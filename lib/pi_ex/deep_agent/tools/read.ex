defmodule PiEx.DeepAgent.Tools.Read do
  @moduledoc "LLM tool: read a file with line numbers, optional offset and limit."

  alias PiEx.Agent.Tool
  alias PiEx.AI.Content.TextContent
  alias PiEx.DeepAgent.PathGuard
  alias PiEx.DeepAgent.Tools.Truncate

  @doc """
  Build a `%PiEx.Agent.Tool{}` scoped to `project_root`.

  Options:
  - `:allowed_paths` — list of absolute file paths that may be read even when
    outside `project_root` (used for skill files).
  """
  @spec tool(String.t(), keyword()) :: Tool.t()
  def tool(project_root, opts \\ []) do
    allowed_paths = Keyword.get(opts, :allowed_paths, [])

    %Tool{
      name: "read",
      label: "Read File",
      description: """
      Read a file and return its contents with line numbers prefixed as \"  N | content\".
      Supports optional offset (1-indexed start line) and limit (max lines to return).
      Large files are automatically truncated.
      """,
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" =>
              "File path to read. Use a relative path for project files, or an exact absolute path when reading an allowlisted skill file."
          },
          "offset" => %{
            "type" => "integer",
            "description" => "1-indexed line number to start reading from."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of lines to return."
          }
        },
        "required" => ["path"]
      },
      execute: fn _call_id, params, _opts ->
        path = Map.fetch!(params, "path")
        offset = Map.get(params, "offset")
        limit = Map.get(params, "limit")

        case execute(%{path: path, offset: offset, limit: limit}, project_root,
               allowed_paths: allowed_paths
             ) do
          {:ok, text} -> {:ok, %{content: [%TextContent{text: text}], details: nil}}
          {:error, reason} -> {:error, reason}
        end
      end
    }
  end

  @doc "Execute the read operation directly (for testing)."
  @spec execute(map(), String.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(params, project_root, opts \\ []) do
    path = Map.fetch!(params, :path)
    offset = Map.get(params, :offset)
    limit = Map.get(params, :limit)
    allowed_paths = Keyword.get(opts, :allowed_paths, [])

    with {:ok, abs_path} <- resolve_path(project_root, path, allowed_paths),
         {:ok, content} <- safe_read(abs_path) do
      lines = String.split(content, "\n")
      sliced = slice_lines(lines, offset, limit)

      start_line = if is_integer(offset) and offset >= 1, do: offset, else: 1

      {truncated_lines, _meta} =
        sliced
        |> Enum.join("\n")
        |> Truncate.truncate_head()

      numbered =
        truncated_lines
        |> String.split("\n")
        |> Enum.with_index(start_line)
        |> Enum.map(fn {line, n} -> "#{String.pad_leading(to_string(n), 5)} | #{line}" end)
        |> Enum.join("\n")

      {:ok, numbered}
    end
  end

  # Resolve path: bypass PathGuard for exact allowed_paths entries.
  defp resolve_path(project_root, path, allowed_paths) when is_list(allowed_paths) do
    expanded = Path.expand(path)

    if expanded in allowed_paths do
      {:ok, expanded}
    else
      PathGuard.resolve(project_root, path)
    end
  end

  defp safe_read(abs_path) do
    case File.read(abs_path) do
      {:ok, content} -> {:ok, content}
      {:error, :enoent} -> {:error, "File not found: #{abs_path}"}
      {:error, reason} -> {:error, "Cannot read file: #{reason}"}
    end
  end

  defp slice_lines(lines, nil, nil), do: lines
  defp slice_lines(lines, nil, limit), do: Enum.take(lines, limit)

  defp slice_lines(lines, offset, nil) when is_integer(offset) and offset >= 1 do
    Enum.drop(lines, offset - 1)
  end

  defp slice_lines(lines, offset, limit) when is_integer(offset) and offset >= 1 do
    lines |> Enum.drop(offset - 1) |> Enum.take(limit)
  end

  defp slice_lines(lines, _, _), do: lines
end

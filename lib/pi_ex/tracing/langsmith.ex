defmodule PiEx.Tracing.LangSmith do
  @moduledoc false
  @behaviour PiEx.Tracing.Adapter

  require Logger

  alias PiEx.Tracing.Payload

  @default_endpoint "https://api.smith.langchain.com"

  @impl true
  def start_span(parent_handle, attrs) do
    with {:ok, config} <- config(),
         run_id <- uuid4(),
         body <- start_body(run_id, parent_handle, attrs, config),
         :ok <- request(:post, config, "/runs", body) do
      {:ok, %{config: config, id: run_id}}
    end
  end

  @impl true
  def finish_span(handle, outputs, opts) do
    body =
      %{
        outputs: Payload.normalize(outputs),
        end_time: timestamp(),
        error: Keyword.get(opts, :error)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Enum.into(%{})

    request(:patch, handle.config, "/runs/#{handle.id}", body)
  end

  @impl true
  def fail_span(handle, error, outputs, opts) do
    opts =
      opts
      |> Keyword.put_new(:error, normalize_error(error))

    finish_span(handle, outputs, opts)
  end

  def enabled? do
    match?({:ok, _config}, config())
  end

  defp config do
    case Application.get_env(:pi_ex, :enable_langsmith_tracing, false) do
      true -> resolve_config()
      _ -> {:error, :disabled}
    end
  end

  defp resolve_config do
    app_config = Application.get_env(:pi_ex, :langsmith, [])

    config = %{
      api_key: env_or_config("LANGSMITH_API_KEY", app_config, :api_key),
      endpoint: env_or_config("LANGSMITH_ENDPOINT", app_config, :endpoint) || @default_endpoint,
      project: env_or_config("LANGSMITH_PROJECT", app_config, :project),
      workspace_id: env_or_config("LANGSMITH_WORKSPACE_ID", app_config, :workspace_id),
      tags: Keyword.get(app_config, :tags, []),
      metadata: Keyword.get(app_config, :metadata, %{}),
      plug: Keyword.get(app_config, :plug),
      receive_timeout: Keyword.get(app_config, :receive_timeout, 5_000)
    }

    case config.api_key do
      api_key when is_binary(api_key) and api_key != "" -> {:ok, config}
      _ -> {:error, :missing_api_key}
    end
  end

  defp env_or_config(env_name, app_config, key) do
    System.get_env(env_name) || Keyword.get(app_config, key)
  end

  defp start_body(run_id, parent_handle, attrs, config) do
    metadata =
      config.metadata
      |> Map.merge(Payload.normalize(Map.get(attrs, :metadata, %{})) || %{})

    %{
      id: run_id,
      name: Map.fetch!(attrs, :name),
      run_type: encode_run_type(Map.fetch!(attrs, :type)),
      inputs: Payload.normalize(Map.get(attrs, :inputs, %{})),
      start_time: timestamp(),
      parent_run_id: parent_id(parent_handle),
      session_name: config.project,
      extra: %{metadata: metadata},
      tags: Enum.uniq(config.tags ++ Map.get(attrs, :tags, []))
    }
    |> Enum.reject(fn {_key, value} ->
      is_nil(value) or value == [] or value == %{}
    end)
    |> Enum.into(%{})
  end

  defp request(method, config, path, body) do
    req_options =
      [
        method: method,
        url: build_url(config.endpoint, path),
        json: body,
        headers: headers(config),
        receive_timeout: config.receive_timeout
      ]
      |> maybe_put_plug(config.plug)

    case Req.request(req_options) do
      {:ok, %Req.Response{status: status}} when status in 200..299 ->
        :ok

      {:ok, %Req.Response{status: status, body: response_body}} ->
        Logger.warning(
          "LangSmith tracing request failed with status #{status}: #{inspect(response_body)}"
        )

        {:error, {:http_error, status}}

      {:error, reason} ->
        Logger.warning("LangSmith tracing request failed: #{inspect(reason)}")
        {:error, reason}
    end
  rescue
    error ->
      Logger.warning("LangSmith tracing request crashed: #{Exception.message(error)}")
      {:error, error}
  end

  defp maybe_put_plug(options, nil), do: options
  defp maybe_put_plug(options, plug), do: Keyword.put(options, :plug, plug)

  defp build_url(endpoint, path) do
    endpoint = String.trim_trailing(endpoint, "/")
    endpoint <> path
  end

  defp headers(config) do
    base_headers = [{"x-api-key", config.api_key}]

    case config.workspace_id do
      workspace_id when is_binary(workspace_id) and workspace_id != "" ->
        [{"x-tenant-id", workspace_id} | base_headers]

      _ ->
        base_headers
    end
  end

  defp parent_id(%{id: id}), do: id
  defp parent_id(_handle), do: nil

  defp encode_run_type(:chain), do: "chain"
  defp encode_run_type(:llm), do: "llm"
  defp encode_run_type(:tool), do: "tool"
  defp encode_run_type(other), do: Atom.to_string(other)

  defp normalize_error(error) when is_binary(error), do: error
  defp normalize_error(error), do: inspect(error)

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:millisecond)
    |> DateTime.to_iso8601()
  end

  defp uuid4 do
    <<a1::32, a2::16, a3::16, a4::16, a5::48>> = :crypto.strong_rand_bytes(16)
    a3 = Bitwise.band(a3, 0x0FFF) |> Bitwise.bor(0x4000)
    a4 = Bitwise.band(a4, 0x3FFF) |> Bitwise.bor(0x8000)
    hex([a1, a2, a3, a4, a5], [8, 4, 4, 4, 12])
  end

  defp hex(parts, widths) do
    parts
    |> Enum.zip(widths)
    |> Enum.map_join("-", fn {part, width} ->
      part
      |> Integer.to_string(16)
      |> String.downcase()
      |> String.pad_leading(width, "0")
    end)
  end
end

defmodule PiEx.Tracing do
  @moduledoc false

  require Logger

  alias PiEx.Tracing.{Context, Noop, Span}

  @spec enabled?() :: boolean()
  def enabled? do
    resolve_adapter() != Noop
  end

  @spec new_context(keyword()) :: Context.t()
  def new_context(opts \\ []) do
    %Context{
      adapter: Keyword.get(opts, :adapter, resolve_adapter()),
      parent_span: Keyword.get(opts, :parent_span)
    }
  end

  @spec child_context(Context.t(), Span.t()) :: Context.t()
  def child_context(%Context{} = context, %Span{} = parent_span) do
    %{context | parent_span: parent_span}
  end

  @spec start_span(Context.t() | nil, keyword()) :: Span.t()
  def start_span(context, attrs) do
    context = context || new_context()
    adapter = context.adapter
    parent_handle = parent_handle(context.parent_span)

    safe_start_span(adapter, parent_handle, Enum.into(attrs, %{}))
  end

  @spec finish_span(Span.t() | nil, map(), keyword()) :: :ok
  def finish_span(span, outputs \\ %{}, opts \\ [])

  def finish_span(nil, _outputs, _opts), do: :ok

  def finish_span(%Span{handle: nil}, _outputs, _opts), do: :ok

  def finish_span(%Span{adapter: adapter, handle: handle}, outputs, opts) do
    case safe_apply(adapter, :finish_span, [handle, outputs, opts]) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  @spec fail_span(Span.t() | nil, term(), map(), keyword()) :: :ok
  def fail_span(span, error, outputs \\ %{}, opts \\ [])

  def fail_span(nil, _error, _outputs, _opts), do: :ok

  def fail_span(%Span{handle: nil}, _error, _outputs, _opts), do: :ok

  def fail_span(%Span{adapter: adapter, handle: handle}, error, outputs, opts) do
    case safe_apply(adapter, :fail_span, [handle, error, outputs, opts]) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp safe_start_span(adapter, parent_handle, attrs) do
    name = Map.fetch!(attrs, :name)
    type = Map.fetch!(attrs, :type)

    case safe_apply(adapter, :start_span, [parent_handle, attrs]) do
      {:ok, :noop} ->
        %Span{adapter: adapter, handle: nil, name: name, type: type}

      {:ok, handle} ->
        %Span{adapter: adapter, handle: handle, name: name, type: type}

      {:error, _reason} ->
        %Span{adapter: adapter, handle: nil, name: name, type: type}
    end
  end

  defp safe_apply(adapter, function, args) do
    apply(adapter, function, args)
  rescue
    error ->
      Logger.warning(
        "Tracing adapter #{inspect(adapter)} #{function} failed: #{Exception.message(error)}"
      )

      {:error, error}
  catch
    kind, reason ->
      Logger.warning(
        "Tracing adapter #{inspect(adapter)} #{function} threw #{kind}: #{inspect(reason)}"
      )

      {:error, {kind, reason}}
  end

  defp parent_handle(nil), do: nil
  defp parent_handle(%Span{handle: handle}), do: handle

  defp resolve_adapter do
    Application.get_env(:pi_ex, :tracing_adapter) || default_adapter()
  end

  defp default_adapter do
    case PiEx.Tracing.LangSmith.enabled?() do
      true -> PiEx.Tracing.LangSmith
      false -> Noop
    end
  end
end

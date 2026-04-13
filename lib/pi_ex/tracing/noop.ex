defmodule PiEx.Tracing.Noop do
  @moduledoc false
  @behaviour PiEx.Tracing.Adapter

  @impl true
  def start_span(_parent_handle, _attrs), do: {:ok, :noop}

  @impl true
  def finish_span(_handle, _outputs, _opts), do: :ok

  @impl true
  def fail_span(_handle, _error, _outputs, _opts), do: :ok
end

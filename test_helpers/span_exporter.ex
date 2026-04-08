defmodule PiEx.TestSpanExporter do
  @moduledoc false
  use GenServer

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  def spans do
    GenServer.call(__MODULE__, :spans)
  end

  @impl true
  def init(_opts) do
    {:ok, []}
  end

  @impl true
  def handle_call(:clear, _from, _state) do
    {:reply, :ok, []}
  end

  @impl true
  def handle_call(:spans, _from, state) do
    {:reply, Enum.reverse(state), state}
  end

  @impl true
  def handle_info({:span, span}, state) do
    {:noreply, [span | state]}
  end
end

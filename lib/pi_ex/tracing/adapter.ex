defmodule PiEx.Tracing.Adapter do
  @moduledoc false

  @callback start_span(parent_handle :: term() | nil, attrs :: map()) ::
              {:ok, handle :: term()} | {:error, term()}

  @callback finish_span(handle :: term(), outputs :: map(), opts :: keyword()) ::
              :ok | {:error, term()}

  @callback fail_span(handle :: term(), error :: term(), outputs :: map(), opts :: keyword()) ::
              :ok | {:error, term()}
end

defmodule PiEx.Tracing.Context do
  @moduledoc false

  alias PiEx.Tracing.Span

  @enforce_keys [:adapter]
  defstruct [:adapter, :parent_span]

  @type t :: %__MODULE__{
          adapter: module(),
          parent_span: Span.t() | nil
        }
end

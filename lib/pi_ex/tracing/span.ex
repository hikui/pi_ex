defmodule PiEx.Tracing.Span do
  @moduledoc false

  @enforce_keys [:adapter, :name, :type]
  defstruct [:adapter, :handle, :name, :type]

  @type t :: %__MODULE__{
          adapter: module(),
          handle: term() | nil,
          name: String.t(),
          type: atom()
        }
end

defmodule PiEx.Tracing.Payload do
  @moduledoc false

  def normalize(value) when is_nil(value), do: nil
  def normalize(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value

  def normalize(value) when is_atom(value), do: Atom.to_string(value)

  def normalize(%_{} = value) do
    value
    |> Map.from_struct()
    |> normalize()
  end

  def normalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {normalize_key(key), normalize(item)} end)
    |> Enum.into(%{})
  end

  def normalize(value) when is_list(value) do
    Enum.map(value, &normalize/1)
  end

  def normalize({left, right}) do
    [normalize(left), normalize(right)]
  end

  def normalize(value), do: inspect(value)

  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key), do: inspect(key)
end

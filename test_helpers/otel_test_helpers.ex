defmodule PiEx.OtelTestHelpers do
  @moduledoc false

  require Record

  Record.defrecord(
    :otel_span,
    Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  Record.defrecord(
    :otel_instrumentation_scope,
    Record.extract(:instrumentation_scope, from_lib: "opentelemetry_api/include/opentelemetry.hrl")
  )

  def span_name(span), do: otel_span(span, :name)
  def span_id(span), do: otel_span(span, :span_id)
  def span_kind(span), do: otel_span(span, :kind)

  def span_attributes(span) do
    span
    |> otel_span(:attributes)
    |> :otel_attributes.map()
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
  end

  def parent_span_id(span), do: otel_span(span, :parent_span_id)

  def instrumentation_scope_name(span) do
    span
    |> otel_span(:instrumentation_scope)
    |> otel_instrumentation_scope(:name)
    |> to_string()
  end
end

import Config

config :opentelemetry,
  span_processor: :simple,
  traces_exporter: {:otel_exporter_pid, PiEx.TestSpanExporter}

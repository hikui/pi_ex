import Config

config :opentelemetry,
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :http_protobuf,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") || "http://localhost:4318"

config :pi_ex, :observability,
  enabled: true,
  capture_sensitive_data: false,
  agent_name: "example-observability-demo"

if config_env() == :dev do
  import_config "dev.exs"
end

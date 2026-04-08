defmodule Example.MixProject do
  use Mix.Project

  def project do
    [
      app: :example,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :opentelemetry_exporter, :opentelemetry]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:pi_ex, path: "../"},
      {:opentelemetry, "~> 1.7"},
      {:opentelemetry_exporter, "~> 1.10"}
    ]
  end
end

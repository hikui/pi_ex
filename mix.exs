defmodule PiEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :pi_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {PiEx.Application, []}
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:opentelemetry_api, "~> 1.5"},
      {:opentelemetry, "~> 1.7", only: :test},
      {:plug, "~> 1.0", only: :test}
    ]
  end
end

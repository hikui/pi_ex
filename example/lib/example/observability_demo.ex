defmodule Example.ObservabilityDemo do
  @moduledoc """
  Demonstrates `pi_ex` OpenTelemetry tracing from a host application.

  The example project owns SDK and exporter configuration. `pi_ex` only emits
  spans using the OpenTelemetry API with instrumentation scope `pi_ex`.

  ## Running

      cd example
      export OPENAI_API_KEY=sk-...
      export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318
      mix run -e "Example.ObservabilityDemo.run()"
  """

  alias PiEx.Agent
  alias PiEx.AI.Model
  alias PiEx.AI.ProviderParams
  alias PiEx.Observability.Settings

  @model Model.new("gpt-5.4", "openai_responses",
           provider_params: %ProviderParams.OpenAIResponses{
             http_receive_timeout: 300_000,
             reasoning_effort: "low",
             reasoning_summary: "auto"
           }
         )

  @doc """
  Run a short agent interaction and return the final transcript.

  Options:
  - `:config` — override the default `%PiEx.Agent.Config{}`
  - `:prompt` — override the default prompt
  - `:timeout` — receive timeout while waiting for completion
  """
  @spec run(keyword()) :: [PiEx.AI.Message.t()]
  def run(opts \\ []) do
    config = Keyword.get(opts, :config, build_config())
    prompt = Keyword.get(opts, :prompt, "Tell me a two-sentence fun fact about Melbourne.")
    timeout = Keyword.get(opts, :timeout, 180_000)

    IO.puts("Exporting traces to #{otlp_endpoint()}")
    IO.puts("Look for instrumentation scope `pi_ex` in your collector/backend.")

    {:ok, agent} = Agent.start(config)

    try do
      Agent.subscribe(agent)
      :ok = Agent.prompt(agent, prompt)
      :ok = collect_events(timeout)
      Agent.get_messages(agent)
    after
      Agent.stop(agent)
    end
  end

  defp build_config do
    %PiEx.Agent.Config{
      model: @model,
      system_prompt: """
      You are a concise assistant in an OpenTelemetry demo.

      Keep the reply short and friendly.
      """,
      observability: %Settings{
        enabled: true,
        conversation_id: "example-observability-demo",
        agent_name: "example-observability-demo",
        agent_description: "Example host app demo for pi_ex OpenTelemetry spans"
      }
    }
  end

  defp collect_events(timeout) do
    receive do
      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_events(timeout)

      {:agent_event, {:agent_end, _messages}} ->
        IO.puts("")
        :ok

      {:agent_event, {:agent_error, reason}} ->
        raise "agent failed: #{inspect(reason)}"

      {:agent_event, _event} ->
        collect_events(timeout)
    after
      timeout ->
        raise "agent did not finish within #{timeout}ms"
    end
  end

  defp otlp_endpoint do
    System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") || "http://localhost:4318"
  end
end

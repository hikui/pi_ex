defmodule Example.MultiRoundDemo do
  @moduledoc """
  Demonstrates a multi-round conversation using `PiEx.Agent`.

  Unlike the single-prompt demos, this example keeps one agent process alive and
  calls `PiEx.Agent.prompt/2` multiple times. Each new prompt is appended to the
  existing transcript, so the model can refer back to earlier turns naturally.

  ## Running

      cd example
      mix run -e "Example.MultiRoundDemo.run()"

  Requires the OpenAI API key in the environment or config:

      export OPENAI_API_KEY=sk-...
  """

  alias PiEx.Agent
  alias PiEx.AI.Model
  alias PiEx.AI.ProviderParams

  @default_timeout 180_000

  @model Model.new("gpt-5.4", "openai_responses",
           provider_params: %ProviderParams.OpenAIResponses{
             http_receive_timeout: 300_000,
             reasoning_effort: "low",
             reasoning_summary: "auto"
           }
         )

  @doc """
  Run the multi-round demo and return the final transcript.

  ## Options

  - `:config` — override the default `%PiEx.Agent.Config{}`. Useful for tests.
  - `:prompts` — override the default list of user prompts.
  - `:timeout` — per-turn receive timeout in milliseconds.
  """
  @spec run(keyword()) :: [PiEx.AI.Message.t()]
  def run(opts \\ []) do
    config = Keyword.get(opts, :config, build_config())
    prompts = Keyword.get(opts, :prompts, conversation_prompts())
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    {:ok, agent} = Agent.start(config)

    try do
      Agent.subscribe(agent)

      Enum.each(prompts, fn prompt ->
        IO.puts("\n[User] #{prompt}")
        IO.write("[Assistant] ")
        :ok = Agent.prompt(agent, prompt)
        :ok = collect_turn_events(timeout)
      end)

      messages = Agent.get_messages(agent)
      print_summary(messages)
      messages
    after
      Agent.stop(agent)
    end
  end

  @doc "The prompts used in the default multi-round conversation."
  @spec conversation_prompts() :: [String.t()]
  def conversation_prompts do
    [
      "My name is Sam. Please remember it and greet me briefly.",
      "I am planning a two-day trip to Kyoto. Give me three concise ideas.",
      "Now combine my name and the Kyoto ideas into a short, friendly recap."
    ]
  end

  defp build_config do
    %PiEx.Agent.Config{
      model: @model,
      system_prompt: """
      You are a helpful assistant in a multi-round demo.

      Keep replies short, friendly, and grounded in the conversation so far.
      When the user refers to earlier turns, rely on the transcript context.
      """
    }
  end

  defp collect_turn_events(timeout) do
    receive do
      {:agent_event, :agent_start} ->
        collect_turn_events(timeout)

      {:agent_event, :turn_start} ->
        collect_turn_events(timeout)

      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.write(delta)
        collect_turn_events(timeout)

      {:agent_event, {:agent_end, _messages}} ->
        IO.puts("")
        :ok

      {:agent_event, {:agent_error, reason}} ->
        raise "agent failed: #{inspect(reason)}"

      {:agent_event, _other} ->
        collect_turn_events(timeout)
    after
      timeout ->
        raise "agent did not finish within #{timeout}ms"
    end
  end

  defp print_summary(messages) do
    user_turns =
      Enum.count(messages, fn
        %PiEx.AI.Message.UserMessage{} -> true
        _other -> false
      end)

    IO.puts("\n[Conversation complete: #{user_turns} user turns, #{length(messages)} messages]")
  end
end

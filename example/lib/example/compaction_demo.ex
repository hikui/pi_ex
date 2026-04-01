defmodule Example.CompactionDemo do
  @moduledoc """
  Demonstrates auto context compaction in PiEx.

  The demo runs an agent with an artificially small `context_window` (200 tokens)
  so compaction triggers after just a few messages. A real LLM API call is used
  for both agent turns and the compaction summarization step.

  ## Run

      OPENAI_API_KEY=sk-... mix run -e "Example.CompactionDemo.run()"

  You'll see:
    - Streaming assistant text from each turn
    - `:compaction_start` firing after the context fills up
    - `:compaction_end` with the summary message inserted at the front
    - The agent continuing normally after compaction
  """

  alias PiEx.Agent
  alias PiEx.Agent.Compaction.Settings
  alias PiEx.AI.Model
  alias PiEx.AI.Message.CompactionSummaryMessage

  @context_window 200

  @doc "Run the compaction demo. Requires OPENAI_API_KEY to be set."
  def run do
    do_run()
  end

  defp do_run do
    IO.puts("""
    ┌─────────────────────────────────────────────┐
    │     PiEx Auto Context Compaction Demo        │
    │  context_window=#{@context_window} tokens (tiny, for demo)  │
    └─────────────────────────────────────────────┘
    """)

    config = %PiEx.Agent.Config{
      model: %Model{
        id: "gpt-4o-mini",
        provider: "openai",
        context_window: @context_window
      },
      system_prompt: "You are a helpful assistant. Keep responses under 3 sentences.",
      compaction: %Settings{
        enabled: true,
        reserve_tokens: 80,
        keep_recent_tokens: 50
      }
    }

    {:ok, agent} = Agent.start(config)
    Agent.subscribe(agent)

    # Run three prompt/response turns to fill the context
    turns = [
      "Tell me a brief fact about the planet Mars.",
      "Now tell me a brief fact about Jupiter.",
      "Finally, tell me a brief fact about Saturn."
    ]

    Enum.each(turns, fn prompt ->
      IO.puts("\n[User] #{prompt}")
      IO.write("[Assistant] ")
      :ok = Agent.prompt(agent, prompt)
      collect_turn_events()
    end)

    final_messages = Agent.get_messages(agent)

    compaction_msgs = Enum.filter(final_messages, &match?(%CompactionSummaryMessage{}, &1))

    IO.puts("""

    ──────────────────────────────────────────────
    Final transcript: #{length(final_messages)} messages
    Compaction summaries injected: #{length(compaction_msgs)}
    """)

    if compaction_msgs != [] do
      IO.puts("Summary preview:")
      IO.puts(String.slice(hd(compaction_msgs).summary, 0, 300) <> "…")
    end

    Agent.stop(agent)
    :ok
  end

  # Collect streaming events until agent_end, then check for any trailing compaction.
  defp collect_turn_events do
    receive do
      {:agent_event, {:message_update, _, {:text_delta, _, delta, _}}} ->
        IO.write(delta)
        collect_turn_events()

      {:agent_event, {:agent_end, _messages}} ->
        IO.puts("")
        # Compaction fires asynchronously after agent_end. Wait briefly to see if
        # it starts, then track it to completion before returning to the caller.
        collect_post_turn_events()

      {:agent_event, _} ->
        collect_turn_events()

    after
      60_000 -> IO.puts("\n[timeout]")
    end
  end

  # After agent_end: wait up to 500 ms for a compaction_start. If one arrives,
  # wait for it to complete. Otherwise return immediately.
  defp collect_post_turn_events do
    receive do
      {:agent_event, :compaction_start} ->
        IO.puts("[compaction] Summarizing old context…")
        collect_compaction_events()

      {:agent_event, _} ->
        collect_post_turn_events()

    after
      500 -> :ok
    end
  end

  defp collect_compaction_events do
    receive do
      {:agent_event, {:compaction_end, %CompactionSummaryMessage{tokens_before: before}}} ->
        IO.puts("[compaction] Done. Context was #{before} tokens before compaction.")

      {:agent_event, {:compaction_error, reason}} ->
        IO.puts("[compaction] Error: #{inspect(reason)}")

      {:agent_event, _} ->
        collect_compaction_events()

    after
      60_000 -> IO.puts("[compaction] Timed out waiting for completion.")
    end
  end
end

defmodule Example.ToolStreamEventsDemo do
  @moduledoc """
  Demonstrates tool-injected stream events with `opts[:on_update]`.

  This demo is fully local: it uses a deterministic `stream_fn` instead of a
  real LLM provider, so it does not require an API key or network access.

  ## Run

      mix run -e "Example.ToolStreamEventsDemo.run()"

  You'll see:
    - The fake model requesting a tool call
    - The tool emitting progress events through `opts[:on_update]`
    - The subscriber receiving those events as `:tool_execution_update`
    - The agent completing normally after the tool result is returned
  """

  alias PiEx.Agent
  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.Message.{AssistantMessage, Usage}
  alias PiEx.AI.Model

  @doc "Run the local tool stream events demo."
  @spec run() :: :ok
  def run do
    IO.puts("""
    Tool Stream Events Demo
    -----------------------
    """)

    turn_counter = :counters.new(1, [])

    config = %PiEx.Agent.Config{
      model: Model.new("local-demo-model", "openai"),
      system_prompt: "You are a deterministic local demo agent.",
      tools: [demo_tool()],
      stream_fn: fn _model, _context, _opts -> demo_stream(turn_counter) end
    }

    {:ok, agent} = Agent.start(config)
    Agent.subscribe(agent)

    :ok = Agent.prompt(agent, "Run the demo tool and report back.")
    collect_events()
    Agent.stop(agent)

    :ok
  end

  defp demo_tool do
    %PiEx.Agent.Tool{
      name: "long_running_demo",
      label: "Long Running Demo",
      description: "Emits progress events while doing a deterministic local task.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "topic" => %{
            "type" => "string",
            "description" => "Short label for the demo work."
          }
        },
        "required" => ["topic"]
      },
      execute: fn _call_id, %{"topic" => topic}, opts ->
        on_update = Keyword.fetch!(opts, :on_update)

        events = [
          %{type: :progress, step: 1, message: "Preparing #{topic}"},
          %{type: :progress, step: 2, message: "Doing local work"},
          %{type: :progress, step: 3, message: "Packaging result"}
        ]

        Enum.each(events, fn event ->
          on_update.(event)
          Process.sleep(50)
        end)

        {:ok,
         %{
           content: [%TextContent{text: "Completed demo workflow for #{topic}."}],
           details: %{events_emitted: length(events)}
         }}
      end
    }
  end

  defp demo_stream(turn_counter) do
    :counters.add(turn_counter, 1, 1)

    case :counters.get(turn_counter, 1) do
      1 ->
        tool_call_stream("call_demo_1", "long_running_demo", %{
          "topic" => "subscriber events"
        })

      _ ->
        text_stream("The demo tool finished and its injected events reached the subscriber.")
    end
  end

  defp tool_call_stream(call_id, tool_name, args) do
    tool_call = %ToolCall{id: call_id, name: tool_name, arguments: args}

    partial_empty = %AssistantMessage{
      content: [],
      model: "local-demo-model",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 0
    }

    partial_done = %AssistantMessage{
      content: [tool_call],
      model: "local-demo-model",
      usage: %Usage{},
      stop_reason: :tool_use,
      timestamp: 0
    }

    [
      {:start, partial_empty},
      {:toolcall_start, 0, partial_empty},
      {:toolcall_end, 0, tool_call, partial_done},
      {:done, :tool_use, partial_done}
    ]
  end

  defp text_stream(text) do
    partial_empty = %AssistantMessage{
      content: [],
      model: "local-demo-model",
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: 0
    }

    partial_done = %AssistantMessage{
      content: [%TextContent{text: text}],
      model: "local-demo-model",
      usage: %Usage{input_tokens: 5, output_tokens: 8},
      stop_reason: :stop,
      timestamp: 0
    }

    [
      {:start, partial_empty},
      {:text_start, 0, partial_empty},
      {:text_delta, 0, text, partial_done},
      {:text_end, 0, text, partial_done},
      {:done, :stop, partial_done}
    ]
  end

  defp collect_events do
    receive do
      {:agent_event, {:tool_execution_start, _id, name, args}} ->
        IO.puts("[tool start] #{name} #{inspect(args)}")
        collect_events()

      {:agent_event, {:tool_execution_update, _id, name, _args, event}} ->
        IO.puts("[tool event] #{name} #{inspect(event)}")
        collect_events()

      {:agent_event, {:tool_execution_end, _id, name, _result, false}} ->
        IO.puts("[tool done] #{name}")
        collect_events()

      {:agent_event, {:message_update, _msg, {:text_delta, _idx, delta, _partial}}} ->
        IO.puts("[assistant] #{delta}")
        collect_events()

      {:agent_event, {:agent_end, messages}} ->
        IO.puts("[agent done] #{length(messages)} messages")

      {:agent_event, _event} ->
        collect_events()
    after
      5_000 ->
        IO.puts("[timeout]")
    end
  end
end

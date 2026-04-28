defmodule PiEx.Agent do
  @moduledoc """
  Public API for creating and interacting with PI agents.

  ## Quick start

      config = %PiEx.Agent.Config{
        model: PiEx.AI.Model.new("gpt-4o", "openai"),
        system_prompt: "You are a helpful assistant.",
        tools: []
      }

      {:ok, agent} = PiEx.Agent.start(config)
      PiEx.Agent.subscribe(agent)
      :ok = PiEx.Agent.prompt(agent, "What is 2 + 2?")

      # In the caller's receive loop:
      receive do
        {:agent_event, {:agent_end, _messages}} -> IO.puts("done")
        {:agent_event, {:message_update, _msg, {:text_delta, _, delta, _}}} -> IO.write(delta)
      end

  ## With tools

      weather_tool = %PiEx.Agent.Tool{
        name: "get_weather",
        description: "Get current weather for a city",
        parameters: %{
          "type" => "object",
          "properties" => %{"city" => %{"type" => "string"}},
          "required" => ["city"]
        },
        label: "Get Weather",
        execute: fn _id, %{"city" => city}, opts ->
          opts[:on_update].(%{type: :progress, message: "fetching weather"})
          {:ok, %{content: [%PiEx.AI.Content.TextContent{text: "Sunny in \#{city}"}], details: nil}}
        end
      }

      config = %PiEx.Agent.Config{model: model, tools: [weather_tool]}
  """

  alias PiEx.Agent.{Config, Server, Supervisor}

  @doc "Start a supervised agent with the given config. Returns `{:ok, pid}`."
  @spec start(Config.t()) :: {:ok, pid()} | {:error, term()}
  defdelegate start(config), to: Supervisor, as: :start_agent

  @doc "Subscribe `pid` (default: `self()`) to receive `{:agent_event, event}` messages."
  @spec subscribe(pid(), pid()) :: :ok
  defdelegate subscribe(server, pid \\ self()), to: Server

  @doc "Start a new run. Returns `{:error, :already_running}` if agent is busy."
  @spec prompt(pid(), String.t() | [PiEx.AI.Message.t()]) :: :ok | {:error, :already_running}
  defdelegate prompt(server, input), to: Server

  @doc "Inject messages to steer the current run (queued for next turn)."
  @spec steer(pid(), PiEx.AI.Message.t() | [PiEx.AI.Message.t()]) :: :ok
  defdelegate steer(server, messages), to: Server

  @doc "Add follow-up messages to restart the agent after it stops."
  @spec follow_up(pid(), PiEx.AI.Message.t() | [PiEx.AI.Message.t()]) :: :ok
  defdelegate follow_up(server, messages), to: Server

  @doc "Abort the currently running loop."
  @spec abort(pid()) :: :ok
  defdelegate abort(server), to: Server

  @doc "Return the full message transcript."
  @spec get_messages(pid()) :: [PiEx.AI.Message.t()]
  defdelegate get_messages(server), to: Server

  @doc "Return current status: `:idle` or `:running`."
  @spec status(pid()) :: :idle | :running
  defdelegate status(server), to: Server

  @doc "Manually trigger compaction on the current message history. No-op if compaction is not configured."
  @spec compact(pid()) :: :ok | {:error, :already_running}
  defdelegate compact(server), to: Server

  @doc "Stop the agent process."
  @spec stop(pid()) :: :ok | {:error, :not_found}
  defdelegate stop(server), to: Supervisor, as: :stop_agent
end

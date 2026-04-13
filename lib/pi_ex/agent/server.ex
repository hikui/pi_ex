defmodule PiEx.Agent.Server do
  @moduledoc """
  Stateful GenServer that orchestrates an agent run.

  Lifecycle:
  1. Started via `PiEx.Agent.Supervisor.start_agent/1`.
  2. Callers subscribe via `subscribe/2` to receive agent events.
  3. `prompt/2` starts a run. Returns `{:error, :already_running}` if busy.
  4. `steer/2` injects messages mid-run (queued, polled each turn).
  5. `follow_up/2` injects messages when the agent would otherwise stop.
  6. `abort/1` signals cancellation to the running task.
  7. Events arrive as `{:agent_event, event}` in the subscriber's mailbox.

  ## State
  - `:status` — `:idle | :running`
  - `:messages` — full conversation transcript
  - `:subscribers` — list of PIDs to notify
  - `:loop_task` — the running `Task` struct (if any)
  - `:steering_queue` — messages to inject on the next turn
  - `:follow_up_queue` — messages to inject after the agent stops
  """

  use GenServer

  alias PiEx.Agent.{Config, Compaction, Loop}
  alias PiEx.AI.ProviderParams
  alias PiEx.Tracing

  defstruct [
    :config,
    :base_trace_context,
    :root_trace_span,
    :compaction_trace_span,
    status: :idle,
    messages: [],
    subscribers: [],
    loop_task: nil,
    steering_queue: [],
    follow_up_queue: [],
    compaction_task: nil
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start_link(%Config{} = config) do
    GenServer.start_link(__MODULE__, config)
  end

  @doc "Subscribe `pid` to receive `{:agent_event, event}` messages. Default: `self()`."
  @spec subscribe(pid(), pid()) :: :ok
  def subscribe(server, pid \\ self()) do
    GenServer.call(server, {:subscribe, pid})
  end

  @doc "Start a new run with the given prompt text or messages. Returns `{:error, :already_running}` if busy."
  @spec prompt(pid(), String.t() | [PiEx.AI.Message.t()]) :: :ok | {:error, :already_running}
  def prompt(server, text) when is_binary(text) do
    msg = PiEx.AI.Message.user(text)
    GenServer.call(server, {:prompt, [msg]})
  end

  def prompt(server, messages) when is_list(messages) do
    GenServer.call(server, {:prompt, messages})
  end

  @doc "Inject messages to steer the agent mid-run (queued for next turn)."
  @spec steer(pid(), PiEx.AI.Message.t() | [PiEx.AI.Message.t()]) :: :ok
  def steer(server, msg) when is_struct(msg) do
    GenServer.cast(server, {:steer, [msg]})
  end

  def steer(server, messages) when is_list(messages) do
    GenServer.cast(server, {:steer, messages})
  end

  @doc "Inject follow-up messages to restart the agent after it stops."
  @spec follow_up(pid(), PiEx.AI.Message.t() | [PiEx.AI.Message.t()]) :: :ok
  def follow_up(server, msg) when is_struct(msg) do
    GenServer.cast(server, {:follow_up, [msg]})
  end

  def follow_up(server, messages) when is_list(messages) do
    GenServer.cast(server, {:follow_up, messages})
  end

  @doc "Abort the currently running loop (no-op if idle)."
  @spec abort(pid()) :: :ok
  def abort(server) do
    GenServer.cast(server, :abort)
  end

  @doc "Return the current message transcript."
  @spec get_messages(pid()) :: [PiEx.AI.Message.t()]
  def get_messages(server) do
    GenServer.call(server, :get_messages)
  end

  @doc "Return current status: `:idle` or `:running`."
  @spec status(pid()) :: :idle | :running
  def status(server) do
    GenServer.call(server, :status)
  end

  @doc "Manually trigger compaction regardless of token count. No-op if already compacting or running."
  @spec compact(pid()) :: :ok | {:error, :already_running}
  def compact(server) do
    GenServer.call(server, :compact)
  end

  # ---------------------------------------------------------------------------
  # Callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%Config{} = config) do
    server_pid = self()

    state = %__MODULE__{
      config:
        config
        |> inject_queue_hooks(server_pid)
        |> inject_run_agent_tool(server_pid)
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: [pid | state.subscribers]}}
  end

  @impl true
  def handle_call({:prompt, _messages}, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call({:prompt, _messages}, _from, %{compaction_task: {_, _}} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call({:prompt, messages}, _from, state) do
    all_messages = state.messages ++ messages
    server_pid = self()
    base_trace_context = state.config.trace_context || Tracing.new_context()

    root_trace_span =
      Tracing.start_span(base_trace_context,
        name: root_trace_name(state.config),
        type: :chain,
        inputs: %{messages: all_messages},
        metadata: %{
          depth: state.config.depth,
          agent_type: agent_type(state.config)
        }
      )

    run_config =
      state.config
      |> Map.put(:trace_context, Tracing.child_context(base_trace_context, root_trace_span))
      |> inject_run_agent_tool(server_pid)

    task =
      Task.Supervisor.async_nolink(PiEx.TaskSupervisor, fn ->
        Loop.run(all_messages, run_config, server_pid)
      end)

    # Monitor the task so we catch crashes
    Process.monitor(task.pid)

    {:reply, :ok,
     %{
       state
       | status: :running,
         loop_task: task,
         messages: all_messages,
         config: run_config,
         base_trace_context: base_trace_context,
         root_trace_span: root_trace_span
     }}
  end

  @impl true
  def handle_call(:get_messages, _from, state) do
    {:reply, state.messages, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:compact, _from, %{status: :running} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:compact, _from, %{compaction_task: {_, _}} = state) do
    {:reply, {:error, :already_running}, state}
  end

  @impl true
  def handle_call(:compact, _from, state) do
    new_state = force_start_compaction(state)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:get_steering_messages, _from, state) do
    msgs = state.steering_queue
    {:reply, msgs, %{state | steering_queue: []}}
  end

  @impl true
  def handle_call(:get_follow_up_messages, _from, state) do
    msgs = state.follow_up_queue
    {:reply, msgs, %{state | follow_up_queue: []}}
  end

  @impl true
  def handle_cast({:steer, messages}, state) do
    {:noreply, %{state | steering_queue: state.steering_queue ++ messages}}
  end

  @impl true
  def handle_cast({:follow_up, messages}, state) do
    {:noreply, %{state | follow_up_queue: state.follow_up_queue ++ messages}}
  end

  @impl true
  def handle_cast(:abort, %{loop_task: nil} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast(:abort, %{loop_task: task} = state) do
    Task.shutdown(task, :brutal_kill)
    state = fail_root_trace(state, "aborted", %{messages: state.messages})
    {:noreply, %{state | status: :idle, loop_task: nil}}
  end

  @impl true
  def handle_info({:agent_event, event}, state) do
    state = apply_event(event, state)
    broadcast(state.subscribers, {:agent_event, event})

    state =
      if match?({:agent_end, _}, event) do
        state
        |> maybe_start_compaction()
        |> maybe_finish_root_trace(event)
      else
        state
      end

    {:noreply, state}
  end

  # Compaction completed successfully
  @impl true
  def handle_info({:compaction_done, new_messages}, state) do
    broadcast(state.subscribers, {:agent_event, {:compaction_end, hd(new_messages)}})
    Tracing.finish_span(state.compaction_trace_span, %{messages: new_messages})
    state = finish_root_trace(state, %{messages: new_messages, compacted: true})

    {:noreply,
     %{state | messages: new_messages, compaction_task: nil, compaction_trace_span: nil}}
  end

  # Compaction failed
  @impl true
  def handle_info({:compaction_error, reason}, state) do
    broadcast(state.subscribers, {:agent_event, {:compaction_error, reason}})
    Tracing.fail_span(state.compaction_trace_span, reason, %{messages: state.messages})
    state = finish_root_trace(state, %{messages: state.messages, compaction_error: reason})
    {:noreply, %{state | compaction_task: nil, compaction_trace_span: nil}}
  end

  # Loop task completed normally (async_nolink sends a message with the result)
  @impl true
  def handle_info({ref, _result}, %{loop_task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, %{state | status: :idle, loop_task: nil}}
  end

  # Compaction task exited (start_child monitors send :DOWN on exit, both normal and crash)
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{compaction_task: {task_pid, _}} = state)
      when task_pid == pid do
    if reason != :normal do
      broadcast(state.subscribers, {:agent_event, {:compaction_error, reason}})
      Tracing.fail_span(state.compaction_trace_span, reason, %{messages: state.messages})
      state = finish_root_trace(state, %{messages: state.messages, compaction_error: reason})
      {:noreply, %{state | compaction_task: nil, compaction_trace_span: nil}}
    else
      {:noreply, %{state | compaction_task: nil}}
    end
  end

  # Loop task crashed
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{loop_task: task} = state)
      when task != nil and task.pid == pid do
    if reason != :normal do
      broadcast(state.subscribers, {:agent_event, {:agent_error, reason}})
      state = fail_root_trace(state, reason, %{messages: state.messages})
      {:noreply, %{state | status: :idle, loop_task: nil}}
    else
      {:noreply, %{state | status: :idle, loop_task: nil}}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    {:noreply, state}
  end

  # ---------------------------------------------------------------------------
  # State reduction
  # ---------------------------------------------------------------------------

  defp apply_event({:agent_end, messages}, state) do
    %{state | messages: messages, status: :idle}
  end

  defp apply_event(_event, state), do: state

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp broadcast(subscribers, message) do
    Enum.each(subscribers, &send(&1, message))
  end

  defp maybe_start_compaction(%{config: %{compaction: nil}} = state), do: state
  defp maybe_start_compaction(%{config: %{model: %{context_window: nil}}} = state), do: state

  defp maybe_start_compaction(state) do
    %{messages: messages, config: config} = state
    estimate = Compaction.estimate_context_tokens(messages)

    if Compaction.should_compact?(estimate.tokens, config.model.context_window, config.compaction) do
      start_compaction_task(state)
    else
      state
    end
  end

  defp force_start_compaction(%{config: %{compaction: nil}} = state), do: state
  defp force_start_compaction(state), do: start_compaction_task(state)

  defp start_compaction_task(state) do
    %{messages: messages, config: config} = state
    server_pid = self()
    compact_fn = config.compact_fn || (&Compaction.compact(&1, &2, &3, &4))

    compaction_trace_span =
      Tracing.start_span(config.trace_context,
        name: "pi_ex.compaction",
        type: :llm,
        inputs: %{messages: messages, settings: config.compaction},
        metadata: %{depth: config.depth}
      )

    {:ok, task_pid} =
      Task.Supervisor.start_child(PiEx.TaskSupervisor, fn ->
        case compact_fn.(
               messages,
               config.model,
               config.compaction,
               ProviderParams.api_key(config.model)
             ) do
          {:ok, new_messages} -> send(server_pid, {:compaction_done, new_messages})
          {:error, reason} -> send(server_pid, {:compaction_error, reason})
        end
      end)

    monitor_ref = Process.monitor(task_pid)
    broadcast(state.subscribers, {:agent_event, :compaction_start})

    %{
      state
      | compaction_task: {task_pid, monitor_ref},
        compaction_trace_span: compaction_trace_span
    }
  end

  # Inject queue-polling hooks so the loop can call back into this GenServer
  defp inject_queue_hooks(%Config{} = config, server_pid) do
    %{
      config
      | get_steering_messages: fn -> safe_queue_call(server_pid, :get_steering_messages) end,
        get_follow_up_messages: fn -> safe_queue_call(server_pid, :get_follow_up_messages) end
    }
  end

  # Inject the run_agent tool when depth allows nesting.
  # Any pre-existing "run_agent" entry is replaced so each server gets a fresh
  # closure bound to its own config and pid.
  defp inject_run_agent_tool(%Config{max_depth: max_depth, depth: depth} = config, server_pid) do
    if max_depth == nil or depth < max_depth do
      tool = PiEx.Agent.Tools.RunAgent.tool(config, server_pid)
      tools = Enum.reject(config.tools, &(&1.name == "run_agent"))
      %{config | tools: tools ++ [tool]}
    else
      config
    end
  end

  defp maybe_finish_root_trace(state, {:agent_end, messages}) do
    case state.compaction_task do
      nil -> finish_root_trace(state, %{messages: messages})
      {_pid, _ref} -> state
    end
  end

  defp maybe_finish_root_trace(state, _event), do: state

  defp finish_root_trace(%{root_trace_span: nil} = state, _outputs),
    do: reset_trace_context(state)

  defp finish_root_trace(state, outputs) do
    Tracing.finish_span(state.root_trace_span, outputs)

    state
    |> Map.put(:root_trace_span, nil)
    |> reset_trace_context()
  end

  defp fail_root_trace(%{root_trace_span: nil} = state, _reason, _outputs),
    do: reset_trace_context(state)

  defp fail_root_trace(state, reason, outputs) do
    Tracing.fail_span(state.root_trace_span, reason, outputs)

    state
    |> Map.put(:root_trace_span, nil)
    |> reset_trace_context()
  end

  defp reset_trace_context(%{base_trace_context: base_trace_context} = state) do
    base_trace_context = base_trace_context || state.config.trace_context
    config = %{state.config | trace_context: base_trace_context} |> inject_run_agent_tool(self())
    %{state | config: config, base_trace_context: base_trace_context}
  end

  defp root_trace_name(%Config{depth: 0}), do: "pi_ex.agent"
  defp root_trace_name(%Config{}), do: "pi_ex.subagent"

  defp agent_type(%Config{depth: 0}), do: "root"
  defp agent_type(%Config{}), do: "subagent"

  defp safe_queue_call(server_pid, message) do
    GenServer.call(server_pid, message)
  catch
    :exit, _reason -> []
  end
end

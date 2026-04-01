defmodule PiEx.AI do
  @moduledoc """
  Public API for streaming LLM completions.

  ## Usage

      model = PiEx.AI.Model.new("gpt-4o", "openai")
      context = %PiEx.AI.Context{messages: [PiEx.AI.Message.user("Hello!")]}

      for event <- PiEx.AI.stream(model, context) do
        case event do
          {:text_delta, _idx, delta, _partial} -> IO.write(delta)
          {:done, _reason, _msg} -> IO.puts("")
          _ -> :ok
        end
      end

      # Or get the final message synchronously:
      {:ok, message} = PiEx.AI.complete(model, context)
  """

  alias PiEx.AI.{Model, Context, ProviderParams}
  alias PiEx.AI.Message.AssistantMessage
  alias PiEx.AI.Message.Usage

  @providers %{
    "openai" => PiEx.AI.Providers.OpenAI,
    "openai_responses" => PiEx.AI.Providers.OpenAIResponses,
    "litellm" => PiEx.AI.Providers.LiteLLM
  }

  @doc """
  Returns a lazy stream of `PiEx.AI.StreamEvent.t()` events.

  The stream never raises. All failures are encoded as `{:error, reason, message}` events.
  """
  @spec stream(Model.t(), Context.t(), keyword()) :: Enumerable.t()
  def stream(%Model{provider: provider} = model, %Context{} = context, opts \\ []) do
    with {:ok, model_opts} <- ProviderParams.to_opts(model),
         {:ok, module} <- fetch_provider(provider) do
      module.stream(model, context, Keyword.merge(model_opts, opts))
    else
      {:error, reason} ->
        error_msg = empty_error_message(reason)
        [{:error, :error, error_msg}]
    end
  end

  @doc """
  Runs the stream to completion and returns `{:ok, AssistantMessage}` or `{:error, message}`.
  """
  @spec complete(Model.t(), Context.t(), keyword()) ::
          {:ok, AssistantMessage.t()} | {:error, AssistantMessage.t()}
  def complete(%Model{} = model, %Context{} = context, opts \\ []) do
    model
    |> stream(context, opts)
    |> Enum.reduce_while(nil, fn
      {:done, _reason, message}, _acc -> {:halt, {:ok, message}}
      {:error, _reason, message}, _acc -> {:halt, {:error, message}}
      _event, _acc -> {:cont, nil}
    end)
    |> case do
      nil -> {:error, empty_error_message("Stream ended without a terminal event")}
      result -> result
    end
  end

  defp empty_error_message(msg) do
    %AssistantMessage{
      content: [],
      model: "",
      usage: %Usage{},
      stop_reason: :error,
      timestamp: System.system_time(:millisecond),
      error_message: msg
    }
  end

  defp fetch_provider(provider) do
    case Map.fetch(@providers, provider) do
      {:ok, module} -> {:ok, module}
      :error -> {:error, "Unknown provider: #{provider}"}
    end
  end
end

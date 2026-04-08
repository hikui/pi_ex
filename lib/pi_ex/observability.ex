defmodule PiEx.Observability do
  @moduledoc """
  Helpers for OpenTelemetry instrumentation used by `pi_ex`.

  The library emits spans through the OpenTelemetry API only. Exporter and SDK
  configuration remain the responsibility of the host application.
  """

  alias PiEx.AI.Content.{ImageContent, TextContent, ThinkingContent, ToolCall}
  alias PiEx.AI.Context

  alias PiEx.AI.Message.{
    AssistantMessage,
    CompactionSummaryMessage,
    ToolResultMessage,
    Usage,
    UserMessage
  }

  alias PiEx.AI.Model
  alias PiEx.Agent.Config
  alias PiEx.Agent.Tool
  alias PiEx.Observability.Settings

  @scope :pi_ex
  @default_error_type "_OTHER"

  @spec resolve_settings(Settings.t() | map() | keyword() | nil) :: Settings.t()
  def resolve_settings(overrides \\ nil) do
    merged =
      Application.get_env(:pi_ex, :observability, [])
      |> normalize_settings_map()
      |> Map.merge(normalize_settings_map(overrides))

    struct(Settings, merged)
  end

  @spec enabled?(Settings.t() | map() | keyword() | nil) :: boolean()
  def enabled?(settings) do
    settings
    |> resolve_settings()
    |> Map.fetch!(:enabled)
  end

  @spec current_ctx() :: term()
  def current_ctx do
    :otel_ctx.get_current()
  end

  @spec attach_ctx(term() | nil) :: reference() | nil
  def attach_ctx(nil), do: nil

  def attach_ctx(ctx) do
    :otel_ctx.attach(ctx)
  end

  @spec detach_ctx(reference() | nil) :: :ok
  def detach_ctx(nil), do: :ok

  def detach_ctx(token) do
    :otel_ctx.detach(token)
  end

  @spec with_span(String.t(), keyword(), Settings.t() | map() | keyword() | nil, (term() | nil ->
                                                                                    result)) ::
          result
        when result: var
  def with_span(name, opts, settings_overrides, fun) when is_function(fun, 1) do
    settings = resolve_settings(settings_overrides)

    if settings.enabled do
      do_with_span(name, opts, settings, fun)
    else
      fun.(nil)
    end
  end

  @spec set_attributes(term() | nil, map()) :: :ok
  def set_attributes(nil, _attributes), do: :ok

  def set_attributes(span_ctx, attributes) do
    attributes
    |> clean_attributes()
    |> case do
      %{} = attrs when map_size(attrs) == 0 ->
        :ok

      attrs ->
        :otel_span.set_attributes(span_ctx, attrs)
        :ok
    end
  end

  @spec set_error(term() | nil, term()) :: :ok
  def set_error(nil, _reason), do: :ok

  def set_error(span_ctx, reason) do
    :otel_span.set_status(span_ctx, :error)
    set_attributes(span_ctx, %{"error.type" => error_type(reason)})
  end

  @spec safe_provider(String.t()) :: String.t()
  def safe_provider("openai_responses"), do: "openai"
  def safe_provider(provider) when is_binary(provider), do: provider
  def safe_provider(_provider), do: "custom"

  @spec system_instruction_attributes(String.t() | nil, Settings.t()) :: map()
  def system_instruction_attributes(nil, _settings), do: %{}

  def system_instruction_attributes(system_prompt, %Settings{capture_sensitive_data: true})
      when is_binary(system_prompt) do
    %{"gen_ai.system_instructions" => encode_json!([text_part(system_prompt)])}
  end

  def system_instruction_attributes(_system_prompt, _settings), do: %{}

  @spec agent_span_name(Settings.t()) :: String.t()
  def agent_span_name(%Settings{agent_name: nil}), do: "invoke_agent"
  def agent_span_name(%Settings{agent_name: name}), do: "invoke_agent #{name}"

  @spec agent_span_attributes([PiEx.AI.Message.t()], Config.t(), Settings.t()) :: map()
  def agent_span_attributes(initial_messages, %Config{} = config, %Settings{} = settings) do
    %{
      "gen_ai.operation.name" => "invoke_agent",
      "gen_ai.provider.name" => safe_provider(config.model.provider),
      "gen_ai.request.model" => config.model.id
    }
    |> maybe_put("gen_ai.conversation.id", settings.conversation_id)
    |> maybe_put("gen_ai.agent.name", settings.agent_name)
    |> maybe_put("gen_ai.agent.description", settings.agent_description)
    |> maybe_put("gen_ai.agent.id", settings.agent_id)
    |> maybe_put("gen_ai.agent.version", settings.agent_version)
    |> Map.merge(server_attributes(config.model, nil))
    |> Map.merge(system_instruction_attributes(config.system_prompt, settings))
    |> Map.merge(
      maybe_json_attribute(
        "gen_ai.input.messages",
        settings.capture_sensitive_data,
        serialize_input_messages(initial_messages)
      )
    )
  end

  @spec finish_agent_span(
          term() | nil,
          [PiEx.AI.Message.t()],
          [PiEx.AI.Message.t()],
          Config.t(),
          Settings.t()
        ) ::
          :ok
  def finish_agent_span(
        span_ctx,
        initial_messages,
        final_messages,
        %Config{} = config,
        %Settings{} = settings
      ) do
    produced_messages = Enum.drop(final_messages, length(initial_messages))
    assistant_messages = Enum.filter(produced_messages, &match?(%AssistantMessage{}, &1))
    usage = aggregate_usage(assistant_messages)

    response_model =
      assistant_messages
      |> Enum.reverse()
      |> Enum.find_value(fn
        %AssistantMessage{model: model} when is_binary(model) and model != "" -> model
        _message -> nil
      end)

    finish_reasons =
      assistant_messages
      |> Enum.map(fn %AssistantMessage{stop_reason: stop_reason} ->
        Atom.to_string(stop_reason)
      end)
      |> Enum.uniq()

    span_ctx
    |> set_attributes(%{
      "gen_ai.response.model" => response_model || config.model.id,
      "gen_ai.response.finish_reasons" => finish_reasons,
      "gen_ai.usage.input_tokens" => usage.input_tokens,
      "gen_ai.usage.output_tokens" => usage.output_tokens
    })

    set_attributes(
      span_ctx,
      maybe_json_attribute(
        "gen_ai.output.messages",
        settings.capture_sensitive_data,
        serialize_output_messages(produced_messages)
      )
    )
  end

  @spec model_span_name(String.t()) :: String.t()
  def model_span_name(model_id), do: "chat #{model_id}"

  @spec model_span_attributes(Model.t(), Context.t(), keyword(), Settings.t()) :: map()
  def model_span_attributes(%Model{} = model, %Context{} = context, opts, %Settings{} = settings) do
    %{
      "gen_ai.operation.name" => "chat",
      "gen_ai.provider.name" => safe_provider(model.provider),
      "gen_ai.request.model" => model.id
    }
    |> maybe_put("gen_ai.request.temperature", numeric_option(opts, :temperature))
    |> maybe_put("gen_ai.request.max_tokens", integer_option(opts, :max_tokens))
    |> Map.merge(server_attributes(model, opts))
    |> Map.merge(system_instruction_attributes(context.system_prompt, settings))
    |> Map.merge(
      maybe_json_attribute(
        "gen_ai.input.messages",
        settings.capture_sensitive_data,
        serialize_input_messages(context.messages)
      )
    )
    |> Map.merge(
      maybe_json_attribute(
        "gen_ai.tool.definitions",
        settings.capture_sensitive_data,
        serialize_tool_definitions(context.tools)
      )
    )
  end

  @spec finish_model_span(term() | nil, AssistantMessage.t(), Settings.t()) :: :ok
  def finish_model_span(span_ctx, %AssistantMessage{} = message, %Settings{} = settings) do
    span_ctx
    |> set_attributes(%{
      "gen_ai.response.model" => message.model,
      "gen_ai.response.finish_reasons" => [Atom.to_string(message.stop_reason)],
      "gen_ai.usage.input_tokens" => message.usage.input_tokens,
      "gen_ai.usage.output_tokens" => message.usage.output_tokens
    })

    set_attributes(
      span_ctx,
      maybe_json_attribute(
        "gen_ai.output.messages",
        settings.capture_sensitive_data,
        serialize_output_messages([message])
      )
    )
  end

  @spec tool_span_name(String.t()) :: String.t()
  def tool_span_name(tool_name), do: "execute_tool #{tool_name}"

  @spec tool_span_attributes(Tool.t(), String.t(), map()) :: map()
  def tool_span_attributes(%Tool{} = tool, call_id, args) do
    %{
      "gen_ai.operation.name" => "execute_tool",
      "gen_ai.tool.name" => tool.name,
      "gen_ai.tool.type" => "function",
      "gen_ai.tool.call.id" => call_id
    }
    |> maybe_put("gen_ai.tool.description", tool.description)
    |> Map.merge(maybe_json_attribute("gen_ai.tool.call.arguments", true, args))
  end

  @spec tool_result_attributes(ToolResultMessage.t(), Settings.t()) :: map()
  def tool_result_attributes(%ToolResultMessage{} = result, %Settings{} = settings) do
    maybe_json_attribute(
      "gen_ai.tool.call.result",
      settings.capture_sensitive_data,
      serialize_tool_result(result)
    )
  end

  @spec serialize_input_messages([PiEx.AI.Message.t()]) :: [map()]
  def serialize_input_messages(messages) do
    Enum.map(messages, &serialize_message/1)
  end

  @spec serialize_output_messages([PiEx.AI.Message.t()]) :: [map()]
  def serialize_output_messages(messages) do
    Enum.map(messages, &serialize_message/1)
  end

  @spec serialize_tool_definitions([PiEx.AI.Tool.t()]) :: [map()]
  def serialize_tool_definitions(tools) do
    Enum.map(tools, fn tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => tool.parameters
      }
    end)
  end

  @spec serialize_tool_result(ToolResultMessage.t()) :: map()
  def serialize_tool_result(%ToolResultMessage{} = result) do
    %{
      "tool_name" => result.tool_name,
      "is_error" => result.is_error,
      "content" => Enum.map(result.content, &serialize_content/1)
    }
  end

  defp do_with_span(name, opts, _settings, fun) do
    parent_ctx = Keyword.get(opts, :parent_ctx)
    kind = Keyword.get(opts, :kind, :internal)
    attributes = Keyword.get(opts, :attributes, %{})
    parent_token = attach_ctx(parent_ctx)
    tracer = :opentelemetry.get_tracer(@scope, instrumentation_version(), :undefined)

    try do
      :otel_tracer.with_span(
        tracer,
        name,
        %{kind: kind, attributes: clean_attributes(attributes)},
        fun
      )
    after
      detach_ctx(parent_token)
    end
  end

  defp normalize_settings_map(nil), do: %{}

  defp normalize_settings_map(%Settings{} = settings) do
    settings
    |> Map.from_struct()
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == false end)
    |> Enum.into(%{})
  end

  defp normalize_settings_map(settings) when is_list(settings) do
    settings
    |> Enum.into(%{})
    |> normalize_settings_map()
  end

  defp normalize_settings_map(settings) when is_map(settings) do
    settings
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      Map.put(acc, normalize_key(key), value)
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    case key do
      "enabled" -> :enabled
      "capture_sensitive_data" -> :capture_sensitive_data
      "conversation_id" -> :conversation_id
      "agent_name" -> :agent_name
      "agent_description" -> :agent_description
      "agent_id" -> :agent_id
      "agent_version" -> :agent_version
    end
  end

  defp maybe_put(attributes, _key, nil), do: attributes
  defp maybe_put(attributes, _key, []), do: attributes
  defp maybe_put(attributes, key, value), do: Map.put(attributes, key, value)

  defp maybe_json_attribute(_key, false, _value), do: %{}
  defp maybe_json_attribute(_key, _enabled, value) when value in [nil, []], do: %{}
  defp maybe_json_attribute(key, true, value), do: %{key => encode_json!(value)}

  defp clean_attributes(attributes) do
    Enum.reduce(attributes, %{}, fn
      {_key, nil}, acc ->
        acc

      {_key, []}, acc ->
        acc

      {key, value}, acc ->
        Map.put(acc, key, normalize_attribute_value(value))
    end)
  end

  defp normalize_attribute_value(value) when is_binary(value), do: value
  defp normalize_attribute_value(value) when is_integer(value), do: value
  defp normalize_attribute_value(value) when is_float(value), do: value
  defp normalize_attribute_value(value) when is_boolean(value), do: value

  defp normalize_attribute_value(value) when is_list(value),
    do: Enum.map(value, &normalize_attribute_value/1)

  defp normalize_attribute_value(value), do: inspect(value)

  defp numeric_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) or is_float(value) -> value
      _value -> nil
    end
  end

  defp integer_option(opts, key) do
    case Keyword.get(opts, key) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp server_attributes(%Model{} = model, opts) do
    base_url =
      case opts do
        nil -> nil
        _ -> Keyword.get(opts, :base_url)
      end

    server_base =
      base_url ||
        provider_default_base_url(model.provider)

    case URI.parse(server_base || "") do
      %URI{host: host, port: port} when is_binary(host) ->
        %{}
        |> maybe_put("server.address", host)
        |> maybe_put("server.port", port)

      _uri ->
        %{}
    end
  end

  defp provider_default_base_url("openai") do
    PiEx.AI.ProviderConfig.get_base_url("openai") || "https://api.openai.com/v1"
  end

  defp provider_default_base_url("openai_responses") do
    PiEx.AI.ProviderConfig.get_base_url("openai") || "https://api.openai.com/v1"
  end

  defp provider_default_base_url(provider) do
    PiEx.AI.ProviderConfig.get_base_url(provider)
  end

  defp serialize_message(%UserMessage{content: content}) do
    %{"role" => "user", "content" => serialize_content_list(content)}
  end

  defp serialize_message(%AssistantMessage{content: content}) do
    %{"role" => "assistant", "content" => Enum.map(content, &serialize_content/1)}
  end

  defp serialize_message(
         %ToolResultMessage{tool_call_id: call_id, tool_name: tool_name} = message
       ) do
    %{
      "role" => "tool",
      "tool_call_id" => call_id,
      "tool_name" => tool_name,
      "is_error" => message.is_error,
      "content" => Enum.map(message.content, &serialize_content/1)
    }
  end

  defp serialize_message(%CompactionSummaryMessage{summary: summary}) do
    %{"role" => "system", "content" => [text_part(summary)]}
  end

  defp serialize_content_list(content) when is_binary(content), do: [text_part(content)]

  defp serialize_content_list(content) when is_list(content),
    do: Enum.map(content, &serialize_content/1)

  defp serialize_content(%TextContent{text: text}), do: text_part(text)

  defp serialize_content(%ThinkingContent{thinking: thinking}),
    do: %{"type" => "text", "content" => thinking}

  defp serialize_content(%ImageContent{mime_type: mime_type}) do
    %{"type" => "image", "mime_type" => mime_type}
  end

  defp serialize_content(%ToolCall{id: id, name: name, arguments: arguments}) do
    %{
      "type" => "tool_call",
      "id" => id,
      "name" => name,
      "arguments" => arguments
    }
  end

  defp text_part(text), do: %{"type" => "text", "content" => text}

  defp encode_json!(value), do: Jason.encode!(value)

  defp aggregate_usage(messages) do
    Enum.reduce(messages, %Usage{}, fn
      %AssistantMessage{usage: %Usage{} = usage}, acc ->
        %Usage{
          input_tokens: acc.input_tokens + usage.input_tokens,
          output_tokens: acc.output_tokens + usage.output_tokens
        }

      _message, acc ->
        acc
    end)
  end

  defp error_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type(reason) when is_binary(reason), do: reason

  defp error_type(%{__exception__: true} = exception),
    do: exception.__struct__ |> Module.split() |> List.last()

  defp error_type(_reason), do: @default_error_type

  defp instrumentation_version do
    case Application.spec(:pi_ex, :vsn) do
      version when is_list(version) -> List.to_string(version)
      version when is_binary(version) -> version
      _version -> "unknown"
    end
  end
end

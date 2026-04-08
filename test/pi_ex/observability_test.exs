defmodule PiEx.ObservabilityTest do
  use ExUnit.Case, async: true

  alias PiEx.AI.Content.{TextContent, ToolCall}
  alias PiEx.AI.Message.{AssistantMessage, ToolResultMessage, Usage}
  alias PiEx.Observability
  alias PiEx.Observability.Settings

  describe "resolve_settings/1" do
    test "merges app config with overrides" do
      Application.put_env(:pi_ex, :observability, enabled: true, agent_name: "default")

      on_exit(fn ->
        Application.delete_env(:pi_ex, :observability)
      end)

      settings = Observability.resolve_settings(capture_sensitive_data: true)

      assert %Settings{} = settings
      assert settings.enabled
      assert settings.capture_sensitive_data
      assert settings.agent_name == "default"
    end
  end

  describe "serialize_input_messages/1" do
    test "serializes user, assistant, and tool result messages" do
      messages = [
        PiEx.AI.Message.user("hello"),
        %AssistantMessage{
          content: [
            %TextContent{text: "hi"},
            %ToolCall{id: "call_1", name: "lookup", arguments: %{"q" => "x"}}
          ],
          model: "gpt-5.4",
          usage: %Usage{input_tokens: 4, output_tokens: 2},
          stop_reason: :tool_use,
          timestamp: 0
        },
        %ToolResultMessage{
          tool_call_id: "call_1",
          tool_name: "lookup",
          content: [%TextContent{text: "result"}],
          is_error: false,
          timestamp: 0
        }
      ]

      assert [
               %{"role" => "user", "content" => [%{"content" => "hello"}]},
               %{
                 "role" => "assistant",
                 "content" => [%{"content" => "hi"}, %{"type" => "tool_call"}]
               },
               %{"role" => "tool", "tool_call_id" => "call_1"}
             ] = Observability.serialize_input_messages(messages)
    end
  end

  describe "system_instruction_attributes/2" do
    test "omits payloads when sensitive capture is disabled" do
      refute Map.has_key?(
               Observability.system_instruction_attributes("secret", %Settings{}),
               "gen_ai.system_instructions"
             )
    end

    test "includes payloads when sensitive capture is enabled" do
      attributes =
        Observability.system_instruction_attributes("secret", %Settings{
          capture_sensitive_data: true
        })

      assert attributes["gen_ai.system_instructions"] =~ "secret"
    end
  end
end

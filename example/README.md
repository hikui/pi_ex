# Example

This project contains runnable demos for `PiEx.Agent` and `PiEx.DeepAgent`.

## Demos

- `Example.MultiRoundDemo.run/0` — basic multi-round conversation demo using one persistent `PiEx.Agent`
- `Example.DeepAgentExample.run/0` — project analyst demo with built-in filesystem tools plus a custom `mix_test` tool
- `Example.SkillsDemo.run/0` — skills-enabled deep agent demo using `example/skills/`
- `Example.CompactionDemo.run/0` — auto-context-compaction demo with a tiny context window

## Running

From the `example/` directory:

```bash
mix deps.get
mix run -e "Example.MultiRoundDemo.run()"
mix run -e "Example.DeepAgentExample.run()"
mix run -e "Example.SkillsDemo.run()"
mix run -e "Example.CompactionDemo.run()"
```

Set `OPENAI_API_KEY` first, or configure `:pi_ex, :openai` in `config/dev.secret.exs`.

The demos use the model-centric provider params API. For example:

```elixir
alias PiEx.AI.{Model, ProviderParams}

model =
  Model.new("gpt-5.4", "openai_responses",
    provider_params: %ProviderParams.OpenAIResponses{
      http_receive_timeout: 300_000,
      reasoning_effort: "low",
      reasoning_summary: "auto"
    }
  )
```

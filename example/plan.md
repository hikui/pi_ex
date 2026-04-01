# Plan: End-to-End DeepAgent Example

## Context

The `example/` directory is a minimal Mix scaffold. The goal is to populate it with a well-commented, end-to-end demonstration of `PiEx.DeepAgent` that showcases three capabilities:
1. **Built-in filesystem tools** — `ls`, `find`, `read`, `grep`, `write`, `edit`
2. **Custom tools** — `extra_tools` in `DeepAgent.Config`
3. **Path security** — `PathGuard` sandboxing all file access to `project_root`

The scenario is a "Project Code Analyst" agent that explores the `example/` directory itself, runs its test suite via a custom tool, and writes an `ANALYSIS.md` summary.

---

## Files to Create/Modify

### 1. `example/mix.exs` — Add pi_ex dependency

In `deps/0`, replace the placeholder comments with:
```elixir
{:pi_ex, path: "../"}
```
No other changes needed. `PiEx.Application` starts `FileMutex` and `TaskSupervisor` automatically as an included OTP app.

---

### 2. `example/lib/example/deep_agent_example.ex` — Main example (new)

> **No unit tests for the example** — it is purely demonstrative code, not library code.

Module: `Example.DeepAgentExample`

**Structure:**
```
@moduledoc   — scenario overview, what is demonstrated and why
@model       — module attribute built with `PiEx.AI.Model.new/3`

run/0             — public entry point: build config, start agent, subscribe, prompt, collect events
build_config/1    — private: constructs %PiEx.DeepAgent.Config{} with extra_tools
mix_test_tool/1   — private: returns %PiEx.Agent.Tool{} for running mix test
analyst_prompt/0  — private: multi-line task string guiding the agent through all 6 tools
collect_events/0  — private: tail-recursive receive loop with 5-min timeout
path_security_note/0 — private, never called: executable PathGuard demo for readers
```

**`run/0` key details:**
- `project_root = Path.expand("../..", __DIR__)` — resolves to `example/` from `lib/example/`
- Calls `PiEx.DeepAgent.start/1` → `PiEx.Agent.subscribe/1` → `PiEx.Agent.prompt/2`
- Drives `collect_events/0` to completion, then calls `PiEx.Agent.stop/1`
- Returns final messages list

**`mix_test_tool/1` — custom tool:**
```elixir
%PiEx.Agent.Tool{
  name: "mix_test",
  label: "Run Mix Tests",
  description: "Run `mix test` in the project root...",
  parameters: %{"type" => "object", "properties" => %{
    "filter" => %{"type" => "string", "description" => "Optional test file or tag filter."}
  }, "required" => []},
  execute: fn _id, params, _opts ->
    filter = Map.get(params, "filter")
    args = if filter, do: ["test", filter], else: ["test"]
    case System.cmd("mix", args, cd: project_root, stderr_to_stdout: true, env: [{"MIX_ENV", "test"}]) do
      {output, 0}    -> {:ok, %{content: [%PiEx.AI.Content.TextContent{text: output}], details: nil}}
      {output, code} -> {:ok, %{content: [%PiEx.AI.Content.TextContent{text: "Exit #{code}:\n#{output}"}], details: %{exit_code: code}}}
    end
  end
}
```
Non-zero exits return `{:ok, ...}` (not `{:error, ...}`) so the LLM sees test failure output and can reason about it.

**`analyst_prompt/0`:** Instructs the agent to execute steps in order:
1. `ls` top-level directory
2. `find` with `"**/*.ex"` to discover source files
3. `read` `mix.exs`
4. `grep` for `"defmodule"` across source files
5. `mix_test` to check test suite status
6. `write` to create `ANALYSIS.md` summarising all findings

This naturally exercises all 6 built-in tools plus the custom tool.

**`collect_events/0`:** Tail-recursive `receive` loop handling:
- `:agent_start` — print started message
- `{:message_update, _, {:text_delta, _, delta, _}}` — `IO.write(delta)` for streaming
- `{:tool_execution_start, id, name, args}` — print tool invocation
- `{:tool_execution_end, id, name, _, is_error}` — print result status
- `{:agent_end, messages}` — return messages (terminates recursion)
- `_other` — ignore (turn_start, turn_end, etc.)
- `after 300_000` — timeout guard returning `[]`

**`path_security_note/0`:** Never called from `run/0`; exists as executable documentation showing:
```elixir
# Traversal rejected:
{:error, "path is outside project root"} = PathGuard.resolve(root, "../etc/passwd")
# Absolute path outside root rejected:
{:error, "path is outside project root"} = PathGuard.resolve(root, "/etc/hosts")
# Valid path allowed:
{:ok, _} = PathGuard.resolve(root, "mix.exs")
```

---

## Critical APIs (verified from source)

- `PiEx.AI.Model.new/3` — supports `context_window` and typed `provider_params`
- `PiEx.DeepAgent.Config.validate/1` — uses `Path.expand` (not `File.real_path!`)
- `PiEx.DeepAgent.Tools.Write.execute/2` — takes atom-key map `%{path: ..., content: ...}` + project_root
- `PiEx.DeepAgent.PathGuard.resolve/2` — `canonical_root, user_path` order
- `PiEx.Agent.Tool` execute callback: `fn call_id, params, opts -> {:ok, %{content: [...], details: any}} | {:error, reason}`

## Verification

1. `cd example && mix deps.get && mix compile` — should compile cleanly
2. `OPENAI_API_KEY=sk-... mix run -e "Example.DeepAgentExample.run()"` — runs the full end-to-end demo, streams output, creates `ANALYSIS.md`
3. Manually inspect `ANALYSIS.md` to confirm it references `mix.exs`, module names, and test results

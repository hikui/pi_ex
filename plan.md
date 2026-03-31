# Plan: PiEx.DeepAgent — Built-in Tools Library

## TL;DR

Add `PiEx.DeepAgent` to the existing `pi_ex` library: a pre-configured agent harness that
wraps `PiEx.Agent` with 6 built-in LLM tools (ls, grep, find, read, write, edit) plus
support utilities (truncate, edit_diff, path_guard). All file operations are sandboxed to a
`project_root`. Uses ripgrep for grep/find, respects .gitignore. Serializes write/edit per
file via a `FileMutex` GenServer. Roadmap items (skills, compaction, sessions) are explicitly
out of scope.

---

## Phase 1: Utilities (pure / system-level, not LLM tools)

**Step 1. `PiEx.DeepAgent.Tools.Truncate`** — utility module, not an LLM tool
- `truncate_head(content, opts)` — keeps start; used by read tool
- `truncate_tail(content, opts)` — keeps end (for future bash output)
- `truncate_line(line, max_chars)` — truncates a single line
- Constants: `@default_max_lines 2000`, `@default_max_bytes 51200`, `@grep_max_line_length 500`
- Returns `{truncated_content, %{truncated: bool, lines_removed: n}}`

**Step 2. `PiEx.DeepAgent.Tools.EditDiff`** — utility module, not an LLM tool
- `fuzzy_find_text(content, old_text)` → `{:ok, %{start_line: n, end_line: n}} | {:error, reason}`
  - exact match first, then normalize (strip trailing ws, normalize unicode smart-quotes/dashes)
- `apply_edits(content, edits)` — all edits matched against ORIGINAL content, not sequentially
  → `{:ok, new_content} | {:error, reason}`
- `generate_diff(old_content, new_content, path)` — writes two temp files to `System.tmp_dir!/0`,
  runs `System.cmd("diff", ["-u", old_path, new_path])`, returns diff string, cleans up temp files

**Step 3. `PiEx.DeepAgent.PathGuard`** — security utility module (pure, no side effects)
- `resolve(canonical_root, user_path)` → `{:ok, abs_path} | {:error, :outside_project_root}`
- Expands via `Path.expand(user_path, canonical_root)`, then asserts result starts with
  `canonical_root <> "/"`
- Does NOT follow symlinks in `user_path`; `canonical_root` is pre-resolved at config time
- Every tool calls this before any filesystem operation; returns
  `{:error, "path is outside project root"}` if violated

**Step 4. `PiEx.DeepAgent.FileMutex`** — GenServer, serializes write/edit per file path
- State: `%{queues: %{path => [{from, fun}]}, running: MapSet.t()}`
- `with_lock(path, fun)` — `GenServer.call` that runs `fun.()` exclusively per path;
  queues caller if path is already locked
- Named process: `PiEx.DeepAgent.FileMutex`
- Added to `PiEx.Application` children list

---

## Phase 2: Built-in LLM Tools

Each module exports `tool(project_root)` → `%PiEx.Agent.Tool{}` and
`execute(params, project_root)` for direct testing. All tools call
`PathGuard.resolve(project_root, user_path)` before any filesystem operation.

**Step 5. `PiEx.DeepAgent.Tools.Ls`**
- Schema: `%{path: optional string, limit: optional integer}`
- `PathGuard.resolve` on `path` (defaults to `project_root`)
- `File.ls!/1`, `File.dir?/1` to append `/` to dirs, sort alphabetically
- Filters .gitignore: reads `Path.join(project_root, ".gitignore")`, parses simple patterns
  (non-comment, non-empty lines), filters via `Path.match?/2`
- Applies `limit` (default 500); appends truncation notice if exceeded
- Returns `{:ok, text_lines} | {:error, reason}`

**Step 6. `PiEx.DeepAgent.Tools.Find`**
- Schema: `%{pattern: string, path: optional string, limit: optional integer}`
- `PathGuard.resolve` on `path` (defaults to `project_root`)
- `System.cmd("rg", ["--files", "--glob", pattern, resolved_path])` — natively respects .gitignore
- Falls back to `Path.wildcard/2` if rg not found (no .gitignore filtering in fallback)
- Returns paths relative to `resolved_path`; applies `limit` (default 1000)
- Returns `{:ok, text_lines} | {:error, reason}`

**Step 7. `PiEx.DeepAgent.Tools.Read`**
- Schema: `%{path: string, offset: optional integer, limit: optional integer}`
- `PathGuard.resolve` on `path`
- `File.read!/1` → split lines → apply `offset` (1-indexed) and `limit`
- `Truncate.truncate_head` with `@default_max_lines` / `@default_max_bytes`
- Prepends line numbers: `"  123 | content"`
- Returns `{:ok, numbered_text} | {:error, reason}`

**Step 8. `PiEx.DeepAgent.Tools.Grep`**
- Schema: `%{pattern: string, path: optional string, glob: optional string,
  ignore_case: optional bool, literal: optional bool, context: optional integer,
  limit: optional integer}`
- `PathGuard.resolve` on `path` (defaults to `project_root`)
- rg args: `--no-heading --line-number --color=never`; plus `--ignore-case`, `--fixed-strings`,
  `--after-context`/`--before-context`, `--glob`, `--max-count` as applicable
- Each output line truncated to `@grep_max_line_length` via `Truncate.truncate_line/2`
- Returns `"file:line: content"` lines joined; appends limit notice if capped
- Returns `{:ok, text} | {:error, reason}`

**Step 9. `PiEx.DeepAgent.Tools.Write`**
- Schema: `%{path: string, content: string}`
- `PathGuard.resolve` on `path`
- `File.mkdir_p!/1` for parent dirs
- `FileMutex.with_lock(abs_path, fn -> File.write!(abs_path, content) end)`
- Returns `{:ok, "Wrote N bytes to <path>"} | {:error, reason}`

**Step 10. `PiEx.DeepAgent.Tools.Edit`**
- Schema: `%{path: string, edits: [%{old_text: string, new_text: string}]}`
- `PathGuard.resolve` on `path`
- `FileMutex.with_lock(abs_path, fn -> ... end)` wrapping:
  1. `File.read!/1`
  2. `EditDiff.apply_edits(content, edits)` → `{:ok, new_content}`
  3. `File.write!/2`
  4. `EditDiff.generate_diff(old_content, new_content, abs_path)`
- Returns `{:ok, diff_string} | {:error, reason}`

---

## Phase 3: DeepAgent Facade

**Step 11. `PiEx.DeepAgent.Config`**
```elixir
%PiEx.DeepAgent.Config{
  model:         %PiEx.AI.Model{},   # required
  project_root:  binary(),           # required; canonicalized via File.real_path!/1
  system_prompt: binary() | nil,     # nil = use built-in default
  extra_tools:   list(),             # default []
  api_key:       binary() | nil,
  temperature:   float() | nil,
  max_tokens:    integer() | nil
}
```
- `Config.validate(%Config{})` → `{:ok, config} | {:error, reason}`
  - resolves `project_root` with `File.real_path!/1` (symlink-safe canonical path)
  - fails if `project_root` does not exist or is not a directory

**Step 12. `PiEx.DeepAgent.SystemPrompt`**
- `build(tools, opts)` → binary system prompt
- Role preamble: "You are a general-purpose AI agent..."
- `## Available tools` section: name + description per tool
- `## Guidelines` section: prefer read/grep/find for discovery; all paths relative to
  project root; avoid unnecessary writes
- Optional `append_system_prompt` concatenated at end

**Step 13. `PiEx.DeepAgent`** — public facade
- `start(%Config{} = config)` → `{:ok, pid}`
  1. `Config.validate(config)` → canonical config
  2. `built_in_tools(canonical_root)` = [Ls, Find, Read, Grep, Write, Edit tools]
  3. Merge with `config.extra_tools`
  4. `SystemPrompt.build(all_tools, opts)` (or use `config.system_prompt` if set)
  5. Build `%PiEx.Agent.Config{}` and call `PiEx.Agent.start/1`
- `start!(%Config{})` → `pid` (raises on error)
- All further interaction via `PiEx.Agent.*` API (prompt, subscribe, steer, abort, etc.)

---

## Phase 4: Tests

**Step 14.** `test/pi_ex/deep_agent/tools/truncate_test.exs` — `async: true`
- head/tail/line truncation happy paths
- content within limits (no truncation), empty content, exactly at limit

**Step 15.** `test/pi_ex/deep_agent/tools/edit_diff_test.exs` — `async: true`
- `fuzzy_find_text`: exact match, fuzzy (trailing ws diff, smart quotes), not found
- `apply_edits`: single edit, multiple edits, edit not found returns error

**Step 16.** `test/pi_ex/deep_agent/path_guard_test.exs` — `async: true`
- valid path inside root, path traversal (`../`), absolute path outside root,
  path equal to root itself, symlinks in user path

**Step 17.** `test/pi_ex/deep_agent/file_mutex_test.exs` — `async: false`
- sequential execution: two concurrent calls on same path run in order
- independent paths are not blocked by each other

**Step 18.** File tool tests — `async: true`, each using a temp dir as `project_root`
- `ls_test.exs`: lists files, appends `/` to dirs, respects limit, filters .gitignore,
  rejects path outside root
- `find_test.exs`: finds by glob, limit, error on missing dir, rejects path outside root
- `read_test.exs`: reads with line numbers, offset+limit, file not found, rejects outside root
- `grep_test.exs`: pattern match, case insensitive, limit; tag with `@tag :requires_rg` and
  skip gracefully if rg not installed
- `write_test.exs`: creates parent dirs, overwrites existing file, rejects path outside root
- `edit_test.exs`: applies edits and returns diff, error on missing old_text,
  rejects path outside root

**Step 19.** `test/pi_ex/deep_agent_test.exs` — `async: false`
- `start/1` returns `{:ok, pid}`
- `start/1` with non-existent project_root returns `{:error, _}`
- system prompt contains each built-in tool name

---

## Files

### New files
- `lib/pi_ex/deep_agent.ex`
- `lib/pi_ex/deep_agent/config.ex`
- `lib/pi_ex/deep_agent/system_prompt.ex`
- `lib/pi_ex/deep_agent/path_guard.ex`
- `lib/pi_ex/deep_agent/file_mutex.ex`
- `lib/pi_ex/deep_agent/tools/truncate.ex`
- `lib/pi_ex/deep_agent/tools/edit_diff.ex`
- `lib/pi_ex/deep_agent/tools/ls.ex`
- `lib/pi_ex/deep_agent/tools/find.ex`
- `lib/pi_ex/deep_agent/tools/read.ex`
- `lib/pi_ex/deep_agent/tools/grep.ex`
- `lib/pi_ex/deep_agent/tools/write.ex`
- `lib/pi_ex/deep_agent/tools/edit.ex`
- `test/pi_ex/deep_agent_test.exs`
- `test/pi_ex/deep_agent/path_guard_test.exs`
- `test/pi_ex/deep_agent/file_mutex_test.exs`
- `test/pi_ex/deep_agent/tools/truncate_test.exs`
- `test/pi_ex/deep_agent/tools/edit_diff_test.exs`
- `test/pi_ex/deep_agent/tools/ls_test.exs`
- `test/pi_ex/deep_agent/tools/find_test.exs`
- `test/pi_ex/deep_agent/tools/read_test.exs`
- `test/pi_ex/deep_agent/tools/grep_test.exs`
- `test/pi_ex/deep_agent/tools/write_test.exs`
- `test/pi_ex/deep_agent/tools/edit_test.exs`

### Modified files
- `lib/pi_ex/application.ex` — append `PiEx.DeepAgent.FileMutex` child
- `mix.exs` — no dependency changes needed

### Reference (read before implementing)
- `lib/pi_ex/agent/tool.ex` — `%PiEx.Agent.Tool{}` struct and `execute` fn signature
- `lib/pi_ex/agent/config.ex` — `%PiEx.Agent.Config{}` fields
- `lib/pi_ex/agent.ex` — `PiEx.Agent.start/1`
- `lib/pi_ex/application.ex` — existing supervision tree

---

## Verification

1. `mix compile --warnings-as-errors` — no warnings
2. `mix test test/pi_ex/deep_agent` — all tool and unit tests pass
3. `mix test` — full suite green

---

## Decisions

- **Sandbox**: `project_root` canonicalized via `File.real_path!/1` at `Config.validate/1` time;
  `PathGuard` enforces containment on every operation
- **Namespace**: `PiEx.DeepAgent` under existing `PiEx` umbrella
- **No bash tool**: explicitly excluded
- **Grep/find backend**: ripgrep (`rg`) via `System.cmd/2`; `Path.wildcard` fallback for find
- **ls .gitignore**: manual parse of `<project_root>/.gitignore` (simple line patterns)
- **Write/edit serialization**: `FileMutex` GenServer per absolute path
- **edit_diff / truncate**: utility modules only, not registered as LLM tools
- **No new hex deps**: stdlib + existing deps (`req`, `jason`) + system tools (`rg`, `diff`)
- **Roadmap OUT of scope**: skills, auto-compaction, session management

---

## Roadmap (future)

1. **Skills** — load `.pi/skills/<name>/SKILL.md` files; inject into system prompt
2. **Auto context compaction** — detect token overflow, summarize old context via LLM
3. **Session management** — persist conversation to NDJSON on disk; resume sessions

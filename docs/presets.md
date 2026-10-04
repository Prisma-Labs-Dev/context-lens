# Presets

A preset starts Claude Code or Codex with a different context than the files on disk would give,
without changing those files. Presets apply to launches from Context Lens (the Launch button or
`context-lens run`). The Claude and Codex desktop apps start their own sessions and ignore them.

## Built-in and example presets

- **Clean install** (`clean-install`): nothing of yours loads. Claude Code runs with `--safe-mode`. Codex runs from a separate home
  that only links your login and session history.
- **On disk**: a plain launch, with everything the harness finds.
- **Autonomous**, **Careful** and **Lean** are seeded on first launch as editable examples. Delete or
  change them freely. They live in `~/.context-lens/presets/<id>.json`.

## What a custom preset can do

- Switch off individual files (CLAUDE.md, rules, imports, AGENTS.md), skills, MCP servers and
  plugins (Claude Code).
- Switch off whole groups (all skills, all MCP servers, memory, hooks), which also covers items
  added to disk later.
- Keep the instruction files, add its own instructions, or replace the user-level file
  (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`) with its own. Project files still load.

## How each harness is told

Every switch below was verified on 2026-10-03 by launching the harness and reading what it
recorded (Claude Code 2.1.283, codex-cli 0.159.3). Each launch writes its generated files to its
own directory, `~/.context-lens/generated/<preset>/<harness>/<time>-<id>/`, so a later launch never
replaces files a running session uses. Directories older than 14 days are removed. Preset ids must
be lowercase letters, digits and dashes; files with other ids are ignored.

### Claude Code

Settings passed with `--settings <file>` sit above user, project and local settings:

| Preset switch | Mechanism |
| --- | --- |
| A CLAUDE.md, rule, import or AGENTS.md off | `claudeMdExcludes: [absolute paths]` |
| A skill off | `skillOverrides: { name: "off" }` |
| All skills off | `--disable-slash-commands` |
| Built-in skills off | `disableBundledSkills: true` |
| Memory off | `autoMemoryEnabled: false` |
| Hooks off | `disableAllHooks: true` |
| A plugin off | `enabledPlugins: { "id@market": false }` |
| Some MCP servers off | `--strict-mcp-config --mcp-config <file with the rest>` (claude.ai connectors drop too) |
| Added or replacement instructions | `--add-dir <dir with CLAUDE.md>` plus `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`; replace also excludes `~/.claude/CLAUDE.md` |
| Clean install | `--safe-mode` (built-in skills and the system prompt remain) |

Subagents cannot be switched off one by one.

### Codex

`-c key=value` overrides, which Codex honors only after a subcommand (`codex exec -c ...`), so
`context-lens run` places them after one when present:

| Preset switch | Mechanism |
| --- | --- |
| Project AGENTS.md off | `project_doc_max_bytes=0` (all project docs; Codex has no per-file switch) |
| A skill off | `skills.config=[{path="…/SKILL.md",enabled=false}]`, merged with your own `[[skills.config]]` entries |
| All skills off | `skills.include_instructions=false` |
| Memory off | `features.memories=false` |
| An MCP server off | `mcp_servers.<name>.enabled=false` |
| Added instructions | `developer_instructions="…"` |
| Global AGENTS.md off or replaced | `CODEX_HOME=<generated home>` that links auth, config, sessions, skills and plugins but not `AGENTS.md`. SQLite state stays separate so WAL files are never shared; memory files are copied. |
| Clean install | a generated home with only auth and sessions, and a config that keeps model, login and approval settings and project trust (single-line values only), plus the switches above |

## Launching

- **Launch** in the top bar writes `~/.context-lens/launch/<time>-<preset>-<harness>.command` and
  opens it in Terminal: `cd <folder> && context-lens run <preset> <harness>`.
- `context-lens run <preset> <claude|codex> [args…]` runs the harness through your interactive
  shell (`$SHELL -i -c`), so aliases and functions such as `teamclaude` or `codex-guard` still apply.
- **Copy Command** copies the same `context-lens run` command, for any terminal.
- `context-lens plan <preset> <harness> [dir]` prints the raw flags and environment for inspection.
  A plan's directory is not marked in use, so do not run long sessions from a pasted plan;
  `context-lens run` marks the directory with its pid and cleanup skips it while it lives.
- Each run is logged to `~/.context-lens/launches.jsonl`; the session view uses it to show which
  preset a past session ran with.

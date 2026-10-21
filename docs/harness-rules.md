# How the harnesses build their context

These rules were checked on 2026-10-03 against Claude Code 2.1.283 and codex-cli 0.159.3. Each
harness ran once in a throwaway git repo containing every kind of instruction file. The test then
read back what the harness recorded in its transcript. Re-run that check when a harness updates
(see "Re-checking" below). The resolvers in `Sources/ContextLensCore` encode these rules, and the
tests in `Tests/` use the same fixture layout.

## Claude Code

Loaded at start, in this order:

1. Managed policy: `/Library/Application Support/ClaudeCode/CLAUDE.md`.
2. User: `~/.claude/CLAUDE.md`, `~/.claude/rules/**/*.md`.
3. Every ancestor of the cwd except `/`, top down: `CLAUDE.md`, `.claude/CLAUDE.md`,
   `.claude/rules/**/*.md`, `CLAUDE.local.md`.
4. Auto memory index: `~/.claude/projects/<slug>/memory/MEMORY.md`. `<slug>` is the main repo
   root path with every non-alphanumeric character replaced by `-`. Linked worktrees share the
   main repo's memory.

Details:

- `AGENTS.md` is read only when step 3 finds no `CLAUDE.md`, `.claude/CLAUDE.md`,
  `CLAUDE.local.md` or rule. In that case every `AGENTS.md` on the ancestor path loads. With any
  CLAUDE file present, none load. A CLAUDE.md can still pull one in with `@AGENTS.md`.
- Rules with `paths:` frontmatter load only when matching files are touched (`nested_memory`).
- `CLAUDE.md` files below the cwd load when Claude Code reads files in that directory.
- In a linked worktree nested inside its main repo (`repo/.claude/worktrees/x`), directories from
  the main repo root down to the worktree are skipped, so the main checkout's copy of the same
  file is not loaded twice.
- Skills (`~/.claude/skills`, `.claude/skills` in ancestors, enabled plugins) are listed as
  `- name: description`. The body loads when the skill runs.

Recorded in transcripts (`~/.claude/projects/<slug>/<session>.jsonl`) as `attachment` lines:
`instructions` (files with path, scope and content), `prompt_snapshot` (system prompt parts),
`skill_listing`, `nested_memory`, `invoked_skills`, `mcp_instructions_delta`,
`agent_listing_delta`, `deferred_tools_delta`, `context_sections`, `session_context`,
`environment`, `hook_additional_context`. Older transcripts lack these records.

## Codex

1. Global: `$CODEX_HOME/AGENTS.override.md`, else `$CODEX_HOME/AGENTS.md`.
2. Project: from the git root down to the cwd, the first of `AGENTS.override.md`, `AGENTS.md`,
   then `project_doc_fallback_filenames` in each directory. Concatenated up to
   `project_doc_max_bytes` (32 KiB default). `CLAUDE.md` is not read.
3. Skills: `$CODEX_HOME/skills` (and `.system`), `~/.agents/skills`, plugin caches, and
   `.agents/skills` from the cwd up to the git root. Listed as `- name: description (file: ...)`.
   Plugin skills come from `plugins/cache/<marketplace>/<plugin>/<version>/skills` and are named
   `plugin:skill`. Context Lens takes the newest cached version of each plugin and skips plugins
   with `enabled = false` in `config.toml`; this part is an approximation.
4. Memory: with `[features] memories = true`, `memories/memory_summary.md` goes into a developer
   message.

Recorded in rollouts (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): `session_meta` holds
`base_instructions`; developer messages hold memory, skills, permissions and collaboration mode.
A user message `# AGENTS.md instructions for <cwd>` holds the global file, then
`--- project-doc ---`, then the project docs concatenated without file markers. Codex adds no
markers of its own; `<!-- BEGIN GLOBAL AGENTS.md -->` comments seen in some rollouts were pasted
into the global file itself. Context Lens matches the project text against today's files to
attribute it.

## Prompt cache

Checked on 2026-10-04 against Claude Code 2.1.289 and codex-cli 0.160.0 by resuming one session
several times with `-p` / `exec resume` and reading the usage each turn reported.

- Neither harness rewrites the start of a conversation when context files change. Claude Code
  appends an `instructions` attachment with `"changed": true` (or `"removed"`) at the next turn;
  Codex appends the new AGENTS.md text. The model sees the new content, and only that delta is
  new input.
- Codex resume keeps the cache: after an AGENTS.md edit, 58.6k of 71.3k input tokens were cached,
  and resuming under the Clean install preset read 105k of 157k from cache.
- A Claude Code resume in a new process re-writes the conversation cache even when nothing
  changed (about 22k of 22k conversation tokens written on each resume, with and without a
  proxy in front of the API). Resuming after a CLAUDE.md edit or with `--safe-mode` cost the same as an
  unchanged resume, so presets add nothing to it.
- Presets never write files the harnesses read, and Launch always starts a new session, so
  presets change no running or resumed session's prefix. MCP settings do write harness settings
  (see "Switching MCP servers and plugins"); a running Claude Code session picks up plugin changes
  only through `/reload-plugins`, which itself refuses to change a tool list the prompt cache
  depends on without `--force`. Whether a running session drops a newly denied server live was not
  tested; the sheet says running sessions keep their tools until they restart. Any feature that would
  (resuming under a preset, editing a file a session already loaded, switching a session's model)
  must say so and ask first.

## Measured context

Checked on 2026-10-07 against Claude Code 2.1.281 by running `claude -p "/context"` and then a
one-word `-p` prompt with `--output-format json` in the same folder and clean environment, and
comparing the first call's usage with what `/context` counted.

- `/context` counts the harness prompt, built-in tools, MCP tool schemas per server, instruction
  files, the skill listing and custom agents. It doesn't count MCP server instructions or the
  built-in subagent listing, which go into the first message.
- Its count of built-in tools depends on how the run started. Runs of the same setup reported
  16.0k, 16.4k, 19.6k and 20.3k for System tools; with tool search (1M-context model) it reports
  10k. The first call of a one-word prompt was 11.0k larger than `/context`'s total with tool
  search on, 4.6k larger with an MCP server and tool search off, and 0.3k larger with neither.
- Each `/context` run is recorded in the transcript as a `system` entry with subtype
  `local_command` and a `contextUsage` object with exact counts (`categories`, `mcp_tools` with
  `server_name`, `memory_files`, `skills`, `agents`). The printed table rounds to 0.1k. Context
  Lens adds these runs to a folder's measurement history.
- `/context` names plugin MCP servers `plugin_<plugin>_<server>`; transcripts name the same server
  `plugin:<plugin>:<server>`.
- An MCP server that connects slowly can be missing from a `-p` measurement. A measurement taken
  13 seconds later in the folder above had it.
- Transcript text runs at about 2.9 characters per token for instruction files and skill listings,
  not 4. Context Lens scales its estimates of a session by `/context`'s count of the same files.

## Worktree command guard

Read from the Claude Code 2.1.286 binary on 2026-10-04 (the CLI and the copy the desktop app runs
from `~/Library/Application Support/Claude/claude-code/`), after agent health counted 176
refusals in 29 sessions in one week.

- It lives in the Bash executor, after permission rules and hooks. It is not a hook, so no
  `permissions.allow` rule, PreToolUse hook or setting turns it off; none of the session's
  settings gate it.
- It runs on every Bash call in a session or subagent that has an isolation worktree:
  `EnterWorktree`, a desktop session started in a worktree, or a subagent with
  `isolation: "worktree"`.
- Check 1: the command's working directory must not resolve to the shared checkout ("…working
  directory resolved to the shared checkout"). A `cd` into the main repo trips it.
- Check 2: the command must provably not run git outside the worktree. Anything the parser cannot
  reduce to simple commands with literal program names is refused, read-only or not: heredocs,
  `for` loops, `$VAR` or `$(…)` as a program or a directory, `source`/`.`, `export X=$(…)`,
  `cd $X`. The refusal says "too complex to verify", "names git in a form too complex", or "runs X
  with a value computed at runtime".
- The PreToolUse:Write refusal for files in a sibling worktree is a separate hook check.

What avoids it: start sessions in place unless they change repo files; inside a worktree, write
multi-line scripts to a file and run `python3 /path/script.py`, keep one plain command per call,
and use absolute paths inside the worktree.

## Switching MCP servers and plugins

Checked on 2026-10-07 against Claude Code 2.1.281 and codex-cli 0.153.2: each key was written in
a throwaway `HOME` and read back with `claude mcp list` / `codex mcp list`, and `claude plugin
enable|disable --scope local` was run to see what it writes. The MCP settings sheet and
`context-lens mcp` write exactly these keys.

| What | This folder | Everywhere |
|---|---|---|
| Claude Code plugin (its MCP servers and skills) | `enabledPlugins["<plugin>@<marketplace>"]` in `<project>/.claude/settings.local.json` | the same key in `~/.claude/settings.json` |
| User server (`mcpServers` in `~/.claude.json`) | `projects["<project>"].disabledMcpServers` in `~/.claude.json` | `deniedMcpServers: [{"serverName": "<name>"}]` in `~/.claude/settings.json` |
| Local server (`projects["<project>"].mcpServers`) | `projects["<project>"].disabledMcpServers` | (only exists in that project) |
| `.mcp.json` server | `disabledMcpjsonServers` / `enabledMcpjsonServers` in `<project>/.claude/settings.local.json` | (per project) |
| Codex server | `[mcp_servers.<name>] enabled` in `<project>/.codex/config.toml`, read only for trusted projects | `enabled = false` in `~/.codex/config.toml` |

- `<project>` is the git root (the worktree root in a linked worktree), or the folder outside git.
  `claude plugin --scope local` writes there from a subfolder, and `/mcp` keys its project entry
  the same way. Settings files in the cwd itself are read too; Context Lens reads them but writes
  only at the project root.
- `enabledPlugins` merges user, project and local settings; the later one wins, so `false` in
  user settings and `true` in the folder's local settings is "off everywhere, on here".
  `claude plugin enable|disable --scope user|project|local` writes the same key; Context Lens edits
  the JSON itself so every write goes through one path with a backup, a diff and undo, and works
  without `claude` on the app's PATH.
- `/mcp disable <server>` writes `disabledMcpServers` in the project entry ("⊘ Disabled for this
  project"); there is no CLI command for it and no user-wide form of it. A missing project entry
  is created with the defaults Claude Code itself uses (`allowedTools: []`, `mcpServers: {}`, ...).
  Plugin servers appear there as `plugin:<plugin>:<server>`.
- `deniedMcpServers` is documented as an enterprise denylist but is read from user and local
  settings too: the server disappears from `claude mcp list`. A deny wins over every allow, so a
  folder cannot turn a denied server back on (an `allowedMcpServers` entry in local settings did not).
  For "off everywhere, on here" with a user server, leave it on everywhere and switch it off in the
  folders that don't need it.
- Codex: `enabled = false` shows the server as `disabled` in `codex mcp list`; a trusted project's
  `.codex/config.toml` overrides it per server (`enabled = true` there turns it back on).
  Servers that Codex plugins bring are switched with the plugin, not here.
- Claude Desktop's built-in MCP tools and claude.ai connectors are not in these files. The sheet
  shows servers a `/context` measurement saw but no file defines as fixed rows.
- Running sessions keep the tools they started with until they restart (plugins: until
  `/reload-plugins`, read from the binary; a live deny was not tested).

Writing safely:

- Claude Code writes `~/.claude.json` under a `proper-lockfile` lock (a directory at
  `~/.claude.json.lock`) and re-reads the file under it. Context Lens takes the same lock for every
  file it writes, re-reads, applies key-level edits and checks the file didn't change before the
  rename, so neither side loses the other's write.
- JSON is edited with an order-preserving parser and written the way `JSON.stringify(v, null, 2)`
  does, so a file Claude Code wrote changes only in the edited lines. Unknown keys, key order and
  number spellings stay. Files that aren't strict JSON are refused.
- TOML is edited line by line, so comments and layout stay; a server defined as a dotted key or
  an inline table is refused rather than rewritten.
- Symlinked files are written through the link; permissions are kept (`~/.claude.json` is 0600).
- Every write is backed up to `~/.context-lens/backups/` first, and the inverse edits of the last
  change are kept in `last-change.json` for undo.
- A folder-scope file that git doesn't ignore gets a warning before it is written.

## Skill use

Being listed in the context is not a use. The Skills screen and `context-lens skills` count only
what a transcript shows a session doing:

- Claude Code: a `Skill` tool call (`model`, or `subagent` inside a subagent transcript), a
  `<command-name>` message for a name in `invoked_skills` (`user`, so built-ins such as `/model`
  do not count), or a `Read` or shell read (as for Codex, below) of a `SKILL.md` under a `skills/`
  folder.
- Codex has no skill tool. Its instructions list every skill's path, so a use is a shell call
  whose command prints a `SKILL.md` with a reader such as `cat`, `sed -n` or `head`. Editors,
  `ls`, `rg -g`, `sed -i`, `apply_patch`, globs and bare relative or remote paths do not count.
- Copilot CLI: `skill.invoked` in `~/.copilot/session-state/<id>/events.jsonl`, with
  `trigger` `user-invoked` or agent-invoked.

A plugin skill is named `plugin:skill`; any other skill takes its folder name. Results are cached
per transcript under `~/.context-lens/skills/`, keyed by size and modification time.

Known limits: a SKILL.md read in order to edit it counts as a use; skills bundled with Claude Code
show as not installed; repo-relative SKILL.md paths are not counted.

## Re-checking

```bash
mkdir -p /tmp/cl-exp/sub && cd /tmp/cl-exp && git init -q
echo 'root CLAUDE marker' > CLAUDE.md; echo 'root AGENTS marker' > AGENTS.md
echo 'sub AGENTS marker' > sub/AGENTS.md
cd sub && claude -p "Reply with exactly: ok" --model haiku </dev/null
codex exec -m gpt-6-luna "Reply with exactly: ok" </dev/null
context-lens session "$(ls -t ~/.claude/projects/*cl-exp-sub/*.jsonl | head -1)"
```

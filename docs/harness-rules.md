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
- Context Lens never writes files the harnesses read, and Launch always starts a new session, so
  nothing in the app changes a running or resumed session's prefix. Any feature that would
  (resuming under a preset, editing a file a session already loaded, switching a session's model)
  must say so and ask first.

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

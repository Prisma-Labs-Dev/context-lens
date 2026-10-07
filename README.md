# Context Lens

A macOS app that shows what Claude Code and Codex put into their context. Instruction files, rules,
imports, memory, skills, subagents, MCP servers and hooks pile up over time. Some go stale and
start working against you. Context Lens shows all of it in one place so you can prune it.

One flow: pick a folder in the sidebar, pick Claude Code or Codex in the top bar, and read what
that harness puts into its context there.

- **Now**: predicted from the files on disk. Each item shows its scope, how it loads (always,
  listed, on demand, not loaded), a token estimate and when it was last edited.
- **Past sessions**: the source picker in the top bar lists the harness's past sessions in that
  folder. Picking one shows the context it actually received, including the system prompt.
  Files that changed or disappeared since are marked M or D, with a recorded/current/diff view.
- **Presets**: launch a harness with less (or different) context without touching your files.
  Clean install loads nothing of yours; On disk is a plain launch; custom presets switch individual files,
  skills, MCP servers, memory and hooks on or off and can add to or replace your global
  instructions. Launch opens Terminal in the folder; `context-lens run <preset> claude` does the
  same from a shell. See docs/presets.md.
- **Stale references**: absolute and `~/` paths in context files that no longer exist are flagged.
  A note about a deleted repo or tool is a strong sign the note itself is outdated.
- **Skills**: which skills Claude Code, Codex and Copilot sessions actually used, filtered by time
  window and folder, with per-skill counts and the installed skills nothing used (a prune list).
  A By session mode lists the skills each session used; a past session in the main window shows
  them above its context. Use is read from the transcripts (a skill tool call, a slash command, or
  a read of the skill's SKILL.md); no model is involved.

## Requirements

- macOS 26 or later.
- Xcode 27 (Swift 6.2) and [XcodeGen](https://github.com/yonaskolb/XcodeGen):
  `brew install xcodegen`.
- Claude Code and/or Codex, with the sessions you want to look at. Context Lens only reads what
  they leave on disk.
- Optional, for agent health classification only: Node 22.18 or later and pnpm. See below.

## Install

With Homebrew:

```bash
brew install --cask prisma-labs-dev/tap/context-lens
```

This installs `/Applications/Context Lens.app`, signed with a Developer ID and notarized by Apple,
and puts the `context-lens` CLI on your PATH. `brew upgrade --cask context-lens` updates it;
`brew uninstall --zap --cask context-lens` also removes `~/.context-lens`.

Or build it from source (needs Xcode and XcodeGen, see above):

```bash
git clone https://github.com/Prisma-Labs-Dev/context-lens.git
cd context-lens
scripts/install.sh      # Release build into ~/Applications/Context Lens.app, then launch
```

A source build is signed with your first "Apple Development" identity if the keychain has one
(override with `CONTEXT_LENS_SIGN_IDENTITY`), otherwise ad hoc. A stable identity keeps macOS
privacy grants such as Full Disk Access across rebuilds; with an ad hoc signature every build
counts as a new app. Either way it opens on the Mac that built it, and Gatekeeper blocks it on
another Mac. "Install Command Line Tool" (in the presets panel) links
`~/.local/bin/context-lens` to the CLI inside it.

The app is **unsandboxed** either way. The menu bar icon (bars under a lens) lists recent folders
and keeps running when the window is closed. "Open at Login" is in that menu.

Releases are built on a Mac with `scripts/release.sh`, which signs, notarizes and zips the app
for the cask in [Prisma-Labs-Dev/homebrew-tap](https://github.com/Prisma-Labs-Dev/homebrew-tap).

## What it reads and writes

It is unsandboxed because it has to read files outside its own container:

- `~/.claude` and `~/.claude.json` (settings, instructions, skills, agents, plugins, memory, MCP
  servers, session transcripts under `~/.claude/projects`), `~/.codex` (config, AGENTS.md,
  skills, memories, session rollouts), and managed settings under
  `/Library/Application Support/ClaudeCode`.
- The project folders you pick, every folder above them, and their subfolders (skipping
  `node_modules`, build output and similar), for `CLAUDE.md`, `AGENTS.md`, `.claude/`, `.agents/`
  and `.mcp.json`, plus any file those import with `@path`. The stale check only tests whether
  the paths they mention exist.
- For skills: Copilot CLI sessions and skills under `~/.copilot`, and skills under `~/.agents`.
- For agent health only: Claude desktop session metadata under
  `~/Library/Application Support/Claude`, and OpenClaw's Codex homes under `~/.openclaw` if present.

Folders macOS guards (Desktop, Documents, Downloads, iCloud Drive, other `~/Library` data,
photo and music libraries, other volumes) are never walked into. A session folder in one of them
is listed but left unread until you give Context Lens Full Disk Access; the sidebar then shows one
row that opens that setting, instead of a privacy prompt per folder.

It writes only to `~/.context-lens/` (generated preset settings, caches such as
`~/.context-lens/skills/`, `/context` measurement history under `~/.context-lens/context/`,
health reports), the
optional `~/.local/bin/context-lens` link, and the app's own preferences. It never edits a file
the harnesses read.

**Nothing leaves your Mac.** The app and the engine make no network requests. The two exceptions
are opt-in CLI commands, described next.

## Agent health (optional)

`context-lens health` reads every Claude Code, Codex and OpenClaw session in a window, finds tool
errors, guard and permission walls, retries, corrections and interrupts, and ranks the causes with
counts and links to example sessions. The app shows the results in its Agent Health window (⌘⇧H).
See docs/health.md.

Extraction runs locally. Two further steps send data off the Mac, and both are off unless you
turn them on:

- **Classification** labels each event with Jev, which sends redacted, clipped excerpts of your
  transcripts to TypeSafe's API (`api.typesafe.ai`), an external service. It runs only when
  `TYPESAFE_API_KEY` is set and the optional `@prisma-labs/jev` package is installed. That package
  lives in a private repository, so a plain clone does not get it, and `pnpm -C health install`
  skips it. Without both, `context-lens health` prints one line saying classification is off and
  reports extraction only, like `--no-classify`.
- **The judge** (`context-lens health judge`) sends the weekly report, with quoted examples, to
  Claude through your own `claude` CLI.

Redaction catches common token shapes and long random strings, not every secret or every piece of
personal or company data. **On a company machine, check your employer's policy before enabling
either step.** `context-lens health --no-classify` is always safe to run.

## CLI

The same engine ships as a JSON CLI, which is useful for agents and scripts:

```bash
swift run context-lens resolve ~/code/my-app --harness claude
swift run context-lens stale ~/code
swift run context-lens sessions --limit 20 --cwd ~/code/my-app
swift run context-lens session ~/.codex/sessions/2026/10/01/rollout-....jsonl
context-lens presets
context-lens run lean claude          # in any folder, after "Install Command Line Tool"
context-lens plan careful codex .     # the flags and environment a launch would use
context-lens health --since 7d --no-classify   # friction across all sessions, local only
context-lens health judge             # sends the report to Claude; writes proposals to ~/.context-lens/health/proposals
context-lens skills --since 30d --cwd ~/code/my-app   # skills used and never used; --since all for everything
context-lens skills --session <transcript path or session id>   # skills one session used
```

## Develop

```bash
scripts/run.sh                                   # debug build, install to ~/Applications, launch
scripts/run.sh -directory ~/code/my-app -harness codex -latest-session -appearance light
scripts/check.sh                                 # tests + app build
```

The Xcode project is generated from `project.yml`; run `xcodegen generate` (the scripts do it).
`scripts/run.sh` and `scripts/install.sh` both sign with `scripts/sign.sh` and replace
`~/Applications/Context Lens.app`, so there is one app at one path and privacy grants stick.

## Layout

- `Sources/ContextLensCore`: resolvers (`ClaudeResolver`, `CodexResolver`), the session index and
  transcript parsers, and the stale-path checker.
- `Sources/context-lens`: the CLI.
- `App`: the SwiftUI app.
- `docs/harness-rules.md`: the loading rules each harness follows, and how they were verified.
- `docs/presets.md`: the switches presets use for each harness.
- `Sources/ContextLensCore/Health`, `health/` (Node, Jev) and `docs/health.md`: agent health.
- `Sources/ContextLensCore/Skills` and `App/SkillsView.swift`: skill use.
- `Sources/ContextLensCore/PrivacyGuard.swift`: the folders the app never walks into.

## License

MIT. See LICENSE.

# Agent health

`context-lens health` finds where agent sessions hit friction and which tools, guards and rule
files cause it. It is the first half of a loop: extract and classify here; a weekly judge turns the
aggregates into proposed edits for you to review; a Health view in the app shows both.

```bash
swift run -c release context-lens health --since 7d     # JSON report on stdout
context-lens health --since 24h --top 20
context-lens health --no-classify                        # extraction only, no network
pnpm -C health install && pnpm -C health eval             # Jev accuracy on the labeled cases
```

## What leaves the Mac

Extraction and aggregation run locally and send nothing anywhere. Two steps are optional and do
send data to outside services:

- **Classification** sends redacted, clipped excerpts of your transcripts (the failing command
  and its error, or your message and the agent's last words before it) to TypeSafe's API at
  `api.typesafe.ai`, an external service. It is off by default: it runs only when
  `TYPESAFE_API_KEY` is set and the optional `@prisma-labs/jev` package is installed (it comes
  from a private repo, so a plain clone does not get it). Without both, `context-lens health`
  prints one line saying classification is off and does extraction only, the same as
  `--no-classify`.
- **The judge** (`context-lens health judge`) sends the aggregated report, with quoted examples,
  to Claude through your own `claude` CLI, so it goes to Anthropic under your Claude Code account.
  It runs only when you call it or install the weekly schedule.

Redaction removes common token shapes and long random strings, but it cannot recognize every
secret or every piece of personal or company data. On a company machine, check your employer's
policy before you enable either step.

## What backpass taught

[backpass](https://github.com/kunchenguid/backpass) is right that the evidence for better
instructions sits in old transcripts, and several of its choices are worth keeping. Every claim
carries a verbatim quote checked against the transcript. A change to an always-loaded file needs
the same gap in two or more sessions. Answers are cached per transcript so re-runs are cheap.
Tool calls are distilled to one line each, with a pointer back to the raw file. Rejected
proposals are remembered. We keep the quotes, the corroboration count, the cache and the pointer
back to the session.

What made it hard to use is that every judgment is a model reading one session at a time. There
are no counts done in code: no tally of tool errors, retries, corrections or interruptions, so a
number is only as good as the model's reading of a 12k-token head-and-tail trace with tool output
cut to 200 characters, which drops the middle of the session where most failures are. Its output
is shaped as edits to one memory file, capped at five, so tool bugs, flaky commands and guard
walls are dropped or hidden, and there is no aggregate view: no ranked list of causes, no trend,
no per-tool rates, no link that opens the session. It also samples 100 sessions. Here, code
counts everything in every session, the cheap model only labels single events, aggregates come
before any judgment, and every group links to sessions that open in the app.

## Pipeline

**1. Extract (Swift, no model).** `HealthExtractor` reads every transcript modified in the window:
Claude Code (`~/.claude/projects/**/*.jsonl`, subagents included), Codex
(`~/.codex/sessions`, `archived_sessions`) and OpenClaw's Codex homes
(`~/.openclaw/agents/*/agent/codex-home/sessions`). OpenClaw's own `*.trajectory.jsonl` files
are not read yet; none were written in the last week on this Mac. Each line is checked with
`memmem` for a few markers and only matching lines are JSON-parsed; files run in parallel. On
2026-10-04 that was 839 files, 1.9 GB, in 2.2 s.

Per session it records model, active time (gaps over 5 minutes ignored), tool calls, input,
output, cache-read and cache-write tokens, the rule files the harness loaded (Claude's
`instructions` and `nested_memory` attachments, Codex's AGENTS.md markers) and the skills used.
Worktree copies of a rule file count as the repo's file. Events:

| Kind | Claude Code | Codex |
| --- | --- | --- |
| `tool_error` | `tool_result` with `is_error` | `Script failed`, non-zero `exit_code`, `Error:` output |
| `user_message` | typed text after the first prompt (not subagents, not injected `<…>` blocks) | user `message` items after the first |
| `interrupt` | `[Request interrupted…` | `turn_aborted` with `interrupted` |
| `api_error` | `system` / `api_error` | `error`, `stream_error` events |
| `question` | `AskUserQuestion` | `request_user_input` |

Each event names a `source`: the tool, or for shell calls the program (`Bash: gh`,
`exec: rg`, `~/bin/sim-lease`), skipping `cd`, `source` and env assignments. `repeats` counts
earlier failures of the identical call in the session, which marks a retry of a failing step.

**Redaction.** `Redactor` runs on every text field before it is written or sent: vendor token
shapes (`sk-`, `ghp_`, `xox*`, `AKIA`, …), JWTs, private keys, `Bearer …`, `KEY=value` and
`"password": …` pairs, credentials in URLs, and any 32+ character run of mixed letters and
digits. Text is clipped to 700 characters, keeping the head and the tail.

**2. Classify (Jev, optional).** `health/src/classify.ts` uses `@prisma-labs/jev` (`jev-1.13.0`),
an optional dependency, and needs `TYPESAFE_API_KEY` (see "What leaves the Mac"). All
questions are in `health/src/questions.ts`. A tool error gets one request with two questions:
the cause (`guard`, `permission`, `auth`, `misuse`, `environment`, `work`) and the cost (a
four-level score). A user message gets one question: `correction`, `repeat`, `frustration`,
`answer` or `request`. Friction is every label except `work`, `answer` and `request`.
Interrupts and API errors are friction without a call. One rule is code, not Jev: a non-zero
exit with no error words in the first or last 240 characters is `work`, because nothing in the
text says what failed (usually the last `grep` in a chain found nothing).

Identical states cost one call, and answers are cached in `~/.context-lens/health/jev-cache.jsonl`
by model, question version and state. A cold week was 1,237 calls, $0.056 and 21 s; a re-run
pays only for new events. Answers under p 0.6 are marked `escalate` and carry a ready-made
prompt for a stronger model (122 of 1,620 events in the first run); the weekly judge reads those.

**Accuracy.** `pnpm -C health eval` labels the cases in `health/evals` and needs the key. The
questions were tuned on hand-labeled real events from the author's transcripts. Those cannot be
published, so the committed cases are synthetic: each copies the shape of one real event (the
harness's guard and permission wording, zsh and tool errors, CI and test-runner output, user
corrections and requests) with invented paths, projects and messages, and keeps its label and
the per-label counts. `cases.jsonl` (82 events) is the tuning set, so its 96% is optimistic.
`holdout.jsonl` (37 events, never tuned against) is the honest number: 92% exact label (34/37),
92% on friction or not, 8% escalated, about $0.005 per run. The real holdout it replaced also
scored 92% (34/37, 95% on friction or not). Known weak spots, in both sets: corrections phrased
as suggestions, a file dump that ends in a shell error read as `work`, and test-runner JSON with
a failed status read as `environment`.

**3. Aggregate (Swift).** `HealthAggregator` groups friction events by cause. Guards, permission
walls, auth and API errors group by the first clause of their message, so one guard's many
wordings are one group. Agent mistakes and broken environments group by the line that names the
error, so `(eval):1: ===== not found` is one group whether `cat`, `sed` or `git` ran first.
Groups rank by summed cost. Each group lists its sources, its distinct failing lines, its top
sessions, retries, and one example with the failing line and a link (`claude://claude.ai/epitaxy/<desktop id>`
for Claude desktop sessions, `codex://threads/<id>` for Codex; CLI-only Claude sessions have no
link, the transcript path is in `file`). The report also has friction by tool, by skill and by
rule file (friction per session that loaded it: a correlation, not a cause), and by day.

## Output

Each run writes `~/.context-lens/health/runs/<time>/` with `events.jsonl`, `sessions.jsonl`,
`labels.jsonl` and `report.json`, and updates `~/.context-lens/health/report.json` and
`~/.context-lens/health/latest.json`, a one-line summary for status bars and dashboards:

```json
{"cacheReadShare":0.982,"escalated":122,"friction":1010,"generated":"…","perSession":1.24,"report":"…/report.json","sessions":813,"since":"…","top":"guard: This session is isolated in the worktree …","topEvents":175}
```

Events stay on this Mac except the redacted, clipped state sent to Jev when classification is on.

## Judge (weekly, Opus 5.5)

`context-lens health judge` builds one input from the latest run: the top 25 groups with their
examples, the tool, skill and rule-file rows, up to 40 user corrections with the agent's words
before them, up to 30 escalated events, and every existing proposal with its status, its count
when it was decided and its count this week. It sends that with `health/judge.md` to
`claude -p --model claude-opus-5-5 --allowedTools Read,Grep,Glob`: the judge may read rule files
to check what they say but cannot edit anything. Its answer must be a JSON array of at most 8
proposals; the command validates it and writes each new one to
`~/.context-lens/health/proposals/<date>-<slug>.json` with status `open`. `--dry-run` prints the
prompt; an unparseable answer is kept as `judge-output.txt` in the run folder.

A proposal names one target file or setting, the exact edit, the report group it addresses, its
event and session counts, and verbatim quotes with session links. You (or an agent you
delegate to) apply or brief it and set the status; changing it records the group's count at that moment
(`baselineEvents`), so the next week's report and judge show whether the fix worked:

```bash
context-lens health proposals
context-lens health status 2026-10-04-zsh-separators applied --note "global rules"
```

`scripts/install-health-schedule.sh` installs a LaunchAgent that runs `context-lens health --since
7d` and then the judge every Monday at 08:00, logging to `~/.context-lens/health/schedule.log`.
It runs through a login shell (`zsh -lc`), so it classifies only if your login profile exports
`TYPESAFE_API_KEY`. Installing the schedule means the judge sends the weekly report to Claude.

The classifier and `judge.md` live in `health/` of a source checkout. The CLI looks for them next
to the sources it was built from; a Homebrew install built elsewhere needs
`CONTEXT_LENS_HEALTH_DIR=<checkout>/health`. The schedule script sets that for its job.

## Health view

The app's Agent Health window (⌘⇧H, or Agent Health in the menu bar menu) reads the same files.
Left: friction per day, proposals (open first), causes ranked by cost, then tools, skills and rule
files. Right: the selection. A cause shows its counts, related proposals, the example's failing
line, command and output, its distinct failing lines, the programs that tripped it, and the
sessions with the most events, each with Open (`claude://` or `codex://`) or Reveal (the
transcript, for CLI-only sessions). A proposal shows the edit, the evidence, its count then and
now, and a status menu. `scripts/run.sh -health -health-select <cause prefix>` opens it on a cause.

## Limits

- Codex `exec` scripts run several commands; the exit code belongs to the last one but the
  source names the first. Grouping by the failing line works around it.
- Skill and rule-file rows are correlations: repos with hard work load more rules.

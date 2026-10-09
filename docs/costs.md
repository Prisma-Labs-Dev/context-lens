# Costs

The Costs window (⇧⌘U, or Costs in the menu bar menu) and `context-lens cost` show what Claude
Code sessions cost at Anthropic list price, from the usage each transcript records. Nothing is
sent anywhere; no model is called.

```bash
context-lens cost --since 7d --brief      # plain text: totals, groups, models, top sessions, drivers
context-lens cost --since today           # the full report as JSON
context-lens cost --since all --until 2026-10-07
context-lens cost --reconcile --since 7d  # computed cost against Claude Code's own total, per session
```

## What it reads

- **Claude Code transcripts** (`~/.claude/projects/**/*.jsonl`). Every assistant message carries
  the API's `usage`: `input_tokens`, `output_tokens` (thinking included, also given as
  `output_tokens_details.thinking_tokens`), `cache_read_input_tokens`,
  `cache_creation_input_tokens` split into `cache_creation.ephemeral_5m_input_tokens` and
  `ephemeral_1h_input_tokens`, `speed` (fast mode) and `server_tool_use.web_search_requests`.
  Claude Code writes one line per content block with the same message ID; output grows across
  them, so a call keeps its largest count. A resumed or forked session copies earlier lines into
  its own file with the original `sessionId`; those calls count once.
- **Claude Code's own total**: `cost-state` lines (`totalCostUSD`, the number `/cost` and
  `claude -p --output-format json` report as `total_cost_usd`). Used only to reconcile.
- **Subagents**: `<session>/subagents/agent-*.jsonl`, with `agent-*.meta.json` for the type.
- **Copilot CLI**: `~/.copilot/session-state/*/events.jsonl`. `totalNanoAiu` in the last
  `session.usage_checkpoint` divided by 1e9 is the "AI Credits" figure the CLI prints at exit.

Results are cached per file in `~/.context-lens/costs/scan-cache.json`, keyed by size and
modification time.

## Prices

One table, `Sources/ContextLensCore/Costs/Pricing.swift`, from
<https://platform.claude.com/docs/en/about-claude/pricing>, read 2026-10-09. Cache writes cost
1.25x base input (5 minutes) or 2x (1 hour); cache reads 0.1x, except 0.05x on Opus 5.5 and
Sonnet 5.5 and 0.025x on Fable 5.1. Fast mode replaces base input and output and keeps the cache
multipliers. Web search is $10 per 1,000. A model the table does not know is counted in tokens
and reported as unpriced, never priced as its predecessor.

These are list prices. A gateway or cloud platform may bill differently (US-only inference is
1.1x; negotiated discounts are not visible in transcripts).

Checked: three `claude -p` runs (one with a subagent) matched `total_cost_usd` to the
micro-dollar. Across 108 sessions with a `cost-state` total, the computed sum was 1% below
Claude Code's (median per session -0.2%): Claude Code also bills calls the transcript does not
record, and restarts its total when a session is resumed.

## Groups

Sessions are grouped by how they started: desktop threads (`claude-desktop*` entrypoints),
terminal sessions (`cli`), headless runs (`sdk-*`, which is `claude -p`), background jobs (a
folder for the session under `~/.claude/jobs`), subagents and Copilot CLI. Name your own groups in
`~/.context-lens/cost-groups.json`; the first matching rule wins:

```json
{"groups": [
  {"name": "Lead", "title": "Lead"},
  {"name": "Reviews", "titlePrefix": "Review "},
  {"name": "App work", "cwdPrefix": "~/code/app"}
]}
```

## Drivers

- **Calls over 300k tokens**: every call re-reads the whole context, so what calls above 300k
  cost is what a fresh session or `/compact` there would have cut.
- **Cold restarts**: a call after a gap longer than 5 minutes that read less than half of the
  previous call's context from cache. The extra is the rewritten tokens at the write price minus
  the read price. The 1-hour TTL estimate prices every 5-minute write at the 1-hour price and
  turns each cold restart after a 5 to 60 minute gap into a read.
- **Cache reads, cache writes, output, subagents**: their share of the total.

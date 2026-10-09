# Costs

The Costs window (⇧⌘U, or Costs in the menu bar menu) and `context-lens cost` show what Claude
Code sessions cost at Anthropic list price, from the usage each transcript records, sliced by
model, harness and route (the budget a call drew from). No model is called. The only network
requests are read-only GETs to the gateway's usage API, for routes that have auth set up.

Every dollar computed from transcripts is an estimate and is labelled "est.": list price for
Claude calls, $0.01 per Copilot AI credit. Only the gateway's "billed" figures are not estimates.

```bash
context-lens cost --since 7d --brief      # plain text: totals, groups, models, top sessions, drivers
context-lens cost --since today           # the full report as JSON
context-lens cost --since all --until 2026-10-07
context-lens cost --reconcile --since 7d  # computed cost against Claude Code's own total, per session
context-lens cost --since today --by route          # per budget, plus what each gateway billed this month
context-lens cost --since 7d --by model,harness     # any combination of model, harness, route
context-lens cost --by route --json --no-gateway    # JSON, without asking the usage API
```

## Slices

In the window, Slices has a toggle per dimension. Turn on several to combine them; the number on
a toggle is its position in the grouping. `--by` takes the same names, in the order to group by.

- **Model**: the model ID without its date or `[1m]` suffix. Copilot's dotted Claude IDs
  (`claude-opus-5.5`) read as Anthropic's.
- **Harness**: Claude Code CLI (interactive terminal, entrypoint `cli`), Desktop Code tab
  (`claude-desktop*`), Headless (`claude -p`, entrypoints `sdk-*`), Background (`claude --bg`: a
  folder for the session under `~/.claude/jobs`, whatever its entrypoint), Subagents and
  Copilot CLI.
- **Route**: see below.

## Routes

Transcripts do not record which credentials a call used, so a call's route is the one in effect
when it was made. `~/.context-lens/auth-windows.json` lists the routes and, per scope, the time
each one took over. `cli` covers the terminal CLI and everything it starts (headless runs,
background jobs, their subagents); `desktop` the desktop app's Code tab and its subagents; `all`
both. A window lasts until the next window for the same scope.

```json
{"usageURL": "https://gateway.example/usage/anthropic/",
 "routes": [
   {"id": "entra", "label": "Entra ID", "auth": {"kind": "entra", "resource": "api://<app id>", "tenant": "<tenant id>"}},
   {"id": "team", "label": "Team key", "auth": {"kind": "apiKey", "header": "api-key", "keyFile": "~/.config/keys/team.key"}},
   {"id": "other", "label": "Other key"}
 ],
 "windows": [
   {"start": "2026-09-01T09:00:00+02:00", "scope": "all", "route": "entra"},
   {"start": "2026-10-01T10:20:00+02:00", "scope": "cli", "route": "team", "note": "settings.json switched"}
 ]}
```

Two routes need no window: the desktop app signed in to claude.ai (entrypoint `claude-desktop`,
without `-3p`) is "claude.ai account", and Copilot CLI is "Copilot seat". A call no window covers
is "Unknown route".

To fill the file, date each switch from what changed: the mtime of `~/.claude/settings.json`
(`apiKeyHelper`, `ANTHROPIC_CUSTOM_HEADERS`) and, for the desktop app, of
`~/Library/Application Support/Claude-3p/configLibrary/_meta.json` (`appliedId` names the active
profile). A settings file's mtime is its last edit, not necessarily the switch, so check the
`note`s against backups. The window and `--by route` warn when an install is set up for a
different route than the window in effect now: Entra when the credential helper runs
`az account get-access-token`, a key route when the configured `api-key` header and the route's
`keyFile` have the same SHA-256. Keys are compared by hash only; none is stored, cached or
printed.

### Gateway figures

For every route with `auth`, the window's Budgets section and `--by route` ask
`<usageURL>?month=YYYY-MM` (UTC month) for `{subscription_id, month, cost_usd, tier,
monthly_limit_usd}`. Entra routes send `Authorization: Bearer` with a token from
`az account get-access-token --resource <resource> --tenant <tenant>`; key routes read
`keyFile` at request time and send it in `header`. Shown per route: billed this month, limit,
what is left, the list-price estimate of the month's calls on the route, and gateway over list.
If the ratio drifts far from 1, either the gateway prices differently or the windows are wrong.

The usage API counts everything billed to the subscription, including use from other machines or
tools; the estimate counts only transcripts on this Mac.

## Copilot credits in dollars

Copilot CLI records AI credits (`totalNanoAiu` / 1e9). GitHub prices one AI credit at $0.01 USD
for usage beyond a plan's included credits
(<https://docs.github.com/copilot/concepts/billing/usage-based-billing-for-organizations-and-enterprises>,
read 2026-10-09; Business includes 1,900 credits per user a month, Enterprise 3,900). The cost
view multiplies credits by $0.01 and labels the result "est.": included credits cost the seat,
not extra money, so this is what the usage would cost at the overage price. A credit step is
attributed to the model of the last call before it.

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

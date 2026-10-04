# Context Lens agent guide

Read README.md. The loading rules each harness follows are in docs/harness-rules.md, and they are
facts verified against real transcripts. When a harness release changes them, re-run the check
in that doc and update the doc, the resolver and the tests together.

- `swift test` covers the engine. `scripts/check.sh` also builds the app.
- `scripts/run.sh` relaunches the app. Pass `-directory <path>`, `-harness claude|codex`,
  `-latest-session`, `-preset <id>` and `-appearance light|dark` to open a specific view, which helps when
  checking the UI with computer use (the source picker is a pop-up menu, which background
  computer use cannot open).
- Presets must never write to files the harnesses read normally. Generated settings go under
  `~/.context-lens/generated/`; docs/presets.md lists every switch and how it was verified.
- UI direction: an IDE, not a web page. Neutral panels, compact single-line rows, system font,
  monospace for content, color only for meaning (harness, kind, stale, changed).
- The Xcode project is generated from `project.yml`; do not commit `ContextLens.xcodeproj`.
- Protect prompt caches. Nothing may change the start of a running or resumed session without
  a warning first that names the cost. docs/harness-rules.md ("Prompt cache") has what each
  harness does today.
- Agent health (docs/health.md): every Jev question lives in `health/src/questions.ts`. After
  changing one, bump `VERSION` and run `pnpm -C health eval`; report the holdout number, which
  was never tuned against. Redact before anything leaves the Mac.
- This repo is public. Never commit real transcript text, personal paths, account IDs or private
  repo names: eval cases in `health/evals` are synthetic, and tests use `/Users/me` and invented
  projects.
- Keep transcript reading fast. The session list reads only the head and tail of each file;
  full parses happen only for the selected session.

import ContextLensCore
import Foundation

let usage = """
context-lens: show what Claude Code and Codex put into their context. Output is JSON.

Usage:
  context-lens resolve [<dir>] [--harness claude|codex]   Context predicted from files on disk (default: cwd, both harnesses)
  context-lens sessions [--limit N] [--harness claude|codex] [--cwd <dir>]
                                                          Recorded sessions, newest first (default limit 50)
  context-lens session <transcript.jsonl>                 Context recorded in one session transcript
  context-lens stale [<dir>]                              Only items that mention paths that no longer exist
  context-lens presets                                    Presets: built-in Clean install and On disk, plus ~/.context-lens/presets/*.json
  context-lens plan <preset> <claude|codex> [<dir>]       Environment and arguments a preset launch would use
  context-lens run <preset> <claude|codex> [args...]      Start the harness in the current directory under a preset.
                                                          Runs through your interactive shell, so aliases and functions apply.
  context-lens health [--since 7d] [--top N] [--no-classify]
                                                          Friction across Claude Code, Codex and OpenClaw sessions: tool errors,
                                                          retries, walls, corrections. Labels events with Jev and writes
                                                          ~/.context-lens/health/ (see docs/health.md)
  context-lens health judge [--model claude-opus-5-5] [--dry-run]
                                                          Weekly pass: Opus reads the latest report and writes proposals
                                                          to ~/.context-lens/health/proposals/
  context-lens health proposals                           Proposals, newest first
  context-lens health status <id> <open|applied|briefed|rejected> [--note text]
  context-lens skills [--since 30d|all] [--cwd <dir>]   Skills sessions used (Skill tool, slash command, subagent, SKILL.md read)
                                                          across Claude Code, Codex and Copilot CLI, and installed skills none
                                                          used. Cached in ~/.context-lens/skills/
  context-lens skills --session <transcript|id>          The skills one session used, in order of first use
  context-lens cost [--since today|24h|7d|30d|all] [--until YYYY-MM-DD] [--brief] [--top N]
                                                          What Claude Code sessions cost at Anthropic list price (default 7d), by
                                                          group, model and session, with cache hit ratio and cost drivers; Copilot
                                                          CLI sessions in AI credits. --brief: plain text. Groups come from
                                                          ~/.context-lens/cost-groups.json (docs/costs.md). Cached in ~/.context-lens/costs/
  context-lens cost --reconcile [--since 7d]              Computed cost against Claude Code's own running total, per session
  context-lens cost --by model,harness,route [--since today] [--json] [--no-gateway]
                                                          Spend sliced by any combination (est.). With route: what each budget's
                                                          gateway billed this month against the list-price estimate. Routes come
                                                          from time windows in ~/.context-lens/auth-windows.json (docs/costs.md)
  context-lens growth <transcript|id> [--all]           Claude Code: the first call's measured context against the transcript's
                                                          estimate, compactions, and the calls where the context grew most
                                                          (--all: every call)
  context-lens measure [<dir>] [--cached|--history]       Claude Code: run claude -p "/context" in a folder for the real token
                                                          counts, MCP tool schemas per server included. Kept as history in
                                                          ~/.context-lens/context/, with /context runs found in transcripts
                                                          (--cached: the latest, without running; --history: all of them)
  context-lens mcp list [<dir>] [--harness claude|codex]
                                                          MCP servers and plugins with MCP tools, their on/off state per scope
                                                          (everywhere, project settings, here) and measured token cost
  context-lens mcp enable|disable <name> [--scope folder|user] [--dry-run] [<dir>]
                                                          Switch a server or plugin in the harness's own settings: folder
                                                          (default) writes the project's local settings, user writes your
                                                          user settings. Backs up to ~/.context-lens/backups/
  context-lens mcp undo                                   Revert the last switch
  context-lens --help

Options:
  --preset <id>   With resolve: show the context as that preset would load it
"""

struct Options {
    var positional: [String] = []
    var flags: [String: String] = [:]

    init(_ args: ArraySlice<String>) {
        var it = args.makeIterator()
        while let a = it.next() {
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if key == "help" || key == "all" || key == "cached" || key == "history" || key == "json" || key == "no-classify" || key == "dry-run" || key == "brief" || key == "reconcile" || key == "no-gateway" { flags[key] = "true" } else { flags[key] = it.next() ?? "" }
            } else {
                positional.append(a)
            }
        }
    }
}

struct ItemOut: Encodable {
    var kind: String, title: String, scope: String, path: String?, load: String
    var tokens: Int, startingTokens: Int, note: String?, issues: [String], diskStatus: String?, presetOff: String?
    init(_ i: ContextItem) {
        kind = i.kind.rawValue; title = i.title; scope = i.scope; path = i.path; load = i.load.rawValue
        tokens = i.tokens; startingTokens = i.startingTokens; note = i.note
        issues = i.issues.map(\.message); diskStatus = i.diskStatus?.rawValue; presetOff = i.presetOff
    }
}

struct SnapshotOut: Encodable {
    var harness: String, cwd: String, startingTokens: Int, issueCount: Int, notes: [String], items: [ItemOut]
    init(_ s: ContextSnapshot, onlyIssues: Bool = false) {
        harness = s.harness.rawValue; cwd = s.cwd; startingTokens = s.startingTokens; issueCount = s.issueCount
        notes = s.notes
        items = s.items.filter { !onlyIssues || !$0.issues.isEmpty }.map(ItemOut.init)
    }
}

struct SessionOut: Encodable {
    var id: String, harness: String, title: String, cwd: String, date: Date, sizeBytes: Int, file: String
    init(_ s: SessionSummary) {
        id = s.id; harness = s.harness.rawValue; title = s.title; cwd = s.cwd; date = s.date; sizeBytes = s.sizeBytes; file = s.file.path
    }
}

func emit<T: Encodable>(_ value: T) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    FileHandle.standardOutput.write(try! enc.encode(value))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

struct PlanOut: Encodable {
    var preset: String, harness: String, cwd: String, env: [String: String], args: [String], command: String, notes: [String]
}

/// Replaces this process with the user's interactive shell running the harness, so the
/// user's `claude` / `codex` aliases and functions still apply.
func execHarness(_ plan: LaunchPlan, extra: [String]) -> Never {
    for (k, v) in plan.env { setenv(k, v, 1) }
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let argv = [shell, "-i", "-c", "\(plan.harness.command) \"$@\"", plan.harness.command] + plan.arguments(extra: extra)
    let cargs = argv.map { strdup($0) } + [nil]
    execv(shell, cargs)
    fail("could not start \(shell): \(String(cString: strerror(errno)))")
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first, command != "--help", command != "-h", command != "help" else {
    print(usage)
    exit(0)
}
func presetNamed(_ id: String) -> Preset {
    guard let p = PresetStore().preset(id: id) else {
        fail("unknown preset \(id); known: \(PresetStore().all().map(\.id).joined(separator: ", "))")
    }
    return p
}

if command == "run" {
    let rest = Array(args.dropFirst())
    guard rest.count >= 2, let h = Harness(rawValue: rest[1]) else { fail("run needs <preset> <claude|codex> [harness args...]") }
    let preset = presetNamed(rest[0])
    let cwd = URL(filePath: FileManager.default.currentDirectoryPath)
    do {
        let plan = try PresetLauncher().plan(preset, harness: h, cwd: cwd)
        FileHandle.standardError.write(Data("context-lens: \(h.displayName) with preset \(preset.name)\n".utf8))
        LaunchLog().record(preset, harness: h, cwd: cwd)
        plan.markInUse(pid: getpid())
        execHarness(plan, extra: Array(rest.dropFirst(2)))
    } catch {
        fail("could not prepare \(preset.id): \(error)")
    }
}
let opts = Options(args.dropFirst())
if opts.flags["help"] != nil { print(usage); exit(0) }
var harnesses = Harness.allCases
if let name = opts.flags["harness"] {
    guard let h = Harness(rawValue: name) else { fail("unknown harness \(name)") }
    harnesses = [h]
}
let dir = URL(filePath: opts.positional.first ?? FileManager.default.currentDirectoryPath).standardizedFileURL

func snapshot(_ h: Harness, _ dir: URL) -> ContextSnapshot {
    switch h {
    case .claude: ClaudeResolver().resolve(cwd: dir)
    case .codex: CodexResolver().resolve(cwd: dir)
    }
}

switch command {
case "resolve":
    if let id = opts.flags["preset"] {
        let preset = presetNamed(id)
        emit(harnesses.map { SnapshotOut(PresetApplier.apply(preset, to: snapshot($0, dir))) })
    } else {
        emit(harnesses.map { SnapshotOut(snapshot($0, dir)) })
    }
case "presets":
    emit(PresetStore().all())
case "plan":
    guard opts.positional.count >= 2, let h = Harness(rawValue: opts.positional[1]) else { fail("plan needs <preset> <claude|codex> [<dir>]") }
    let preset = presetNamed(opts.positional[0])
    let cwd = URL(filePath: opts.positional.count > 2 ? opts.positional[2] : FileManager.default.currentDirectoryPath).resolvingSymlinksInPath()
    do {
        let plan = try PresetLauncher().plan(preset, harness: h, cwd: cwd)
        emit(PlanOut(preset: preset.id, harness: h.rawValue, cwd: cwd.path, env: plan.env, args: plan.args, command: plan.commandLine(cwd: cwd.path), notes: plan.notes))
    } catch {
        fail("could not prepare \(preset.id): \(error)")
    }
case "stale":
    emit(harnesses.map { SnapshotOut(snapshot($0, dir), onlyIssues: true) })
case "sessions":
    let limit = Int(opts.flags["limit"] ?? "50") ?? 50
    let index = SessionIndex()
    var sessions = harnesses.flatMap { $0 == .claude ? index.claudeSessions() : index.codexSessions() }
    if let cwd = opts.flags["cwd"] {
        let target = URL(filePath: cwd).standardizedFileURL.path
        sessions = sessions.filter { $0.cwd == target }
    }
    emit(sessions.sorted { $0.date > $1.date }.prefix(limit).map(SessionOut.init))
case "session":
    guard let path = opts.positional.first else { fail("session needs a transcript path") }
    let file = URL(filePath: path)
    let summary = file.path.contains("/.codex/")
        ? SessionIndex().codexSummary(file, names: [:])
        : SessionIndex().claudeSummary(file)
    guard let summary else { fail("could not read \(path)") }
    let snap = summary.harness == .claude ? ClaudeSessionParser().parse(summary) : CodexSessionParser().parse(summary)
    emit(SnapshotOut(snap))
case "health":
    runHealth(opts)
case "skills":
    runSkills(opts)
case "growth":
    runGrowth(opts)
case "cost":
    runCost(opts)
case "mcp":
    runMcp(opts)
case "measure":
    let store = MeasuredContextStore()
    if opts.flags["history"] != nil {
        store.harvest(around: dir.path)
        emit(store.history(dir.path).map(MeasuredOut.init))
    } else if opts.flags["cached"] != nil {
        store.harvest(around: dir.path)
        guard let m = store.cached(dir.path) else { fail("no measurement of \(dir.path)") }
        emit(MeasuredOut(m))
    } else {
        do { emit(MeasuredOut(try store.measure(dir.path))) } catch { fail("\(error)") }
    }
default:
    fail("unknown command \(command)")
}

struct MeasuredOut: Encodable {
    var measured: MeasuredContext
    /// Harness prompt, built-in tools and MCP tool schemas: what no file shows.
    var notInFiles: Int
    var mcpServers: [MeasuredContext.Row]
    /// The same segments the app's bar shows.
    var attribution: ContextAttribution

    init(_ m: MeasuredContext) {
        measured = m; notInFiles = m.notInFiles; mcpServers = m.mcpServers; attribution = .measured(m)
    }
}

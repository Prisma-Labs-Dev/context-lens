import ContextLensCore
import Foundation

/// `context-lens health judge`: the weekly pass. Opus 5.5 reads the latest report, the worst
/// examples, the escalated events and the existing proposals, and returns proposals as JSON. It
/// runs headless with read-only tools; this command validates its answer and writes
/// `~/.context-lens/health/proposals/<id>.json`. Prompt: health/judge.md.
func runJudge(_ opts: Options) {
    let store = HealthStore()
    guard let report = store.report(), let run = store.latestRun() else { fail("no report yet; run context-lens health first") }
    let sessions = store.sessions(in: run)
    let model = opts.flags["model"] ?? "claude-opus-5-5"
    guard let instructions = try? String(contentsOf: classifierDir().appending(path: "judge.md"), encoding: .utf8) else {
        fail("missing \(classifierDir().appending(path: "judge.md").path)")
    }
    let input = judgeInput(report, run: run, store: store, sessions: sessions)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let prompt = instructions.replacingOccurrences(of: "{{HOME}}", with: home) + "\n\nInput:\n\n```json\n" + input + "\n```\n"
    if opts.flags["dry-run"] != nil {
        print(prompt)
        return
    }
    healthLog("judge: asking \(model) (\(prompt.count / 4) tokens of input)")
    let started = Date()
    let output = runClaude(prompt: prompt, model: model)
    let items = parseJudge(output)
    guard let items else {
        try? output.write(to: run.appending(path: "judge-output.txt"), atomically: true, encoding: .utf8)
        fail("the judge did not return a JSON array; its output is in \(run.path)/judge-output.txt")
    }
    let existing = Set(store.proposals().map(\.id))
    var written: [HealthProposal] = []
    for item in items {
        let p = HealthProposal(
            id: HealthStore.proposalID(item.title), created: Date(), title: item.title, target: item.target,
            kind: item.kind, status: .open, summary: item.summary, edit: item.edit, group: item.group,
            events: item.events ?? 0, sessions: item.sessions ?? 0,
            quotes: (item.quotes ?? []).map { .init(session: $0.session, link: sessions[$0.session]?.link, text: Redactor.clip($0.text, 500)) },
            author: "judge \(model)"
        )
        guard !existing.contains(p.id) else { continue }
        do {
            try store.save(p)
            written.append(p)
        } catch {
            healthLog("judge: could not save \(p.id): \(error)")
        }
    }
    healthLog("judge: \(items.count) proposals, \(written.count) new, in \(Int(Date().timeIntervalSince(started))) s")
    emit(written)
}

struct JudgeItem: Decodable {
    struct Quote: Decodable { var session: String; var text: String }
    var title: String, target: String, kind: String, summary: String, edit: String
    var group: String?, events: Int?, sessions: Int?, quotes: [Quote]?
}

func parseJudge(_ output: String) -> [JudgeItem]? {
    guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]"), start < end else { return nil }
    return try? JSONDecoder().decode([JudgeItem].self, from: Data(output[start...end].utf8))
}

/// What the judge reads: the ranked groups with examples, the per-tool, skill and rule-file rows,
/// user corrections, escalated events and the existing proposals. All of it is already redacted.
func judgeInput(_ r: HealthReport, run: URL, store: HealthStore, sessions: [String: HealthSession]) -> String {
    let labels = Dictionary(store.labels(in: run).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let events = store.events(in: run)
    func clip(_ s: String?, _ n: Int) -> String? { s.map { $0.count > n ? String($0.prefix(n)) + "…" : $0 } }
    let groups: [[String: Any]] = r.groups.prefix(25).map { g in
        [
            "group": g.name, "label": g.label, "events": g.events, "sessions": g.sessions, "retries": g.retries,
            "cost": g.severity, "sources": g.sources, "variants": g.variants,
            "example": [
                "session": g.example.session, "title": clip(g.example.title, 100) ?? "", "line": clip(g.example.line, 300) ?? "",
                "command": clip(g.example.input, 300) ?? "", "text": clip(g.example.text, 500) ?? "",
            ],
        ]
    }
    let user: [[String: Any]] = events.filter { e in
        e.kind == .userMessage && ["correction", "repeat", "frustration"].contains(labels[e.id]?.label ?? "")
    }.prefix(40).map { e in
        ["session": e.session, "label": labels[e.id]?.label ?? "", "user": clip(e.text, 400) ?? "", "agent_before": clip(e.context, 250) ?? ""]
    }
    let escalated: [[String: Any]] = events.filter { labels[$0.id]?.escalate == true }.prefix(30).map { e in
        ["session": e.session, "kind": e.kind.rawValue, "jev_guess": labels[e.id]?.label ?? "", "p": labels[e.id]?.p ?? 0,
         "command": clip(e.input, 200) ?? "", "text": clip(e.text, 300) ?? ""]
    }
    func rows(_ rs: [FrictionRow]) -> [[String: Any]] {
        rs.prefix(15).map { ["name": $0.name, "sessions": $0.sessions, "friction": $0.friction, "perSession": $0.perSession, "labels": $0.labels] }
    }
    let proposals: [[String: Any]] = store.proposals().map { p in
        var d: [String: Any] = ["id": p.id, "title": p.title, "target": p.target, "status": p.status.rawValue,
                                "events": p.events, "group": p.group ?? ""]
        if let b = p.baselineEvents { d["baselineEvents"] = b }
        if let g = p.group { d["eventsThisWeek"] = r.groups.first { $0.name == g }?.events ?? 0 }
        return d
    }
    let f = ISO8601DateFormatter()
    let input: [String: Any] = [
        "period": ["since": f.string(from: r.since), "until": f.string(from: r.generated)],
        "sessions": r.sessions, "harnesses": r.harnesses, "friction": r.friction, "totals": r.totals,
        "groups": groups, "byTool": rows(r.byTool), "bySkill": rows(r.bySkill), "byRuleFile": rows(r.byRuleFile),
        "byDay": r.byDay.map { ["day": $0.day, "sessions": $0.sessions, "friction": $0.friction] },
        "userFriction": user, "escalated": escalated, "proposals": proposals,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

/// Runs `claude -p` through a login shell, so it finds `claude` from launchd too. Read-only tools.
func runClaude(prompt: String, model: String) -> String {
    let p = Process()
    p.executableURL = URL(filePath: "/bin/zsh")
    p.arguments = ["-lc", "claude -p --model \"$1\" --allowedTools Read,Grep,Glob --output-format text", "judge", model]
    var env = ProcessInfo.processInfo.environment
    for key in ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SESSION_ID"] { env.removeValue(forKey: key) }
    p.environment = env
    p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    let input = Pipe(), output = Pipe()
    p.standardInput = input
    p.standardOutput = output
    do { try p.run() } catch { fail("could not start claude: \(error)") }
    input.fileHandleForWriting.write(Data(prompt.utf8))
    try? input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    if p.terminationStatus != 0 { fail("claude exited with \(p.terminationStatus)") }
    return String(decoding: data, as: UTF8.self)
}

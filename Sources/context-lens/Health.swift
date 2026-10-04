import ContextLensCore
import Foundation

/// `context-lens health`: extract events (Swift), label them with Jev (the Node classifier in
/// `health/`), aggregate, and write `~/.context-lens/health/`. See docs/health.md.
func runHealth(_ opts: Options) {
    switch opts.positional.first {
    case "judge": return runJudge(opts)
    case "proposals": return emit(HealthStore().proposals())
    case "status":
        let p = opts.positional
        guard p.count >= 3, let status = HealthProposal.Status(rawValue: p[2]) else {
            fail("status needs <proposal-id> <open|applied|briefed|rejected> [--note text]")
        }
        do { emit(try HealthStore().setStatus(p[1], status, note: opts.flags["note"])) } catch { fail("\(error.localizedDescription)") }
        return
    case nil: break
    case let other?: fail("unknown health command \(other)")
    }
    guard let age = parseAge(opts.flags["since"] ?? "7d") else { fail("--since takes 24h, 7d or 2w") }
    let since = Date().addingTimeInterval(-age)
    let top = Int(opts.flags["top"] ?? "10") ?? 10
    let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".context-lens/health")
    let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate, .withTime, .withColonSeparatorInTime])
        .replacingOccurrences(of: ":", with: "")
    let run = root.appending(path: "runs/\(stamp)")
    try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)

    let extract = HealthExtractor().extract(since: since)
    healthLog("extracted \(extract.events.count) events from \(extract.sessions.count) sessions (\(extract.files) files, \(extract.bytes / 1_000_000) MB) in \(String(format: "%.1f", extract.seconds)) s")
    let eventsFile = run.appending(path: "events.jsonl")
    writeJSONLines(extract.events, to: eventsFile)
    writeJSONLines(extract.sessions, to: run.appending(path: "sessions.jsonl"))

    var labels: [HealthLabel] = []
    if opts.flags["no-classify"] == nil, classifierReady() {
        let labelsFile = run.appending(path: "labels.jsonl")
        classify(events: eventsFile, labels: labelsFile, root: root)
        labels = readLines(labelsFile)
    }
    let report = HealthAggregator.report(extract, labels: labels, top: top)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    try? enc.encode(report).write(to: run.appending(path: "report.json"))
    try? enc.encode(report).write(to: root.appending(path: "report.json"))
    writeLatest(report, run: run, root: root)
    emit(report)
}

func parseAge(_ s: String) -> TimeInterval? {
    guard let unit = s.last, let n = Double(s.dropLast()) else { return nil }
    switch unit {
    case "h": return n * 3600
    case "d": return n * 86400
    case "w": return n * 7 * 86400
    default: return nil
    }
}

func healthLog(_ message: String) {
    FileHandle.standardError.write(Data("context-lens health: \(message)\n".utf8))
}

func writeJSONLines<T: Encodable>(_ items: [T], to url: URL) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    var data = Data()
    for item in items {
        data.append(try! enc.encode(item))
        data.append(0x0A)
    }
    try? data.write(to: url)
}

func readLines<T: Decodable>(_ url: URL) -> [T] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let dec = JSONDecoder()
    return data.split(separator: 0x0A).compactMap { try? dec.decode(T.self, from: $0) }
}

/// The classifier is a Node script next to the sources; `CONTEXT_LENS_HEALTH_DIR` overrides it.
/// A build from a worktree points at the main checkout, since the worktree goes away.
func classifierDir() -> URL {
    if let dir = ProcessInfo.processInfo.environment["CONTEXT_LENS_HEALTH_DIR"] { return URL(filePath: dir) }
    let repo = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let main = URL(filePath: repo.path.replacingOccurrences(of: #"/\.claude/worktrees/[^/]+$"#, with: "", options: .regularExpression))
    return main.appending(path: "health")
}

/// Classifying sends redacted excerpts to TypeSafe's API, so it is off unless the key is set and
/// the optional Jev package is installed. Otherwise the run is extraction only, as with --no-classify.
func classifierReady() -> Bool {
    let dir = classifierDir()
    if (ProcessInfo.processInfo.environment["TYPESAFE_API_KEY"] ?? "").isEmpty {
        healthLog("classification off: TYPESAFE_API_KEY is not set (extraction only, nothing leaves this Mac)")
        return false
    }
    if !FileManager.default.fileExists(atPath: dir.appending(path: "node_modules/@prisma-labs/jev").path) {
        healthLog("classification off: @prisma-labs/jev is not installed in \(dir.path) (extraction only)")
        return false
    }
    return true
}

func classify(events: URL, labels: URL, root: URL) {
    let dir = classifierDir()
    let p = Process()
    p.executableURL = URL(filePath: "/usr/bin/env")
    p.arguments = ["node", dir.appending(path: "src/classify.ts").path, events.path, labels.path, root.appending(path: "jev-cache.jsonl").path]
    p.currentDirectoryURL = dir
    do {
        try p.run()
        p.waitUntilExit()
    } catch {
        fail("could not start node: \(error)")
    }
    if p.terminationStatus != 0 { fail("classifier exited with \(p.terminationStatus)") }
}

/// One summary line for status bars and dashboards.
func writeLatest(_ r: HealthReport, run: URL, root: URL) {
    struct Latest: Encodable {
        var generated: Date, since: Date, sessions: Int, friction: Int, perSession: Double, escalated: Int
        var cacheReadShare: Double, top: String?, topEvents: Int?, report: String
    }
    let latest = Latest(
        generated: r.generated, since: r.since, sessions: r.sessions, friction: r.friction,
        perSession: r.sessions == 0 ? 0 : (Double(r.friction) / Double(r.sessions) * 100).rounded() / 100,
        escalated: r.escalated, cacheReadShare: r.cacheReadShare, top: r.top.first?.name, topEvents: r.top.first?.events,
        report: run.appending(path: "report.json").path
    )
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    enc.dateEncodingStrategy = .iso8601
    var data = try! enc.encode(latest)
    data.append(0x0A)
    try? data.write(to: root.appending(path: "latest.json"))
}

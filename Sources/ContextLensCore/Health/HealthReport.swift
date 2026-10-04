import Foundation

/// Jev's verdict on one event, written by the classifier in `health/`.
public struct HealthLabel: Codable, Sendable {
    public var id: String
    public var label: String
    public var p: Double
    /// 1 (no cost) to 4 (blocks the task).
    public var severity: Double
    public var friction: Bool
    public var escalate: Bool
}

public struct HealthExample: Codable, Sendable {
    public var session: String
    public var title: String?
    public var link: String?
    public var file: String
    public var time: Date?
    public var input: String?
    /// For tool errors: the line that names the failure.
    public var line: String?
    public var text: String
}

public struct FrictionGroup: Codable, Sendable {
    /// What a person would call it: the guard message, or the label and the failing line.
    public var name: String
    public var label: String
    /// Tools and programs that tripped it, most first (top 8).
    public var sources: [String: Int]
    /// Distinct failing lines inside the group (top 6).
    public var variants: [String: Int]
    public var events: Int
    public var sessions: Int
    /// The sessions with the most events in this group (up to 5).
    public var sessionIDs: [String]
    /// Events that repeated a call that had already failed in the same session.
    public var retries: Int
    public var severity: Double
    public var cost: Double
    public var example: HealthExample
}

public struct FrictionRow: Codable, Sendable {
    public var name: String
    public var sessions: Int
    public var friction: Int
    public var perSession: Double
    public var labels: [String: Int]
}

public struct HealthDay: Codable, Sendable {
    public var day: String
    public var sessions: Int
    public var toolCalls: Int
    public var friction: Int
}

public struct HealthReport: Codable, Sendable {
    public var generated: Date
    public var since: Date
    public var sessions: Int
    public var harnesses: [String: Int]
    public var files: Int
    public var gigabytes: Double
    public var extractSeconds: Double
    public var events: Int
    public var labeled: Int
    public var friction: Int
    public var escalated: Int
    public var totals: [String: Int]
    /// Share of input tokens served from the prompt cache.
    public var cacheReadShare: Double
    public var top: [FrictionGroup]
    /// Every group, ranked (up to 100), for the app and for measuring a fix later.
    public var groups: [FrictionGroup]
    public var byTool: [FrictionRow]
    public var bySkill: [FrictionRow]
    public var byRuleFile: [FrictionRow]
    public var byDay: [HealthDay]
}

public enum HealthAggregator {
    /// Labels for events Jev does not see: these are friction by definition.
    static func defaultLabel(_ e: HealthEvent) -> HealthLabel? {
        switch e.kind {
        case .interrupt: HealthLabel(id: e.id, label: "interrupt", p: 1, severity: 2, friction: true, escalate: false)
        case .apiError: HealthLabel(id: e.id, label: "api_error", p: 1, severity: 2, friction: true, escalate: false)
        case .question: HealthLabel(id: e.id, label: "question", p: 1, severity: 1, friction: false, escalate: false)
        default: nil
        }
    }

    /// Labels whose events share one cause whatever tool tripped them, so they group by message.
    static let byMessage: Set<String> = ["guard", "permission", "auth", "api_error"]

    public static func report(_ x: HealthExtract, labels: [HealthLabel], top: Int = 10, now: Date = Date()) -> HealthReport {
        let byID = Dictionary(labels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sessions = Dictionary(x.sessions.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let labeled: [(HealthEvent, HealthLabel)] = x.events.compactMap { e in (byID[e.id] ?? defaultLabel(e)).map { (e, $0) } }
        let friction = labeled.filter { $0.1.friction }

        // Top groups.
        var groups: [String: [(HealthEvent, HealthLabel)]] = [:]
        for pair in friction {
            groups[groupKey(pair.0, pair.1), default: []].append(pair)
        }
        let ranked: [FrictionGroup] = groups.map { key, items in
            let cost = items.reduce(0) { $0 + $1.1.severity }
            // The example: one that opens in an app, then the most severe, then the most repeated.
            func rank(_ p: (HealthEvent, HealthLabel)) -> (Int, Double, Int) {
                (sessions[p.0.session]?.link == nil ? 0 : 1, p.1.severity, p.0.repeats)
            }
            let ex = items.max { rank($0) < rank($1) }!.0
            let s = sessions[ex.session]
            let bySession = Dictionary(items.map { ($0.0.session, 1) }, uniquingKeysWith: +)
            return FrictionGroup(
                name: key, label: items[0].1.label,
                sources: topCounts(Dictionary(items.map { ($0.0.source, 1) }, uniquingKeysWith: +), 8),
                variants: topCounts(Dictionary(items.map { (signature(errorLine($0.0.text)), 1) }, uniquingKeysWith: +), 6),
                events: items.count, sessions: bySession.count,
                sessionIDs: bySession.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(5).map(\.key),
                retries: items.filter { $0.0.repeats > 0 }.count,
                severity: (cost / Double(items.count) * 100).rounded() / 100, cost: cost,
                example: HealthExample(session: ex.session, title: s?.title, link: s?.link, file: s?.file ?? "", time: ex.time,
                                       input: ex.input, line: ex.kind == .toolError ? errorLine(ex.text) : nil, text: ex.text)
            )
        }.sorted { ($0.cost, $0.events) > ($1.cost, $1.events) }

        // Rows: per tool (events), per skill and per rule file (friction per session that loaded it).
        func rows(_ keyed: [(String, String)], sessionsWith: [String: Set<String>]) -> [FrictionRow] {
            var count: [String: [String: Int]] = [:]
            for (key, label) in keyed { count[key, default: [:]][label, default: 0] += 1 }
            return sessionsWith.map { name, ids in
                let labels = count[name] ?? [:]
                let n = labels.values.reduce(0, +)
                return FrictionRow(name: name, sessions: ids.count, friction: n,
                                   perSession: ids.isEmpty ? 0 : (Double(n) / Double(ids.count) * 100).rounded() / 100, labels: labels)
            }.sorted { ($0.friction, $0.sessions) > ($1.friction, $1.sessions) }
        }
        var toolSessions: [String: Set<String>] = [:]
        for (e, _) in friction { toolSessions[e.source, default: []].insert(e.session) }
        var skillSessions: [String: Set<String>] = [:], ruleSessions: [String: Set<String>] = [:]
        for s in x.sessions {
            for k in s.skills { skillSessions[k, default: []].insert(s.id) }
            for f in s.ruleFiles { ruleSessions[f, default: []].insert(s.id) }
        }
        let skillKeyed = friction.flatMap { e, l in e.skills.map { ($0, l.label) } }
        let ruleKeyed = friction.flatMap { e, l in (sessions[e.session]?.ruleFiles ?? []).map { ($0, l.label) } }

        // Days.
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        var days: [String: HealthDay] = [:]
        for s in x.sessions {
            let d = fmt.string(from: s.ended ?? s.started ?? now)
            days[d, default: HealthDay(day: d, sessions: 0, toolCalls: 0, friction: 0)].sessions += 1
            days[d, default: HealthDay(day: d, sessions: 0, toolCalls: 0, friction: 0)].toolCalls += s.toolCalls
        }
        for (e, _) in friction {
            let d = fmt.string(from: e.time ?? now)
            days[d, default: HealthDay(day: d, sessions: 0, toolCalls: 0, friction: 0)].friction += 1
        }

        let input = x.sessions.reduce(0) { $0 + $1.inputTokens }
        let cacheRead = x.sessions.reduce(0) { $0 + $1.cacheReadTokens }
        let cacheWrite = x.sessions.reduce(0) { $0 + $1.cacheWriteTokens }
        func sum(_ k: KeyPath<HealthSession, Int>) -> Int { x.sessions.reduce(0) { $0 + $1[keyPath: k] } }
        let totals: [String: Int] = [
            "toolCalls": sum(\.toolCalls), "toolErrors": sum(\.toolErrors), "userMessages": sum(\.userMessages),
            "interrupts": sum(\.interrupts), "apiErrors": sum(\.apiErrors), "questions": sum(\.questions),
            "corrections": friction.filter { ["correction", "repeat", "frustration"].contains($0.1.label) }.count,
            "retries": friction.filter { $0.0.repeats > 0 }.count,
            "inputTokens": input, "outputTokens": sum(\.outputTokens), "cacheReadTokens": cacheRead, "cacheWriteTokens": cacheWrite,
            "activeMinutes": Int(x.sessions.reduce(0) { $0 + $1.activeSeconds } / 60),
            "subagentSessions": x.sessions.filter(\.subagent).count,
        ]
        let allInput = input + cacheRead + cacheWrite
        return HealthReport(
            generated: now, since: x.since, sessions: x.sessions.count,
            harnesses: Dictionary(x.sessions.map { ($0.harness, 1) }, uniquingKeysWith: +),
            files: x.files, gigabytes: (Double(x.bytes) / 1e9 * 100).rounded() / 100, extractSeconds: (x.seconds * 10).rounded() / 10,
            events: x.events.count, labeled: labels.count, friction: friction.count, escalated: labels.filter(\.escalate).count,
            totals: totals, cacheReadShare: allInput == 0 ? 0 : (Double(cacheRead) / Double(allInput) * 1000).rounded() / 1000,
            top: Array(ranked.prefix(top)), groups: Array(ranked.prefix(100)),
            byTool: Array(rows(friction.map { ($0.0.source, $0.1.label) }, sessionsWith: toolSessions).prefix(40)),
            bySkill: rows(skillKeyed, sessionsWith: skillSessions),
            byRuleFile: rows(ruleKeyed, sessionsWith: ruleSessions),
            byDay: days.values.sorted { $0.day < $1.day }
        )
    }

    /// Events with one cause share a key. Guards and walls group by the first clause of their
    /// message (one guard words its refusals many ways); agent mistakes and broken environments
    /// by the line that names the error, so the same mistake groups across programs.
    static func topCounts(_ counts: [String: Int], _ n: Int) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }.prefix(n).map { ($0.key, $0.value) })
    }

    static func groupKey(_ e: HealthEvent, _ l: HealthLabel) -> String {
        switch e.kind {
        case .userMessage: return "user \(l.label)"
        case .interrupt: return "user interrupt"
        default: break
        }
        if byMessage.contains(l.label) {
            // API errors arrive as `429 {"type":"error",…,"message":"…"}`: name them by the message.
            let text = e.text.firstMatch(of: /"message"\s*:\s*"([^"]+)"/).map { String($0.1) } ?? e.text
            var s = signature(text).replacing(/claude-[a-z]+[-#]*/, with: "claude-*")
            if l.label == "api_error", let r = s.range(of: ": ") { s = String(s[..<r.lowerBound]) }
            if let r = s.range(of: ", but ") ?? s.range(of: ". ") { s = String(s[..<r.lowerBound]) }
            s = s.replacingOccurrences(of: "This agent is", with: "This session is")
            return "\(l.label): \(s)"
        }
        return "\(l.label): \(signature(errorLine(e.text)))"
    }

    static let errorWords = try! NSRegularExpression(
        pattern: #"(?i)error|fail|not found|no such|denied|invalid|cannot|can't|unable|fatal|exception|refus|timed? ?out|unknown|usage:|not permitted|missing|no matches|abort|panic"#
    )

    /// The line that names the failure: the last line with an error word, else the first line.
    public static func errorLine(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: #"^Exit code \d+\s*"#, with: "", options: .regularExpression)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let hit = lines.last { line in
            line.count < 400 && errorWords.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
                && !line.hasPrefix("File \"") && !line.hasPrefix("at ")
        }
        return hit ?? lines.first ?? text
    }

    /// The stable part of a message: first line, paths, numbers and ids blanked.
    public static func signature(_ text: String) -> String {
        var s = text.replacingOccurrences(of: #"<[/]?tool_use_error>"#, with: "", options: .regularExpression)
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^Exit code \d+\s*"#, with: "", options: .regularExpression)
        s = String(s.split(separator: "\n").first ?? "")
        s = s.replacingOccurrences(of: #"\u{1B}\[[0-9;]*m"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[`'"]?[^\s,'"`(]*/[^\s,'"`)]*"#, with: "…", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b[0-9a-f]{7,}\b|\b\d+(\.\d+)?\b"#, with: "#", options: .regularExpression)
        s = s.replacingOccurrences(of: #"={2,}\S*"#, with: "==", options: .regularExpression)
        return s.count > 90 ? String(s.prefix(90)) + "…" : s
    }
}

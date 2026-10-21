import Foundation

/// Where the tokens of a measured context go, segment by segment, so the parts add up to the
/// measured total.
///
/// For a recorded session the total is the first call's API usage. What the transcript records
/// (instruction files, skill and subagent listings, MCP server instructions, environment, the first
/// message) is estimated from its text; what it doesn't record (the harness prompt, built-in tool
/// definitions, MCP tool schemas) comes from the `/context` measurement of the folder nearest the
/// session's start. What neither explains is an explicit Unattributed segment.
public struct ContextAttribution: Codable, Hashable, Sendable {
    public enum Basis: String, Codable, Sendable {
        /// Counted by Claude Code (`/context` or API usage).
        case measured
        /// Estimated from transcript text.
        case estimated
        /// Measured schemas plus estimated instructions.
        case mixed
        /// Total minus everything attributed.
        case remainder
    }

    public struct Segment: Codable, Hashable, Sendable, Identifiable {
        /// `harness-prompt`, `built-in-tools`, `mcp|<server>`, `instructions`, `skills`, `subagents`,
        /// `environment`, `reminders`, `first-message`, `unattributed`.
        public var id: String
        public var title: String
        public var tokens: Int
        /// Rounded to 100 tokens so that the shown values sum to the shown total.
        public var shown: Int = 0
        public var basis: Basis
        /// "schemas 31.6k + instructions 0.7k", "instructions 0.5k + schemas unknown".
        public var detail: String?
        /// MCP servers: the measured tool schemas, nil when no measurement has the server.
        public var schemas: Int?
        /// MCP servers: the server instructions the transcript records.
        public var instructions: Int?
        /// MCP servers whose schemas come from another measurement than the one the session uses.
        public var schemasFrom: MeasurementRef?

        public var isMCP: Bool { id.hasPrefix("mcp|") }
    }

    public struct MeasurementRef: Codable, Hashable, Sendable {
        public var folder: String
        public var measuredAt: Date
        public var source: String?
    }

    /// The measured total: the first call, or what `/context` counted.
    public var total: Int
    /// `total` rounded to 100 tokens; the segments' `shown` values sum to it.
    public var shownTotal: Int
    public var segments: [Segment]
    /// The `/context` measurement used for what the transcript doesn't record.
    public var measurement: MeasurementRef?
    /// Factor applied to the 4-characters-per-token estimates, from /context's own count of the
    /// same instruction files and skills. Nil without a measurement.
    public var calibration: Double?
    public var cacheRead: Int?
    public var cacheWritten: Int?
    /// Likely causes of the Unattributed segment, most likely first.
    public var causes: [String]
    public var rounding = "Each segment is rounded to 0.1k, with the rounding spread so the legend adds up to the rounded total."

    public init(total: Int, segments: [Segment], measurement: MeasurementRef? = nil, calibration: Double? = nil,
                cacheRead: Int? = nil, cacheWritten: Int? = nil, causes: [String] = []) {
        self.total = total
        self.segments = segments
        self.measurement = measurement
        self.calibration = calibration
        self.cacheRead = cacheRead
        self.cacheWritten = cacheWritten
        self.causes = causes
        shownTotal = Self.round100(total)
        let shown = Self.spread(segments.map(\.tokens), to: shownTotal)
        for i in self.segments.indices { self.segments[i].shown = shown[i] }
    }

    public func mcp(_ server: String) -> Segment? {
        segments.first { $0.isMCP && MeasuredContext.serverKey($0.title) == MeasuredContext.serverKey(server) }
    }

    public var unattributed: Segment? { segments.first { $0.id == "unattributed" } }

    // MARK: - Recorded session

    /// Attributes a session's first call. `measurement` is the folder's measurement nearest the
    /// session start; `others` are measurements of any folder, used for MCP servers the session
    /// loaded but `measurement` lacks (a server that didn't connect during that run).
    public static func session(snapshot: ContextSnapshot, growth: ContextGrowth, measurement m: MeasuredContext?,
                               others: [MeasuredContext] = []) -> ContextAttribution? {
        guard let total = growth.firstCall else { return nil }
        let items = snapshot.items.filter { $0.startingTokens > 0 }
        let cal = m.flatMap { calibration(items, $0) }
        func est(_ n: Int) -> Int { Int((Double(n) * (cal ?? 1)).rounded()) }
        func sum(_ kinds: Set<ContextKind>) -> Int { items.filter { kinds.contains($0.kind) }.reduce(0) { $0 + $1.startingTokens } }
        var segs: [Segment] = []
        func add(_ id: String, _ title: String, _ tokens: Int, _ basis: Basis, _ detail: String? = nil) {
            guard tokens != 0 else { return }
            segs.append(Segment(id: id, title: title, tokens: tokens, basis: basis, detail: detail))
        }

        let prompt = m?.category("System prompt") ?? 0
        if prompt > 0 {
            add("harness-prompt", "Harness prompt", prompt, .measured)
        } else {
            add("harness-prompt", "Harness prompt", est(sum([.systemPrompt])), .estimated)
        }
        if let m { add("built-in-tools", "Built-in tools", m.category("System tools"), .measured) }

        // MCP servers: the transcript's (with instructions), then servers only the measurement has.
        let start = growth.calls.first?.time ?? m?.measuredAt ?? Date()
        var mcp: [Segment] = []
        var named = Set<String>()
        for item in items where item.kind == .mcp {
            named.insert(MeasuredContext.serverKey(item.title))
            let instructions = est(item.startingTokens)
            var schemas = m?.mcpSchemas(item.title)
            var from: MeasurementRef?
            if schemas == nil, let other = others.filter({ $0.mcpSchemas(item.title) != nil })
                .min(by: { abs($0.measuredAt.timeIntervalSince(start)) < abs($1.measuredAt.timeIntervalSince(start)) }) {
                schemas = other.mcpSchemas(item.title)
                from = ref(other)
            }
            let detail = schemas.map { "schemas \(k($0)) + instructions \(k(instructions))" } ?? "instructions \(k(instructions)) + schemas unknown"
            mcp.append(Segment(id: "mcp|\(item.title)", title: item.title, tokens: instructions + (schemas ?? 0),
                               basis: schemas == nil ? .estimated : .mixed, detail: detail, schemas: schemas, instructions: instructions, schemasFrom: from))
        }
        for server in m?.mcpServers ?? [] where !named.contains(MeasuredContext.serverKey(server.name)) {
            mcp.append(Segment(id: "mcp|\(server.name)", title: server.name, tokens: server.tokens, basis: .measured,
                               detail: "schemas \(k(server.tokens)), no instructions", schemas: server.tokens, instructions: 0))
        }
        segs += mcp.sorted { ($0.tokens, $1.title) > ($1.tokens, $0.title) }

        add("instructions", "Instruction files", est(sum([.instructions, .imported, .rule, .memory])), .estimated)
        add("skills", "Skills", est(sum([.skill])), .estimated)
        add("subagents", "Subagents", est(sum([.agent])), .estimated)
        add("environment", "Environment", est(sum([.environment, .command, .hook, .onDemand, .inactive])), .estimated)
        let reminders = growth.firstTurnReminders
        add("reminders", "Harness reminders", est(reminders.reduce(0) { $0 + $1.tokens }), .estimated,
            reminders.map { "\($0.label) \(k(est($0.tokens)))" }.joined(separator: " · "))
        add("first-message", "First message", est(growth.firstMessageTokens), .estimated)

        let rest = total - segs.reduce(0) { $0 + $1.tokens }
        let causes: [String]
        if let m {
            segs.append(Segment(id: "unattributed", title: "Unattributed", tokens: rest, basis: .remainder))
            causes = sessionCauses(growth: growth, segments: segs, measurement: m, calibration: cal, start: start, rest: rest)
        } else {
            segs.append(Segment(id: "unattributed", title: "Not in transcript", tokens: rest, basis: .remainder,
                                detail: "built-in tools, MCP tool schemas, harness prompt"))
            causes = ["No /context measurement of this folder yet, so built-in tool definitions and MCP tool schemas can't be told apart. Measure the folder (Now, or `context-lens measure <dir>`)."]
        }
        return ContextAttribution(total: total, segments: segs, measurement: m.map(ref), calibration: cal,
                                  cacheRead: growth.firstCallCacheRead, cacheWritten: growth.firstCallCacheWritten, causes: causes)
    }

    static func sessionCauses(growth: ContextGrowth, segments: [Segment], measurement m: MeasuredContext, calibration: Double?, start: Date, rest: Int) -> [String] {
        var causes: [String] = []
        if rest < 0 {
            causes.append("The attributed parts exceed the measured total by \(k(-rest)): the estimates run high for this text, or the setup was larger when measured.")
        }
        let hours = abs(m.measuredAt.timeIntervalSince(start)) / 3600
        causes.append(String(format: "Measurement drift: measured %.1f h %@ the session started. /context's count of built-in tools depends on how the run started (tool search, environment variables of the shell that ran it) and changes with Claude Code updates and plugins added or removed in between; runs of the same setup have differed by about 4k.",
                             hours, m.measuredAt < start ? "before" : "after"))
        causes.append("Text the harness wraps around what the transcript records: system-reminder tags, the headings and notes around instruction files and listings, permission-mode guidance. The transcript stores the content, not the wrapper.")
        if let calibration {
            causes.append(String(format: "Estimates: transcript text is counted at 4 characters per token, scaled ×%.2f to match /context's count of the same instruction files and skills. The real ratio varies with the text.", calibration))
        } else {
            causes.append("Estimates: transcript text is counted at 4 characters per token. No instruction file or skill matched the measurement, so the estimate isn't calibrated.")
        }
        if let read = growth.firstCallCacheRead, let written = growth.firstCallCacheWritten, read > 0 {
            let prefix = segments.filter { ["harness-prompt", "built-in-tools"].contains($0.id) }.reduce(0) { $0 + $1.tokens }
                + segments.reduce(0) { $0 + ($1.schemas ?? 0) }
            causes.append("The first call read \(k(read)) from the prompt cache (the start an earlier session with the same setup had already sent) and wrote \(k(written)) new. The harness prompt and tool definitions above come to \(k(prefix)).")
        }
        if !growth.firstTurnReminders.contains(where: { $0.label == "Hook output" }) {
            causes.append("Hooks: no hook output was recorded before the first call, so hooks are unlikely.")
        }
        return causes
    }

    /// /context's own count of instruction files and skills against the 4-characters-per-token
    /// estimate of the same items in the transcript. Needs at least 200 estimated tokens to match.
    static func calibration(_ items: [ContextItem], _ m: MeasuredContext) -> Double? {
        var estimated = 0, measured = 0
        for f in m.memoryFiles ?? [] where f.tokens >= 50 {
            guard let i = items.first(where: { $0.path == f.name && $0.load == .always }) else { continue }
            estimated += i.startingTokens; measured += f.tokens
        }
        for s in m.skills where s.tokens >= 50 {
            guard let i = items.first(where: { $0.kind == .skill && $0.title == s.name && $0.load == .listing }), i.startingTokens >= 20 else { continue }
            estimated += i.startingTokens; measured += s.tokens
        }
        guard estimated >= 200 else { return nil }
        return min(2, max(1, Double(measured) / Double(estimated)))
    }

    // MARK: - A measurement on its own

    /// What `/context` counted, as segments.
    public static func measured(_ m: MeasuredContext) -> ContextAttribution {
        var segs: [Segment] = []
        var rest = m.used
        for c in m.categories {
            rest -= c.tokens
            if c.name == "MCP tools" {
                for s in m.mcpServers {
                    segs.append(Segment(id: "mcp|\(s.name)", title: s.name, tokens: s.tokens, basis: .measured, detail: "schemas \(k(s.tokens))", schemas: s.tokens))
                }
                // The printed table rounds the category to 0.1k; a smaller difference is that rounding.
                let other = c.tokens - m.mcpServers.reduce(0) { $0 + $1.tokens }
                if abs(other) >= 100 {
                    segs.append(Segment(id: "mcp-other", title: "MCP tools, other", tokens: other, basis: .measured))
                } else {
                    rest += other
                }
                continue
            }
            guard c.tokens != 0 else { continue }
            let (id, title) = measuredNames[c.name] ?? (c.name.lowercased().replacingOccurrences(of: " ", with: "-"), c.name)
            segs.append(Segment(id: id, title: title, tokens: c.tokens, basis: .measured))
        }
        if rest != 0 {
            segs.append(Segment(id: "rounding", title: "/context rounding", tokens: rest, basis: .remainder))
        }
        return ContextAttribution(total: m.used, segments: segs, measurement: ref(m),
                                  causes: rest == 0 ? [] : ["/context prints its table rounded to 0.1k; the parts don't add up to its total by this much."])
    }

    static let measuredNames: [String: (String, String)] = [
        "System prompt": ("harness-prompt", "Harness prompt"),
        "System tools": ("built-in-tools", "Built-in tools"),
        "Memory files": ("instructions", "Instruction files"),
        "Skills": ("skills", "Skills"),
        "Custom agents": ("subagents", "Subagents"),
        "Messages": ("first-message", "Messages"),
    ]

    // MARK: - Helpers

    static func ref(_ m: MeasuredContext) -> MeasurementRef {
        MeasurementRef(folder: m.folder, measuredAt: m.measuredAt, source: m.source)
    }

    /// "31.6k", "0.5k".
    static func k(_ n: Int) -> String { String(format: "%.1fk", Double(n) / 1000) }

    static func round100(_ n: Int) -> Int { Int((Double(n) / 100).rounded()) * 100 }

    /// Rounds each value to a multiple of 100 so they sum to `total` (largest remainder).
    static func spread(_ values: [Int], to total: Int) -> [Int] {
        guard !values.isEmpty else { return [] }
        var out = values.map { Int((Double($0) / 100).rounded(.down)) * 100 }
        var left = (total - out.reduce(0, +)) / 100
        let order = values.indices.sorted { (values[$0] - out[$0], values[$0]) > (values[$1] - out[$1], values[$1]) }
        var i = 0
        while left > 0 { out[order[i % order.count]] += 100; left -= 1; i += 1 }
        i = 0
        while left < 0 { out[order[order.count - 1 - (i % order.count)]] -= 100; left += 1; i += 1 }
        return out
    }
}

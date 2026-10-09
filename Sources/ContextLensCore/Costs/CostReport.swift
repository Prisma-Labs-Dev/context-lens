import Foundation

/// Token counts and their list-price cost.
public struct TokenTotals: Codable, Sendable, Hashable {
    public var calls = 0
    public var input = 0
    public var cacheWrite5m = 0
    public var cacheWrite1h = 0
    public var cacheRead = 0
    public var output = 0
    public var thinking = 0
    public var webSearches = 0
    public var cost = 0.0
    /// Calls on a model the price table does not know; their tokens count, their cost does not.
    public var unpricedCalls = 0

    public init() {}

    /// Share of prompt tokens served from cache.
    public var hitRatio: Double {
        let prompt = input + cacheWrite5m + cacheWrite1h + cacheRead
        return prompt == 0 ? 0 : Double(cacheRead) / Double(prompt)
    }

    public var prompt: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }

    mutating func add(_ c: CostCall) {
        calls += 1; input += c.input; cacheWrite5m += c.cacheWrite5m; cacheWrite1h += c.cacheWrite1h
        cacheRead += c.cacheRead; output += c.output; thinking += c.thinking; webSearches += c.webSearches
        if let usd = c.cost { cost += usd } else { unpricedCalls += 1 }
    }

    mutating func add(_ t: TokenTotals) {
        calls += t.calls; input += t.input; cacheWrite5m += t.cacheWrite5m; cacheWrite1h += t.cacheWrite1h
        cacheRead += t.cacheRead; output += t.output; thinking += t.thinking; webSearches += t.webSearches
        cost += t.cost; unpricedCalls += t.unpricedCalls
    }

    /// Cost split by token type, in USD, for the "where does the money go" bar.
    public struct Split: Codable, Sendable, Hashable {
        public var input = 0.0, cacheWrite = 0.0, cacheRead = 0.0, output = 0.0
    }
}

/// Names a group of sessions by title or folder, in `~/.context-lens/cost-groups.json`:
///
///     {"groups": [{"name": "Lead", "title": "Lead"}, {"name": "Reviews", "titlePrefix": "Review "}]}
///
/// The first matching rule wins. Sessions no rule matches are grouped by how they were started.
/// Kept outside the repo, since titles are personal.
public struct CostGroupRule: Codable, Sendable, Hashable {
    public var name: String
    public var title: String?
    public var titlePrefix: String?
    public var cwdPrefix: String?
    public var kind: CostKind?

    public init(name: String, title: String? = nil, titlePrefix: String? = nil, cwdPrefix: String? = nil, kind: CostKind? = nil) {
        self.name = name; self.title = title; self.titlePrefix = titlePrefix; self.cwdPrefix = cwdPrefix; self.kind = kind
    }

    func matches(_ f: CostFileScan) -> Bool {
        if title == nil, titlePrefix == nil, cwdPrefix == nil, kind == nil { return false }
        if let title, f.title != title { return false }
        if let titlePrefix, !(f.title ?? "").hasPrefix(titlePrefix) { return false }
        if let cwdPrefix, !f.cwd.hasPrefix(NSString(string: cwdPrefix).expandingTildeInPath) { return false }
        if let kind, f.kind != kind { return false }
        return true
    }
}

public struct CostConfig: Codable, Sendable {
    public var groups: [CostGroupRule] = []

    public init(groups: [CostGroupRule] = []) { self.groups = groups }

    public static func load(env: HarnessEnvironment = .current) -> CostConfig {
        let url = env.home.appending(path: ".context-lens/cost-groups.json")
        guard let data = try? Data(contentsOf: url) else { return CostConfig() }
        return (try? JSONDecoder().decode(CostConfig.self, from: data)) ?? CostConfig()
    }
}

public struct SessionCost: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var group: String
    public var kind: CostKind
    public var cwd: String
    public var file: String
    public var first: Date
    public var last: Date
    public var models: [String]
    /// The session's own calls in the window.
    public var own = TokenTotals()
    /// Its subagents' calls in the window.
    public var subagents = TokenTotals()
    public var subagentCount = 0
    /// Largest context one call sent.
    public var peakContext = 0
    /// Calls that sent more than `CostReport.bigContext` tokens, and what they cost.
    public var bigCalls = 0
    public var bigCost = 0.0
    /// Calls that found the cache cold after an idle gap, and what rewriting the cache cost over
    /// reading it warm.
    public var coldRestarts = 0
    public var coldExtra = 0.0
    /// Copilot only.
    public var credits: Double?

    public var total: Double { own.cost + subagents.cost }
}

public struct GroupCost: Codable, Sendable, Identifiable, Hashable {
    public var id: String { name }
    public var name: String
    public var sessions = 0
    public var totals = TokenTotals()
    public var credits = 0.0
}

public struct ModelCost: Codable, Sendable, Identifiable, Hashable {
    public var id: String { model }
    public var model: String
    public var totals = TokenTotals()
    public var split = TokenTotals.Split()
    public var price: ModelPrice?
}

/// A finding with the money attached, largest first.
public struct CostHint: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var title: String
    public var detail: String
    /// USD at stake: what the pattern cost, or what the change would save.
    public var usd: Double
}

/// What switching the 5-minute cache TTL to 1 hour would have cost, estimated from the gaps.
public struct TTLWhatIf: Codable, Sendable, Hashable {
    /// Extra for writing every 5-minute write at the 1-hour price.
    public var extraWrites = 0.0
    /// Saved where a cold restart after a 5 to 60 minute gap would have read the cache instead.
    public var savedRestarts = 0.0
    public var restartsSaved = 0
    public var net: Double { savedRestarts - extraWrites }
}

/// Idle gaps before cold restarts, bucketed.
public struct ColdRestarts: Codable, Sendable, Hashable {
    public var under1h = 0, under1hExtra = 0.0
    public var over1h = 0, over1hExtra = 0.0
}

public struct CostReport: Codable, Sendable {
    public static let bigContext = 300_000
    /// The default cache TTL; a gap longer than this finds the cache cold.
    public static let ttl5m: Double = 300

    public var since: Date?
    public var until: Date
    public var totals = TokenTotals()
    public var split = TokenTotals.Split()
    public var groups: [GroupCost] = []
    public var models: [ModelCost] = []
    /// Top-level sessions with calls in the window, most expensive first.
    public var sessions: [SessionCost] = []
    public var copilot: [SessionCost] = []
    public var copilotCredits = 0.0
    /// Cost by Claude Code entrypoint. It shows which account paid: `claude-desktop-3p` is the
    /// desktop app on a third-party gateway, `claude-desktop` on a claude.ai account; `cli` and
    /// `sdk-cli` follow whatever `ANTHROPIC_BASE_URL` the shell had.
    public var byEntrypoint: [String: Double] = [:]
    public var cold = ColdRestarts()
    public var ttl1h = TTLWhatIf()
    public var hints: [CostHint] = []
    public var priceSource = Pricing.source
    public var pricesReadOn = Pricing.readOn
    /// Calls seen in two transcripts (a resumed or forked session) and counted once.
    public var duplicateCalls = 0
}

public enum CostReportBuilder {
    public static func build(files: [CostFileScan], since: Date?, until: Date = Date(), config: CostConfig = CostConfig()) -> CostReport {
        var report = CostReport(since: since, until: until)
        func inWindow(_ d: Date) -> Bool { (since.map { d >= $0 } ?? true) && d <= until }

        // A call copied into a resumed or forked transcript counts once, in its own transcript.
        var owned = Set<String>()
        for f in files where f.kind != .copilot { for c in f.calls where !c.copied { owned.insert(c.id) } }
        var seen = Set<String>()

        let parents = Dictionary(files.filter { $0.kind != .subagent && $0.kind != .copilot }.map { ($0.session, $0) }) { a, b in
            a.calls.count >= b.calls.count ? a : b
        }
        var sessions: [String: SessionCost] = [:]
        var groups: [String: GroupCost] = [:]
        var models: [String: ModelCost] = [:]
        var groupSessions: [String: Set<String>] = [:]

        func groupName(_ f: CostFileScan) -> String {
            config.groups.first { $0.matches(f) }?.name ?? f.kind.label
        }

        for f in files {
            if f.kind == .copilot {
                guard let credits = f.credits, let t = f.calls.first?.time, inWindow(t) else { continue }
                var s = SessionCost(id: f.session, title: f.title ?? "Copilot session", group: CostKind.copilot.label, kind: .copilot,
                                    cwd: f.cwd, file: f.file, first: t, last: t, models: f.copilotModel.map { [$0] } ?? [])
                s.credits = credits
                if let k = f.copilotTokens {
                    s.own.calls = 1; s.own.input = k.input; s.own.cacheRead = k.cacheRead; s.own.cacheWrite5m = k.cacheWrite; s.own.output = k.output
                }
                report.copilot.append(s)
                report.copilotCredits += credits
                continue
            }
            let calls = f.calls.filter { c in
                guard inWindow(c.time) else { return false }
                if c.copied, owned.contains(c.id) { report.duplicateCalls += 1; return false }
                if seen.contains(c.id) { report.duplicateCalls += 1; return false }
                seen.insert(c.id)
                return true
            }
            guard !calls.isEmpty else { continue }
            let parent = f.kind == .subagent ? parents[f.session] : f
            let key = f.session
            var s = sessions[key] ?? SessionCost(
                id: key, title: parent?.title ?? "Untitled", group: parent.map(groupName) ?? CostKind.subagent.label,
                kind: parent?.kind ?? .terminal, cwd: parent?.cwd ?? f.cwd, file: parent?.file ?? f.file,
                first: calls[0].time, last: calls[0].time, models: [])
            let group = f.kind == .subagent ? CostKind.subagent.label : s.group
            var totals = TokenTotals()
            for c in calls {
                totals.add(c)
                s.first = min(s.first, c.time); s.last = max(s.last, c.time)
                if !s.models.contains(c.model) { s.models.append(c.model) }
                s.peakContext = max(s.peakContext, c.context)
                let price = Pricing.price(c.model, promptTokens: c.context, fast: c.fast)
                if c.context > CostReport.bigContext { s.bigCalls += 1; s.bigCost += c.cost ?? 0 }
                var m = models[Pricing.normalize(c.model)] ?? ModelCost(model: Pricing.normalize(c.model), price: price)
                m.totals.add(c)
                if let p = price {
                    m.split.input += Double(c.input) * p.input / 1e6
                    m.split.cacheWrite += (Double(c.cacheWrite5m) * p.cacheWrite5m + Double(c.cacheWrite1h) * p.cacheWrite1h) / 1e6
                    m.split.cacheRead += Double(c.cacheRead) * p.cacheRead / 1e6
                    m.split.output += Double(c.output) * p.output / 1e6
                }
                models[m.model] = m
                if let p = price, let cold = coldRestart(c) {
                    let writePrice = c.cacheWrite1h > c.cacheWrite5m ? p.cacheWrite1h : p.cacheWrite5m
                    let extra = Double(cold) * (writePrice - p.cacheRead) / 1e6
                    s.coldRestarts += 1; s.coldExtra += extra
                    if c.gap! <= 3600 {
                        report.cold.under1h += 1; report.cold.under1hExtra += extra
                        if c.cacheWrite1h == 0 {
                            report.ttl1h.restartsSaved += 1
                            report.ttl1h.savedRestarts += Double(cold) * (p.cacheWrite1h - p.cacheRead) / 1e6
                        }
                    } else {
                        report.cold.over1h += 1; report.cold.over1hExtra += extra
                    }
                }
                if let p = price { report.ttl1h.extraWrites += Double(c.cacheWrite5m) * (p.cacheWrite1h - p.cacheWrite5m) / 1e6 }
            }
            if f.kind == .subagent {
                s.subagents.add(totals); s.subagentCount += 1
            } else {
                s.own.add(totals)
            }
            sessions[key] = s
            var g = groups[group] ?? GroupCost(name: group)
            g.totals.add(totals)
            groups[group] = g
            groupSessions[group, default: []].insert(key)
            report.totals.add(totals)
            report.byEntrypoint[f.entrypoint ?? parent?.entrypoint ?? "unknown", default: 0] += totals.cost
        }
        for (name, ids) in groupSessions { groups[name]?.sessions = ids.count }
        if !report.copilot.isEmpty {
            var g = GroupCost(name: CostKind.copilot.label, sessions: report.copilot.count)
            g.credits = report.copilotCredits
            groups[g.name] = g
        }
        report.sessions = sessions.values.sorted { $0.total > $1.total }
        report.copilot.sort { ($0.credits ?? 0) > ($1.credits ?? 0) }
        report.groups = groups.values.sorted { ($0.totals.cost, $0.credits) > ($1.totals.cost, $1.credits) }
        report.models = models.values.sorted { $0.totals.cost > $1.totals.cost }
        for m in report.models {
            report.split.input += m.split.input; report.split.cacheWrite += m.split.cacheWrite
            report.split.cacheRead += m.split.cacheRead; report.split.output += m.split.output
        }
        report.hints = hints(report)
        return report
    }

    /// Tokens a call had to write again because the cache went cold over an idle gap, or nil
    /// when the cache was warm. Small contexts are left out: there is little to lose.
    static func coldRestart(_ c: CostCall) -> Int? {
        guard let gap = c.gap, gap > CostReport.ttl5m, let previous = c.previousContext, previous >= 20_000,
              Double(c.cacheRead) < 0.5 * Double(previous) else { return nil }
        return min(c.cacheWrite + c.input, previous)
    }

    static func hints(_ r: CostReport) -> [CostHint] {
        var out: [CostHint] = []
        let total = max(r.totals.cost, 0.000_001)
        func pct(_ v: Double) -> String { String(format: "%.0f%%", v / total * 100) }
        func usd(_ v: Double) -> String { String(format: "$%.2f", v) }

        let big = r.sessions.filter { $0.peakContext > CostReport.bigContext }
        let bigCost = big.reduce(0) { $0 + $1.bigCost }
        if !big.isEmpty {
            out.append(CostHint(id: "big-context", title: "Calls over 300k tokens of context",
                                detail: "\(big.count) sessions went past 300k; their \(big.reduce(0) { $0 + $1.bigCalls }) calls above it cost \(usd(bigCost)) (\(pct(bigCost))). Every call re-reads the whole context, so a fresh session or /compact near 300k cuts the per-call price.",
                                usd: bigCost))
        }
        if let top = r.sessions.max(by: { $0.own.cacheRead < $1.own.cacheRead }), top.own.cacheRead > 0 {
            let reads = r.split.cacheRead
            out.append(CostHint(id: "re-reads", title: "Cache reads",
                                detail: "Re-reading cached context cost \(usd(reads)) (\(pct(reads))). Most re-read: \"\(top.title)\", \(top.own.calls) calls averaging \(top.own.prompt / max(top.own.calls, 1) / 1000)k tokens each.",
                                usd: reads))
        }
        let coldExtra = r.cold.under1hExtra + r.cold.over1hExtra
        if r.cold.under1h + r.cold.over1h > 0 {
            var detail = "\(r.cold.under1h + r.cold.over1h) calls rewrote a cold cache after an idle gap, \(usd(coldExtra)) over warm reads: \(r.cold.under1h) after 5 to 60 minutes (\(usd(r.cold.under1hExtra))), \(r.cold.over1h) after more than an hour (\(usd(r.cold.over1hExtra)))."
            detail += String(format: " A 1-hour TTL would have saved %@ on restarts but cost %@ more on writes: net %@.",
                             usd(r.ttl1h.savedRestarts), usd(r.ttl1h.extraWrites), r.ttl1h.net >= 0 ? "saves " + usd(r.ttl1h.net) : "costs " + usd(-r.ttl1h.net))
            out.append(CostHint(id: "cold-restarts", title: "Cold restarts after idle gaps", detail: detail, usd: coldExtra))
        }
        let sub = r.groups.first { $0.name == CostKind.subagent.label }?.totals
        if let sub, sub.cost > 0 {
            out.append(CostHint(id: "subagents", title: "Subagents",
                                detail: "Subagents cost \(usd(sub.cost)) (\(pct(sub.cost))) over \(sub.calls) calls, cache hit ratio \(Int(sub.hitRatio * 100))%. Each subagent starts by writing its own cache.",
                                usd: sub.cost))
        }
        let writes = r.split.cacheWrite
        if writes > 0 {
            out.append(CostHint(id: "cache-writes", title: "Cache writes",
                                detail: "Writing new context to the cache cost \(usd(writes)) (\(pct(writes))). Large tool results and file reads are written once, then re-read on every later call.",
                                usd: writes))
        }
        if r.split.output > 0 {
            out.append(CostHint(id: "output", title: "Output and thinking",
                                detail: "Output cost \(usd(r.split.output)) (\(pct(r.split.output))); \(r.totals.thinking / 1000)k of \(r.totals.output / 1000)k output tokens were thinking.",
                                usd: r.split.output))
        }
        return out.sorted { $0.usd > $1.usd }
    }
}

/// Computed cost against Claude Code's own running total (`cost-state` lines, the same number
/// `/cost` and `claude -p --output-format json` report as `total_cost_usd`). Claude Code's total
/// covers one process: it includes subagents and calls the transcript does not record (such as
/// title generation), and it starts again when a session is resumed.
public struct CostReconciliation: Codable, Sendable {
    public struct Row: Codable, Sendable {
        public var session: String
        public var title: String
        public var computed: Double
        public var reported: Double
        public var error: Double { reported == 0 ? 0 : (computed - reported) / reported }
    }

    public var rows: [Row] = []
    public var computed = 0.0
    public var reported = 0.0
    /// Median of the per-session relative errors (computed minus reported, over reported).
    public var medianError = 0.0
    /// Sessions within 5% of Claude Code's total.
    public var within5Percent = 0

    public static func build(files: [CostFileScan], since: Date?) -> CostReconciliation {
        var out = CostReconciliation()
        let subagents = Dictionary(grouping: files.filter { $0.kind == .subagent }, by: \.session)
        for f in files where f.kind != .subagent && f.kind != .copilot {
            guard let reported = f.reportedCost, reported > 0, f.calls.contains(where: { c in since.map { c.time >= $0 } ?? true }) else { continue }
            let all = f.calls + (subagents[f.session] ?? []).flatMap(\.calls)
            let computed = all.reduce(0) { $0 + ($1.cost ?? 0) }
            out.rows.append(Row(session: f.session, title: f.title ?? "Untitled", computed: computed, reported: reported))
        }
        out.rows.sort { $0.reported > $1.reported }
        out.computed = out.rows.reduce(0) { $0 + $1.computed }
        out.reported = out.rows.reduce(0) { $0 + $1.reported }
        let errors = out.rows.map(\.error).sorted()
        if !errors.isEmpty { out.medianError = errors[errors.count / 2] }
        out.within5Percent = errors.filter { abs($0) <= 0.05 }.count
        return out
    }
}

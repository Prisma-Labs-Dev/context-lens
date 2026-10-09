import ContextLensCore
import Foundation

/// `context-lens cost [--since today|24h|7d|30d|all] [--brief] [--top N]`: what Claude Code
/// sessions cost at list price, by group, model and session, with the biggest cost drivers.
/// `--reconcile`: computed cost against Claude Code's own running total, per session.
func runCost(_ opts: Options) {
    let window = opts.flags["since"] ?? "7d"
    var since: Date?
    if window == "today" {
        since = Calendar.current.startOfDay(for: Date())
    } else if window != "all" {
        guard let age = parseAge(window) else { fail("--since takes today, 24h, 7d, 2w or all") }
        since = Date().addingTimeInterval(-age)
    }
    var until = Date()
    if let day = opts.flags["until"] {
        // A day, inclusive, in local time: --until 2026-10-07 ends at midnight after it.
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { fail("--until takes a day such as 2026-10-07") }
        until = d.addingTimeInterval(86_400 - 0.001)
    }
    let files = CostScanner().scan(since: since)
    if opts.flags["reconcile"] != nil {
        emit(CostReconciliation.build(files: files, since: since))
        return
    }
    let report = CostReportBuilder.build(files: files, since: since, until: until, config: CostConfig.load())
    if opts.flags["brief"] != nil {
        print(CostBrief.text(report, window: window, top: Int(opts.flags["top"] ?? "5") ?? 5))
    } else {
        emit(report)
    }
}

/// Plain text for a morning brief: totals, groups, models, top sessions and drivers.
enum CostBrief {
    static func text(_ r: CostReport, window: String, top: Int) -> String {
        var lines: [String] = []
        let t = r.totals
        lines.append("Claude cost, \(window == "all" ? "all time" : "since " + (window == "today" ? "midnight" : window + " ago")): "
            + "\(usd(t.cost)) at list price, \(t.calls) calls, cache hit \(pct(t.hitRatio))"
            + (r.copilotCredits > 0 ? "; Copilot \(String(format: "%.1f", r.copilotCredits)) AI credits" : ""))
        lines.append("By entrypoint: " + r.byEntrypoint.sorted { $0.value > $1.value }.map { "\($0.key) \(usd($0.value))" }.joined(separator: ", "))
        lines.append("Split: cache read \(usd(r.split.cacheRead)), cache write \(usd(r.split.cacheWrite)), output \(usd(r.split.output)), input \(usd(r.split.input))")
        lines.append("")
        lines.append("By group:")
        for g in r.groups {
            if g.totals.calls == 0, g.credits > 0 {
                lines.append("  \(pad(g.name, 26)) \(String(format: "%7.1f cr", g.credits))  \(g.sessions) sessions")
            } else {
                lines.append("  \(pad(g.name, 26)) \(lpad(usd(g.totals.cost), 9))  \(g.sessions) sessions, \(g.totals.calls) calls, hit \(pct(g.totals.hitRatio))")
            }
        }
        lines.append("")
        lines.append("By model:")
        for m in r.models {
            let x = m.totals
            lines.append("  \(pad(m.model, 20)) \(lpad(usd(x.cost), 9))  in \(k(x.input)) out \(k(x.output)) (think \(k(x.thinking))) "
                + "w5m \(k(x.cacheWrite5m)) w1h \(k(x.cacheWrite1h)) read \(k(x.cacheRead)) hit \(pct(x.hitRatio))"
                + (m.price == nil ? " UNPRICED" : ""))
        }
        lines.append("")
        lines.append("Top sessions:")
        for s in r.sessions.prefix(top) {
            lines.append("  \(lpad(usd(s.total), 9))  \(pad(s.title, 44)) \(s.group); peak \(k(s.peakContext))"
                + (s.subagents.cost > 0 ? ", subagents \(usd(s.subagents.cost))" : ""))
        }
        lines.append("")
        lines.append("Drivers:")
        for h in r.hints.prefix(4) { lines.append("  - \(h.title): \(h.detail)") }
        if r.totals.unpricedCalls > 0 { lines.append("  (\(r.totals.unpricedCalls) calls on models without a price are left out)") }
        lines.append("")
        lines.append("Prices: \(r.priceSource) (read \(r.pricesReadOn)); list price, before any gateway discount or markup.")
        return lines.joined(separator: "\n")
    }

    static func usd(_ v: Double) -> String { String(format: "$%.2f", v) }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func k(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : "\(n / 1000)k" }
    static func pad(_ s: String, _ n: Int) -> String {
        let one = s.replacingOccurrences(of: "\n", with: " ")
        return one.count > n ? String(one.prefix(n - 1)) + "…" : one.padding(toLength: n, withPad: " ", startingAt: 0)
    }
    static func lpad(_ s: String, _ n: Int) -> String { String(repeating: " ", count: max(0, n - s.count)) + s }
}

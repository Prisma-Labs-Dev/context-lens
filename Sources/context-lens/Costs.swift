import ContextLensCore
import Foundation

/// `context-lens cost [--since today|24h|7d|30d|all] [--brief] [--top N]`: what Claude Code
/// sessions cost at list price, by group, model and session, with the biggest cost drivers.
/// `--reconcile`: computed cost against Claude Code's own running total, per session.
/// `--by model,harness,route`: spend sliced by any of the three; with route, also what the
/// gateway billed each route this month (`--no-gateway` skips the usage API).
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
    let auth = AuthWindows.load()
    let report = CostReportBuilder.build(files: files, since: since, until: until, config: CostConfig.load(), auth: auth)
    if let by = opts.flags["by"] {
        guard let dims = CostDimension.parse(by) else { fail("--by takes model, harness and route, comma-separated") }
        var gateway: [GatewayUsage] = []
        if dims.contains(.route), opts.flags["no-gateway"] == nil {
            gateway = CostGatewayCheck.run(auth: auth, files: files, window: since)
        }
        let drift = auth.drift()
        if opts.flags["json"] != nil {
            emit(CostSlicesOut(by: dims.map(\.rawValue), since: since, until: until, slices: report.slices(by: dims),
                               gateway: gateway, authDrift: drift))
        } else {
            print(CostBrief.slices(report, dims: dims, window: window, gateway: gateway, drift: drift))
        }
        return
    }
    if opts.flags["brief"] != nil {
        print(CostBrief.text(report, window: window, top: max(0, Int(opts.flags["top"] ?? "5") ?? 5)))
    } else {
        emit(report)
    }
}

struct CostSlicesOut: Encodable {
    var by: [String]
    var since: Date?
    var until: Date
    var estimate = "Dollars are estimates: Anthropic list price for Claude calls, $\(Pricing.copilotCredit) per Copilot AI credit."
    var slices: [CostSlice]
    var gateway: [GatewayUsage]
    var authDrift: [String]
}

/// What each route's gateway billed this month, against the list-price estimate of the calls
/// attributed to it in the same month.
enum CostGatewayCheck {
    static func run(auth: AuthWindows, files: [CostFileScan], window: Date?) -> [GatewayUsage] {
        let start = GatewayClient.monthStart()
        // The window may start after the month does; the month needs its own scan.
        let monthFiles = window.map { $0 <= start } ?? true ? files : CostScanner().scan(since: start)
        let month = CostReportBuilder.build(files: monthFiles, since: start, auth: auth)
        return GatewayClient.fetch(auth, estimates: month.routeEstimates)
    }
}

/// Plain text for a morning brief: totals, groups, models, top sessions and drivers.
enum CostBrief {
    static func text(_ r: CostReport, window: String, top: Int) -> String {
        var lines: [String] = []
        let t = r.totals
        lines.append("Claude cost, \(window == "all" ? "all time" : "since " + (window == "today" ? "midnight" : window + " ago")): "
            + "est. \(usd(t.cost)) at list price, \(t.calls) calls, cache hit \(pct(t.hitRatio))"
            + (r.copilotCredits > 0 ? "; Copilot \(String(format: "%.1f", r.copilotCredits)) AI credits (est. \(usd(r.copilotUSD)))" : ""))
        lines.append("By harness (est.): " + r.slices(by: [.harness]).map { "\($0.keys[0]) \(usd($0.usd))" }.joined(separator: ", "))
        lines.append("By route (est.): " + r.slices(by: [.route]).map { "\($0.keys[0]) \(usd($0.usd))" }.joined(separator: ", "))
        lines.append("Split: cache read \(usd(r.split.cacheRead)), cache write \(usd(r.split.cacheWrite)), output \(usd(r.split.output)), input \(usd(r.split.input))")
        lines.append("")
        lines.append("By group (est.):")
        for g in r.groups {
            if g.totals.calls == 0, g.credits > 0 {
                lines.append("  \(pad(g.name, 26)) \(String(format: "%7.1f cr", g.credits))  \(g.sessions) sessions")
            } else {
                lines.append("  \(pad(g.name, 26)) \(lpad(usd(g.totals.cost), 9))  \(g.sessions) sessions, \(g.totals.calls) calls, hit \(pct(g.totals.hitRatio))")
            }
        }
        lines.append("")
        lines.append("By model (est.):")
        for m in r.models {
            let x = m.totals
            lines.append("  \(pad(m.model, 20)) \(lpad(usd(x.cost), 9))  in \(k(x.input)) out \(k(x.output)) (think \(k(x.thinking))) "
                + "w5m \(k(x.cacheWrite5m)) w1h \(k(x.cacheWrite1h)) read \(k(x.cacheRead)) hit \(pct(x.hitRatio))"
                + (m.price == nil ? " UNPRICED" : ""))
        }
        lines.append("")
        lines.append("Top sessions (est.):")
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

    /// `--by`: one row per slice, then the gateway's figures per route.
    static func slices(_ r: CostReport, dims: [CostDimension], window: String, gateway: [GatewayUsage], drift: [String]) -> String {
        var lines: [String] = []
        let span = window == "all" ? "all time" : "since " + (window == "today" ? "midnight" : window + " ago")
        lines.append("Claude and Copilot spend by \(dims.map(\.rawValue).joined(separator: " x ")), \(span) (est.: list price; Copilot at \(usd(Pricing.copilotCredit)) per credit)")
        let widths = dims.map { d in max(d.rawValue.count, r.cells.map { $0.value(d).count }.max() ?? 0, 6) }
        lines.append("  " + zip(dims, widths).map { pad($0.0.rawValue, $0.1) }.joined(separator: "  ") + "  " + lpad("est. $", 10) + lpad("calls", 8) + lpad("hit", 6) + lpad("credits", 9))
        let slices = r.slices(by: dims)
        for s in slices {
            lines.append("  " + zip(s.keys, widths).map { pad($0.0, $0.1) }.joined(separator: "  ") + "  "
                + lpad(usd(s.usd), 10) + lpad("\(s.totals.calls)", 8) + lpad(s.totals.calls > 0 ? pct(s.totals.hitRatio) : "", 6)
                + lpad(s.credits > 0 ? String(format: "%.1f", s.credits) : "", 9))
        }
        let total = slices.reduce(0) { $0 + $1.usd }
        lines.append("  " + pad("total", widths.reduce(0, +) + 2 * (widths.count - 1)) + "  " + lpad(usd(total), 10))
        if !gateway.isEmpty {
            lines.append("")
            lines.append("Billed this month (usage API or quota command; est. = list price of this month's calls on the route, Copilot in credits):")
            for g in gateway {
                if let e = g.error {
                    lines.append("  \(pad(g.label, 24)) unavailable: \(e)")
                    continue
                }
                let amount = { (v: Double) -> String in g.credits ? String(format: "%.0f cr", v) : usd(v) }
                var line = "  \(pad(g.label, 24)) \(g.month) billed \(lpad(g.billed.map(amount) ?? "?", 9))"
                if let l = g.limit { line += " of \(amount(l)), \(amount(g.remaining ?? 0)) left" }
                line += "  ·  est. \(g.credits ? "" : "list ")\(amount(g.estimate))"
                if let ratio = g.ratio { line += "  ·  billed/est. \(String(format: "%.2f", ratio))" }
                if let sub = g.subscription { line += "  [\(sub)\(g.tier.map { ", " + $0 } ?? "")]" }
                lines.append(line)
            }
        }
        if r.routeEstimates[CostRoute.unknown.id] ?? 0 > 0 {
            lines.append("")
            lines.append("Unknown route: calls no window in ~/.context-lens/auth-windows.json covers. To assign them, add a window")
            lines.append("for their scope with an earlier start, such as {\"start\": \"2026-09-01T00:00:00Z\", \"scope\": \"cli\", \"route\": \"<id>\"}.")
        }
        for d in drift { lines.append("Note: \(d).") }
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

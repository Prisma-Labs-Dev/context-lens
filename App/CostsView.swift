import AppKit
import ContextLensCore
import SwiftUI

/// What sessions cost at list price, from transcript usage: by group, model and session, with
/// the cost drivers. Built with `CostScanner` and `CostReportBuilder`; `context-lens cost` prints
/// the same report.
@MainActor @Observable
final class CostsModel {
    enum Span: String, CaseIterable, Identifiable {
        case today = "Today", week = "7 days", month = "30 days"
        var id: String { rawValue }
        var since: Date {
            switch self {
            case .today: Calendar.current.startOfDay(for: Date())
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-30 * 86_400)
            }
        }
    }

    var span: Span = .week { didSet { load() } }
    /// Only sessions in this group; nil for all.
    var group: String?
    var report: CostReport?
    var loading = false
    /// How the Slices section groups spend, in this order.
    var dims: [CostDimension] = [.route]
    /// What each route's gateway billed this month, next to the list-price estimate.
    var gateway: [GatewayUsage] = []
    var gatewayLoading = false
    /// Installs set up for a route the auth windows do not have yet.
    var drift: [String] = []
    private var generation = 0

    func load() {
        generation += 1
        let since = span.since, generation = generation
        loading = true
        Task.detached {
            let files = CostScanner().scan(since: since)
            let auth = AuthWindows.load()
            let drift = auth.drift()
            let report = CostReportBuilder.build(files: files, since: since, config: CostConfig.load(), auth: auth)
            await MainActor.run {
                guard generation == self.generation else { return }
                self.report = report
                self.drift = drift
                self.loading = false
                if let g = self.group, !report.groups.contains(where: { $0.name == g }) { self.group = nil }
            }
        }
    }

    /// Asks the usage API for each route with auth in `~/.context-lens/auth-windows.json`.
    func loadGateway() {
        guard !gatewayLoading else { return }
        gatewayLoading = true
        Task.detached {
            let auth = AuthWindows.load()
            let start = GatewayClient.monthStart()
            let month = CostReportBuilder.build(files: CostScanner().scan(since: start), since: start, auth: auth)
            let usage = GatewayClient.fetch(auth, estimates: month.routeEstimates)
            await MainActor.run {
                self.gateway = usage
                self.gatewayLoading = false
            }
        }
    }

    func toggle(_ d: CostDimension) {
        if let i = dims.firstIndex(of: d) {
            if dims.count > 1 { dims.remove(at: i) }
        } else {
            dims.append(d)
        }
    }

    var sessions: [SessionCost] {
        guard let r = report else { return [] }
        if group == CostKind.copilot.label { return r.copilot }
        guard let group else { return r.sessions }
        // Subagent spend is its own group; it lists the sessions that started subagents.
        if group == CostKind.subagent.label { return r.sessions.filter { $0.subagents.calls > 0 }.sorted { $0.subagents.cost > $1.subagents.cost } }
        return r.sessions.filter { $0.group == group }
    }
}

struct CostsView: View {
    @State private var model = CostsModel()

    var body: some View {
        VStack(spacing: 0) {
            CostsHeader()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let r = model.report {
                HSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            GroupsSection(report: r)
                            SlicesSection(report: r)
                            BudgetsSection()
                            ModelsSection(report: r)
                            DriversSection(report: r)
                        }
                        .padding(.bottom, 12)
                    }
                    .frame(minWidth: 420, idealWidth: 520, maxWidth: 700)
                    .background(Theme.window)
                    SessionsTable()
                        .frame(minWidth: 560, maxWidth: .infinity)
                        .background(Theme.editor)
                }
            } else {
                Placeholder(text: model.loading ? "Reading transcripts…" : "No sessions found.")
            }
        }
        .environment(model)
        .foregroundStyle(Theme.ink)
        .tint(Theme.claude)
        .onAppear { model.load(); model.loadGateway() }
    }
}

struct CostsHeader: View {
    @Environment(CostsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            Picker("", selection: $model.span) {
                ForEach(CostsModel.Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            if let r = model.report {
                Text("est. " + Fmt.usd(r.totals.cost)).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                Text("\(r.totals.calls) calls · cache hit \(Fmt.pct(r.totals.hitRatio))")
                    .font(Theme.small).foregroundStyle(Theme.ink2)
                if r.copilotCredits > 0 {
                    Text("· Copilot \(String(format: "%.0f", r.copilotCredits)) credits (est. \(Fmt.usd(r.copilotUSD)))").font(Theme.small).foregroundStyle(Theme.ink2)
                }
            }
            Spacer(minLength: 6)
            Text("List price").font(Theme.small).foregroundStyle(Theme.ink3)
                .help("Anthropic list prices from \(Pricing.source), read \(Pricing.readOn). A gateway may bill differently.")
            if model.loading { ProgressView().controlSize(.small) }
            IconButton(systemImage: "arrow.clockwise", help: "Rescan changed transcripts and ask the gateway again") { model.load(); model.loadGateway() }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

struct GroupsSection: View {
    @Environment(CostsModel.self) private var model
    var report: CostReport

    var body: some View {
        ListSection(title: "Groups", trailing: "est. · " + (model.group == nil ? "click to filter" : "showing \(model.group!)")) {
            let top = max(report.groups.map(\.totals.cost).max() ?? 0, 0.01)
            ForEach(report.groups) { g in
                let selected = model.group == g.name
                HStack(spacing: 8) {
                    Text(g.name).lineLimit(1).frame(width: 150, alignment: .leading)
                    if g.totals.calls == 0, g.credits > 0 {
                        Text(String(format: "%.0f cr", g.credits)).font(Theme.monoSmall).frame(width: 76, alignment: .trailing)
                        Spacer()
                    } else {
                        Text(Fmt.usd(g.totals.cost)).font(Theme.monoSmall).monospacedDigit().frame(width: 76, alignment: .trailing)
                        GeometryReader { geo in
                            RoundedRectangle(cornerRadius: 2).fill(Theme.claude.opacity(0.75))
                                .frame(width: max(2, geo.size.width * g.totals.cost / top), height: 8)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    Text("\(g.sessions)").font(Theme.small).foregroundStyle(Theme.ink3).frame(width: 30, alignment: .trailing)
                        .help("sessions")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .frame(height: 24)
                .background(selected ? Theme.selection : .clear)
                .contentShape(Rectangle())
                .onTapGesture { model.group = selected ? nil : g.name }
            }
            SplitBar(split: report.split).padding(.horizontal, 14).padding(.top, 8)
        }
    }
}

/// Spend by any combination of model, harness and route; the same as `context-lens cost --by`.
struct SlicesSection: View {
    @Environment(CostsModel.self) private var model
    var report: CostReport

    var body: some View {
        let slices = report.slices(by: model.dims)
        ListSection(title: "Slices", trailing: "est.") {
            HStack(spacing: 4) {
                Text("by").font(Theme.small).foregroundStyle(Theme.ink3)
                ForEach(CostDimension.allCases) { d in
                    let on = model.dims.contains(d)
                    Button { model.toggle(d) } label: {
                        Text(on && model.dims.count > 1 ? "\(model.dims.firstIndex(of: d)! + 1) \(d.label)" : d.label)
                            .font(Theme.small)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.selection : .clear))
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .help(on ? "Stop slicing by \(d.rawValue)" : "Also slice by \(d.rawValue)")
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 4)
            let top = max(slices.map(\.usd).max() ?? 0, 0.01)
            ForEach(slices) { s in
                HStack(spacing: 8) {
                    Text(s.keys.joined(separator: " · ")).lineLimit(1).truncationMode(.tail).frame(width: 300, alignment: .leading)
                        .help(s.keys.joined(separator: "\n"))
                    Text(Fmt.usd(s.usd)).font(Theme.monoSmall).monospacedDigit().frame(width: 66, alignment: .trailing)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2).fill(Theme.claude.opacity(0.75))
                            .frame(width: max(2, geo.size.width * s.usd / top), height: 8)
                            .frame(maxHeight: .infinity)
                    }
                    Text(s.credits > 0 ? String(format: "%.0f cr", s.credits) : "\(s.totals.calls)")
                        .font(Theme.small).foregroundStyle(Theme.ink3).frame(width: 52, alignment: .trailing)
                        .help(s.credits > 0 ? "Copilot AI credits, at " + String(format: "$%.2f", Pricing.copilotCredit) + " each (est.)" : "calls")
                }
                .font(.system(size: 12))
                .padding(.horizontal, 14)
                .frame(height: 22)
            }
            if model.dims.contains(.route), report.routeEstimates[CostRoute.unknown.id] ?? 0 > 0 {
                Text("Unknown route: calls no window in ~/.context-lens/auth-windows.json covers. To assign them, add a window for their scope (cli or desktop) that starts earlier.")
                    .font(Theme.small).foregroundStyle(Theme.ink3).padding(.horizontal, 14).padding(.top, 4)
            }
        }
    }
}

/// What each budget's gateway billed this month, from its usage API, next to the list-price
/// estimate of the calls attributed to it.
struct BudgetsSection: View {
    @Environment(CostsModel.self) private var model

    var body: some View {
        if !model.gateway.isEmpty || model.gatewayLoading || !model.drift.isEmpty {
            ListSection(title: "Budgets", trailing: model.gateway.first.map { "billed, \($0.month)" } ?? (model.gatewayLoading ? "asking the gateway…" : nil)) {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                    GridRow {
                        Text("route").gridColumnAlignment(.leading)
                        Text("billed"); Text("limit"); Text("left"); Text("est."); Text("billed/est.")
                    }
                    .font(Theme.small).foregroundStyle(Theme.ink3)
                    ForEach(model.gateway) { g in
                        GridRow {
                            Text(g.label).lineLimit(1).help(g.subscription.map { "\($0)\(g.tier.map { ", " + $0 } ?? "")" } ?? "")
                            if let e = g.error {
                                Text(e).foregroundStyle(Theme.stale).lineLimit(1).gridCellColumns(5).frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                let amount = { (v: Double) -> String in g.credits ? String(format: "%.0f cr", v) : Fmt.usd(v) }
                                Text(g.billed.map(amount) ?? "?")
                                Text(g.limit.map(amount) ?? "")
                                Text(g.remaining.map(amount) ?? "").foregroundStyle(g.remaining == 0 ? Theme.stale : Theme.ink)
                                Text(amount(g.estimate))
                                Text(g.ratio.map { String(format: "%.2f", $0) } ?? "")
                            }
                        }
                        .font(Theme.monoSmall).monospacedDigit()
                    }
                }
                .padding(.horizontal, 14)
                ForEach(model.drift, id: \.self) { d in
                    Text(d).font(Theme.small).foregroundStyle(Theme.stale).padding(.horizontal, 14).padding(.top, 4)
                }
            }
        }
    }
}

/// Where the money goes by token type.
struct SplitBar: View {
    var split: TokenTotals.Split

    var body: some View {
        let parts: [(String, Double, Color)] = [
            ("cache read", split.cacheRead, Theme.codex), ("cache write", split.cacheWrite, Theme.stale),
            ("output", split.output, Theme.claude), ("input", split.input, Theme.ink3),
        ]
        let total = max(parts.reduce(0) { $0 + $1.1 }, 0.000_001)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.0) { p in
                        Rectangle().fill(p.2).frame(width: geo.size.width * p.1 / total)
                    }
                }
            }
            .frame(height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
            HStack(spacing: 10) {
                ForEach(parts, id: \.0) { p in
                    HStack(spacing: 4) {
                        Circle().fill(p.2).frame(width: 6, height: 6)
                        Text("\(p.0) \(Fmt.usd(p.1))").font(Theme.small).foregroundStyle(Theme.ink2)
                    }
                }
            }
        }
    }
}

struct ModelsSection: View {
    var report: CostReport

    var body: some View {
        ListSection(title: "Models", trailing: "tokens · est. cost") {
            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                GridRow {
                    Text("model").gridColumnAlignment(.leading)
                    Text("est. cost"); Text("input"); Text("output"); Text("thinking"); Text("write 5m"); Text("write 1h"); Text("read"); Text("hit")
                }
                .font(Theme.small).foregroundStyle(Theme.ink3)
                ForEach(report.models) { m in
                    let t = m.totals
                    GridRow {
                        Text(m.model + (m.price == nil ? " (no price)" : "")).lineLimit(1)
                        Text(Fmt.usd(t.cost)); Text(Fmt.tokens(t.input)); Text(Fmt.tokens(t.output)); Text(Fmt.tokens(t.thinking))
                        Text(Fmt.tokens(t.cacheWrite5m)); Text(Fmt.tokens(t.cacheWrite1h)); Text(Fmt.tokens(t.cacheRead)); Text(Fmt.pct(t.hitRatio))
                    }
                    .font(Theme.monoSmall).monospacedDigit()
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

struct DriversSection: View {
    var report: CostReport

    var body: some View {
        ListSection(title: "Cost drivers", trailing: nil) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(report.hints) { h in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(h.title).font(.system(size: 12, weight: .semibold))
                            Spacer()
                            Text(Fmt.usd(h.usd)).font(Theme.monoSmall).foregroundStyle(Theme.ink2)
                        }
                        Text(h.detail).font(Theme.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }
}

struct SessionsTable: View {
    @Environment(CostsModel.self) private var model
    @State private var selection: SessionCost.ID?

    var body: some View {
        Table(model.sessions, selection: $selection) {
            TableColumn("Session") { s in
                Text(s.title).lineLimit(1).help("\(s.title)\n\(s.cwd)\n\(s.models.joined(separator: ", "))")
            }
            .width(min: 180, ideal: 300)
            TableColumn("Group") { s in Text(s.group).foregroundStyle(Theme.ink2).lineLimit(1) }.width(min: 80, ideal: 120)
            TableColumn("est. Total") { s in
                Text(s.credits.map { String(format: "%.1f cr", $0) } ?? Fmt.usd(s.total)).monospacedDigit()
            }
            .width(70)
            TableColumn("Subagents") { s in Text(s.subagents.cost > 0 ? Fmt.usd(s.subagents.cost) : "").monospacedDigit() }.width(70)
            TableColumn("Calls") { s in Text("\(s.own.calls + s.subagents.calls)").monospacedDigit() }.width(50)
            TableColumn("Peak") { s in
                Text(Fmt.tokens(s.peakContext)).monospacedDigit()
                    .foregroundStyle(s.peakContext > CostReport.bigContext ? Theme.stale : Theme.ink)
            }
            .width(56)
            TableColumn("> 300k") { s in Text(s.bigCost > 0 ? Fmt.usd(s.bigCost) : "").monospacedDigit() }.width(64)
            TableColumn("Cold") { s in
                Text(s.coldRestarts > 0 ? "\(s.coldRestarts) · \(Fmt.usd(s.coldExtra))" : "").monospacedDigit()
                    .help("Calls that rewrote a cold cache after an idle gap, and the extra over warm reads")
            }
            .width(90)
            TableColumn("Hit") { s in Text(Fmt.pct(s.own.hitRatio)).monospacedDigit() }.width(40)
            TableColumn("Last") { s in Text(s.last.formatted(.relative(presentation: .named))).foregroundStyle(Theme.ink2) }.width(80)
        }
        .font(.system(size: 12))
        .contextMenu(forSelectionType: SessionCost.ID.self) { ids in
            if let id = ids.first, let s = model.sessions.first(where: { $0.id == id }) {
                Button("Reveal Transcript in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: s.file)]) }
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s.id, forType: .string)
                }
            }
        }
    }
}

enum Fmt {
    static func usd(_ v: Double) -> String { v >= 100 ? String(format: "$%.0f", v) : String(format: "$%.2f", v) }
    static func pct(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func tokens(_ n: Int) -> String {
        n >= 1_000_000 ? String(format: "%.1fM", Double(n) / 1e6) : n >= 1000 ? "\(n / 1000)k" : "\(n)"
    }
}

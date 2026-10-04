import AppKit
import ContextLensCore
import SwiftUI

/// Agent health: what `context-lens health` found across all sessions, and the proposals the
/// weekly judge wrote. Reads `~/.context-lens/health/`; nothing here writes transcripts or rules.
@MainActor @Observable
final class HealthModel {
    enum Selection: Hashable {
        case group(String)
        case proposal(String)
        case row(RowKind, String)
    }

    enum RowKind: String { case tool = "Tools", skill = "Skills", rule = "Rule files" }

    let store = HealthStore()
    var report: HealthReport?
    var proposals: [HealthProposal] = []
    var sessions: [String: HealthSession] = [:]
    var selection: Selection?
    var loading = false

    func load() {
        loading = true
        let store = store
        Task.detached {
            let report = store.report()
            let proposals = store.proposals().sorted { ($0.status == .open ? 0 : 1) < ($1.status == .open ? 0 : 1) }
            let sessions = store.latestRun().map { store.sessions(in: $0) } ?? [:]
            await MainActor.run {
                self.report = report
                self.proposals = proposals
                self.sessions = sessions
                self.loading = false
                // `-health-select <prefix>` picks the first cause whose name starts with it, for checking the UI.
                let args = ProcessInfo.processInfo.arguments
                if self.selection == nil, let i = args.firstIndex(of: "-health-select"), i + 1 < args.count,
                   let g = report?.groups.first(where: { $0.name.hasPrefix(args[i + 1]) }) {
                    self.selection = .group(g.name)
                }
                if self.selection == nil {
                    self.selection = proposals.first { $0.status == .open }.map { .proposal($0.id) }
                        ?? report?.groups.first.map { .group($0.name) }
                }
            }
        }
    }

    func setStatus(_ p: HealthProposal, _ status: HealthProposal.Status) {
        _ = try? store.setStatus(p.id, status, note: nil)
        proposals = store.proposals()
    }

    func group(_ name: String) -> FrictionGroup? { report?.groups.first { $0.name == name } }

    func open(session id: String) {
        if let link = sessions[id]?.link, let url = URL(string: link) {
            NSWorkspace.shared.open(url)
        } else if let file = sessions[id]?.file {
            NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)])
        }
    }
}

extension String {
    /// Color for a friction label: walls amber, agent mistakes red, environment blue, people violet.
    var healthColor: Color {
        switch self {
        case "guard", "permission", "auth": Theme.stale
        case "misuse": Theme.removed
        case "environment": Theme.codex
        case "correction", "repeat", "frustration", "interrupt": Theme.changed
        default: Theme.ink3
        }
    }
}

struct HealthView: View {
    @State private var model = HealthModel()

    var body: some View {
        HSplitView {
            HealthList()
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 620)
                .background(Theme.window)
            HealthDetail()
                .frame(minWidth: 460, maxWidth: .infinity)
                .background(Theme.editor)
        }
        .environment(model)
        .foregroundStyle(Theme.ink)
        .tint(Theme.claude)
        .onAppear { model.load() }
    }
}

// MARK: - List

struct HealthList: View {
    @Environment(HealthModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HealthHeader()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let r = model.report {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        TrendStrip(days: r.byDay).padding(.horizontal, 14).padding(.vertical, 10)
                        ListSection(title: "Proposals", trailing: "\(model.proposals.filter { $0.status == .open }.count) open") {
                            if model.proposals.isEmpty {
                                Text("None yet. Run context-lens health judge.").font(Theme.small).foregroundStyle(Theme.ink3).padding(.horizontal, 14)
                            }
                            ForEach(model.proposals) { p in
                                HealthRow(selection: .proposal(p.id)) {
                                    StatusDot(status: p.status)
                                    Text(p.title).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(p.status.rawValue).font(Theme.small).foregroundStyle(Theme.ink3)
                                }
                            }
                        }
                        ListSection(title: "Causes", trailing: "\(r.friction) events") {
                            ForEach(r.groups.prefix(40), id: \.name) { g in
                                HealthRow(selection: .group(g.name)) {
                                    Text("\(g.events)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink2)
                                        .frame(width: 34, alignment: .trailing)
                                    Circle().fill(g.label.healthColor).frame(width: 6, height: 6)
                                    Text(g.name).font(Theme.monoSmall).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 4)
                                    Text("\(g.sessions) sess").font(Theme.small).foregroundStyle(Theme.ink3)
                                }
                            }
                        }
                        rowSection(.tool, r.byTool)
                        rowSection(.skill, r.bySkill.filter { $0.friction > 0 })
                        rowSection(.rule, r.byRuleFile.filter { $0.friction > 0 })
                    }
                    .padding(.bottom, 12)
                }
            } else {
                Placeholder(text: model.loading ? "Loading…" : "No report yet. Run: context-lens health --since 7d")
            }
        }
    }

    private func rowSection(_ kind: HealthModel.RowKind, _ rows: [FrictionRow]) -> some View {
        ListSection(title: kind.rawValue, trailing: kind == .tool ? "events" : "per session") {
            ForEach(rows.prefix(25), id: \.name) { row in
                HealthRow(selection: .row(kind, row.name)) {
                    Text(kind == .tool ? "\(row.friction)" : String(format: "%.1f", row.perSession))
                        .font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 34, alignment: .trailing)
                    Text(row.name).font(Theme.monoSmall).lineLimit(1).truncationMode(.head)
                    Spacer(minLength: 4)
                    Text("\(row.sessions) sess").font(Theme.small).foregroundStyle(Theme.ink3)
                }
            }
        }
    }
}

struct HealthHeader: View {
    @Environment(HealthModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "stethoscope").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            Text("Agent health").font(.system(size: 13, weight: .semibold))
            if let r = model.report {
                Text("\(r.sessions) sessions · \(String(format: "%.2f", Double(r.friction) / Double(max(r.sessions, 1)))) friction per session · since \(r.since.formatted(.dateTime.month(.abbreviated).day()))")
                    .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1).layoutPriority(-1)
            }
            Spacer(minLength: 6)
            IconButton(systemImage: "arrow.clockwise", help: "Reload the latest report") { model.load() }
            IconButton(systemImage: "folder", help: "Reveal ~/.context-lens/health") {
                NSWorkspace.shared.activateFileViewerSelecting([model.store.root.appending(path: "report.json")])
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

/// Friction per day as bars, sessions underneath.
struct TrendStrip: View {
    var days: [HealthDay]

    var body: some View {
        let peak = max(days.map(\.friction).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: "Friction per day", trailing: "\(days.map(\.friction).reduce(0, +)) total")
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(days, id: \.day) { d in
                    VStack(spacing: 3) {
                        Text("\(d.friction)").font(.system(size: 9)).monospacedDigit().foregroundStyle(Theme.ink3)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.ink2.opacity(0.55))
                            .frame(height: max(2, CGFloat(d.friction) / CGFloat(peak) * 44))
                        Text(String(d.day.suffix(5))).font(.system(size: 9)).monospacedDigit().foregroundStyle(Theme.ink3)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(d.day): \(d.friction) friction events in \(d.sessions) sessions, \(d.toolCalls) tool calls")
                }
            }
            .frame(height: 70, alignment: .bottom)
        }
    }
}

struct ListSection<Content: View>: View {
    var title: String
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: title, trailing: trailing).padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            content
        }
    }
}

struct HealthRow<Content: View>: View {
    @Environment(HealthModel.self) private var model
    var selection: HealthModel.Selection
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        let selected = model.selection == selection
        HStack(spacing: 7) { content }
            .font(.system(size: 12))
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(selected ? Theme.selection : hovering ? Theme.hover : .clear)
            .contentShape(Rectangle())
            .onTapGesture { model.selection = selection }
            .onHover { hovering = $0 }
    }
}

struct StatusDot: View {
    var status: HealthProposal.Status

    var body: some View {
        Circle()
            .strokeBorder(status == .open ? Theme.claude : Theme.ink3, lineWidth: 1.2)
            .background(Circle().fill(status == .applied ? Theme.added : status == .briefed ? Theme.preset : .clear))
            .frame(width: 8, height: 8)
    }
}

// MARK: - Detail

struct HealthDetail: View {
    @Environment(HealthModel.self) private var model

    var body: some View {
        switch model.selection {
        case .group(let name)?:
            if let g = model.group(name) { GroupDetail(group: g) } else { Placeholder(text: "This cause is not in the latest report.") }
        case .proposal(let id)?:
            if let p = model.proposals.first(where: { $0.id == id }) { ProposalDetail(proposal: p) } else { Placeholder(text: "Proposal not found.") }
        case .row(let kind, let name)?:
            RowDetail(kind: kind, name: name)
        case nil:
            Placeholder(text: "Pick a cause or a proposal.")
        }
    }
}

struct DetailScroll<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
    }
}

struct Facts: View {
    var items: [(String, String)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.0) { k, v in
                HStack(spacing: 4) {
                    Text(v).font(.system(size: 12, weight: .semibold)).monospacedDigit()
                    Text(k).font(Theme.small).foregroundStyle(Theme.ink3)
                }
            }
        }
    }
}

struct CodeBlock: View {
    var text: String
    var tint: Color?

    var body: some View {
        Text(text)
            .font(Theme.mono)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 6).fill(tint.map { $0.opacity(0.08) } ?? Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.hairline))
    }
}

struct SessionLine: View {
    @Environment(HealthModel.self) private var model
    var id: String
    var detail: String?

    var body: some View {
        let s = model.sessions[id]
        HStack(spacing: 7) {
            Circle().fill(s?.harness == "claude" ? Theme.claude : Theme.codex).frame(width: 6, height: 6)
            Text(s?.title ?? id).lineLimit(1)
            if let detail { Text(detail).font(Theme.small).foregroundStyle(Theme.ink3) }
            Spacer(minLength: 6)
            QuietButton(title: s?.link == nil ? "Reveal" : "Open", systemImage: s?.link == nil ? "doc" : "arrow.up.right") { model.open(session: id) }
        }
        .font(.system(size: 12))
    }
}

struct GroupDetail: View {
    @Environment(HealthModel.self) private var model
    var group: FrictionGroup

    var body: some View {
        DetailScroll {
            HStack(spacing: 6) {
                Circle().fill(group.label.healthColor).frame(width: 7, height: 7)
                Text(group.label).font(Theme.small).foregroundStyle(group.label.healthColor)
            }
            Text(group.name).font(.system(size: 15, weight: .semibold, design: .monospaced))
            Facts(items: [("events", "\(group.events)"), ("sessions", "\(group.sessions)"), ("retries", "\(group.retries)"),
                          ("cost 1–4", String(format: "%.1f", group.severity))])
            let related = model.proposals.filter { $0.group == group.name }
            if !related.isEmpty {
                SectionHeader(title: "Proposals")
                ForEach(related) { p in
                    HStack(spacing: 7) {
                        StatusDot(status: p.status)
                        Text(p.title).lineLimit(1)
                        Spacer()
                        QuietButton(title: "Show", systemImage: "arrow.right") { model.selection = .proposal(p.id) }
                    }.font(.system(size: 12))
                }
            }
            SectionHeader(title: "Example")
            SessionLine(id: group.example.session, detail: group.example.time?.formatted(date: .abbreviated, time: .shortened))
            if let line = group.example.line, !line.isEmpty { CodeBlock(text: line, tint: group.label.healthColor) }
            if let input = group.example.input, !input.isEmpty {
                Text("Command").font(Theme.small).foregroundStyle(Theme.ink3)
                CodeBlock(text: input)
            }
            Text("Output").font(Theme.small).foregroundStyle(Theme.ink3)
            CodeBlock(text: group.example.text)
            if group.variants.count > 1 { CountList(title: "Failing lines", counts: group.variants, mono: true) }
            CountList(title: "Tools and programs", counts: group.sources, mono: true)
            SectionHeader(title: "Sessions with the most")
            ForEach(group.sessionIDs, id: \.self) { SessionLine(id: $0) }
        }
    }
}

struct CountList: View {
    var title: String
    var counts: [String: Int]
    var mono = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionHeader(title: title)
            ForEach(counts.sorted { ($0.value, $0.key) > ($1.value, $1.key) }, id: \.key) { k, v in
                HStack(spacing: 8) {
                    Text("\(v)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 34, alignment: .trailing)
                    Text(k).font(mono ? Theme.monoSmall : .system(size: 12)).lineLimit(1)
                }
            }
        }
    }
}

struct ProposalDetail: View {
    @Environment(HealthModel.self) private var model
    var proposal: HealthProposal

    var body: some View {
        let p = proposal
        DetailScroll {
            HStack(spacing: 8) {
                StatusDot(status: p.status)
                Text(p.status.rawValue).font(Theme.small).foregroundStyle(Theme.ink2)
                Text("· \(p.kind) · \(p.author) · \(p.created.formatted(date: .abbreviated, time: .omitted))").font(Theme.small).foregroundStyle(Theme.ink3)
                Spacer()
                Menu("Set status") {
                    ForEach(HealthProposal.Status.allCases, id: \.self) { s in
                        Button(s.rawValue) { model.setStatus(p, s) }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.system(size: 12))
            }
            Text(p.title).font(.system(size: 15, weight: .semibold))
            Text(p.target).font(Theme.mono).foregroundStyle(Theme.ink2)
            Text(p.summary).font(Theme.body).fixedSize(horizontal: false, vertical: true)
            SectionHeader(title: "Edit")
            CodeBlock(text: p.edit, tint: Theme.preset)
            SectionHeader(title: "Evidence")
            let now = p.group.flatMap { model.group($0)?.events }
            Facts(items: [("events", "\(p.events)"), ("sessions", "\(p.sessions)")]
                + (p.baselineEvents.map { [("at decision", "\($0)")] } ?? [])
                + [("this week", now.map(String.init) ?? "0")])
            if let g = p.group {
                HStack(spacing: 6) {
                    Text(g).font(Theme.monoSmall).lineLimit(1)
                    Spacer()
                    if model.group(g) != nil { QuietButton(title: "Show cause", systemImage: "arrow.right") { model.selection = .group(g) } }
                }
            }
            ForEach(Array(p.quotes.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 4) {
                    SessionLine(id: q.session)
                    CodeBlock(text: q.text)
                }
            }
            if let note = p.note { Text(note).font(Theme.small).foregroundStyle(Theme.ink2) }
        }
    }
}

struct RowDetail: View {
    @Environment(HealthModel.self) private var model
    var kind: HealthModel.RowKind
    var name: String

    var body: some View {
        let rows = kind == .tool ? model.report?.byTool : kind == .skill ? model.report?.bySkill : model.report?.byRuleFile
        if let row = rows?.first(where: { $0.name == name }) {
            DetailScroll {
                Text(kind.rawValue).font(Theme.small).foregroundStyle(Theme.ink3)
                Text(row.name).font(.system(size: 15, weight: .semibold, design: .monospaced))
                Facts(items: [("friction", "\(row.friction)"), ("sessions", "\(row.sessions)"), ("per session", String(format: "%.2f", row.perSession))])
                if kind != .tool {
                    Text("Friction in sessions that loaded this \(kind == .skill ? "skill" : "file"). A correlation: hard repos load more rules.")
                        .font(Theme.small).foregroundStyle(Theme.ink3)
                }
                CountList(title: "By label", counts: row.labels)
                if kind == .tool, let groups = model.report?.groups.filter({ $0.sources[name] != nil }), !groups.isEmpty {
                    SectionHeader(title: "Causes")
                    ForEach(groups, id: \.name) { g in
                        HStack(spacing: 7) {
                            Text("\(g.sources[name] ?? 0)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 34, alignment: .trailing)
                            Circle().fill(g.label.healthColor).frame(width: 6, height: 6)
                            Text(g.name).font(Theme.monoSmall).lineLimit(1)
                            Spacer()
                            QuietButton(title: "Show", systemImage: "arrow.right") { model.selection = .group(g.name) }
                        }
                    }
                }
            }
        } else {
            Placeholder(text: "Not in the latest report.")
        }
    }
}

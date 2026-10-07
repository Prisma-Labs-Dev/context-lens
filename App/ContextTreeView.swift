import ContextLensCore
import SwiftUI

/// Everything the harness gets, grouped by kind like a file explorer.
struct ContextTreeView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        if let snap = model.snapshot {
            VStack(spacing: 0) {
                if let s = model.selectedSession {
                    SessionBanner(session: s, snapshot: snap)
                } else if !model.sessionsHere.isEmpty {
                    SkillsHint()
                }
                if model.presetIsActive { PresetBar() }
                SummaryStrip(snapshot: snap)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if let s = model.selectedSession {
                    if let growth = model.growth { ContextGrowthSection(growth: growth) }
                    if let skills = model.sessionSkills, skills.id == s.id { SessionSkillsSection(skills: skills) }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            // One flat row per header or item. With whole sections as the lazy
                            // stack's children, every hover change re-placed a section of dozens of
                            // rows, which moved hover targets again: a layout loop on the main thread.
                            ForEach(model.treeEntries(of: snap)) { entry in
                                switch entry {
                                case .header(let kind, let count, let tokens, let open):
                                    TreeHeader(kind: kind, count: count, tokens: tokens, open: open)
                                case .item(let item):
                                    TreeRow(item: item, selected: model.selectedItemID == item.id, editable: model.canEditPreset)
                                        .onTapGesture { model.selectedItemID = item.id }
                                }
                            }
                            if !snap.notes.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(snap.notes, id: \.self) {
                                        Text($0).font(Theme.small).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .focusable()
                    .focusEffectDisabled()
                    .focused($focused)
                    .onKeyPress(.downArrow) { model.moveItemSelection(1); scrollTo(proxy); return .handled }
                    .onKeyPress(.upArrow) { model.moveItemSelection(-1); scrollTo(proxy); return .handled }
                    .simultaneousGesture(TapGesture().onEnded { focused = true })
                }
                .opacity(model.loadingSnapshot ? 0.4 : 1)
                .overlay { if model.loadingSnapshot { ProgressView().controlSize(.small) } }
            }
        } else if let dir = model.selectedDirectory, model.needsAccess(dir) {
            AccessPlaceholder()
        } else {
            Placeholder(text: model.loadingSnapshot ? "Loading…" : "Pick a folder on the left.")
        }
    }

    private func scrollTo(_ proxy: ScrollViewProxy) {
        if let id = model.selectedItemID { proxy.scrollTo(TreeEntry.id(item: id)) }
    }
}

struct Placeholder: View {
    var text: String

    var body: some View {
        Text(text).font(Theme.body).foregroundStyle(Theme.ink3).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A folder in Documents, Desktop, iCloud Drive or another guarded place, before the app has
/// Full Disk Access.
struct AccessPlaceholder: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock").font(.system(size: 20)).foregroundStyle(Theme.ink3)
            Text("macOS guards this folder. Give Context Lens Full Disk Access to read it, and every other guarded session folder, without a prompt for each.")
                .font(Theme.body).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 380)
            QuietButton(title: "Open Full Disk Access settings", systemImage: "gearshape", tint: Theme.ink) { model.openFullDiskAccessSettings() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when the tree comes from a past session rather than today's files.
struct SessionBanner: View {
    @Environment(AppModel.self) private var model
    var session: SessionSummary
    var snapshot: ContextSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(Theme.changed).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Text("Recorded \(session.date.formatted(date: .abbreviated, time: .shortened)). Files may have changed since.")
                    .font(Theme.small).foregroundStyle(Theme.ink2)
                if let launch = model.launch(for: session) {
                    Label("Launched with the \(launch.presetName) preset", systemImage: "slider.horizontal.3")
                        .font(Theme.small).foregroundStyle(Theme.preset)
                }
            }
            Spacer(minLength: 4)
            QuietButton(title: "Back to now", tint: Theme.ink2) { model.select(source: .now) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Theme.changed.opacity(0.08))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// The skills a past session used, in order of first use. A skill opens in the Skills window.
struct SessionSkillsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    var skills: SessionSkills

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.ink3)
                Text("Skills used").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink2)
                Text(skills.skills.isEmpty ? "none" : "\(skills.skills.count)").font(Theme.small).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 12)
            .padding(.top, 7)
            .padding(.bottom, skills.skills.isEmpty ? 7 : 3)
            // Subagents can read many skills; past a few rows the list scrolls so the tree keeps its room.
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(skills.skills) { skill in
                        SessionSkillRow(skill: skill, started: skills.started, highlighted: model.highlightedSkill == skill.name) {
                            model.skillsRequest = skill.name
                            openWindow(id: "skills")
                            NSApp.activate()
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(skills.skills.count, 7)) * 22)
            .scrollDisabled(skills.skills.count <= 7)
        }
        .padding(.bottom, skills.skills.isEmpty ? 0 : 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// In Now mode, where to find the skills a session used.
struct SkillsHint: View {
    var body: some View {
        Label("Skills used shows for a past session: pick one from the Now menu above, or open Skills (⇧⌘K) › By session.",
              systemImage: "sparkles")
            .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(2)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// One skill in a session: name, how it ran, how often, and when it first ran.
struct SessionSkillRow: View {
    var skill: SessionSkill
    var started: Date?
    var highlighted = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            Text(skill.name).lineLimit(1)
            if !skill.installed { Text("not installed").font(Theme.small).foregroundStyle(Theme.ink3) }
            if skill.failures > 0 { Text("\(skill.failures) failed").font(Theme.small).foregroundStyle(Theme.removed) }
            Spacer(minLength: 6)
            Text(triggers).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1)
            Text("×\(skill.uses)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink2).frame(minWidth: 26, alignment: .trailing)
            Text(when).font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink3).frame(minWidth: 96, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .background(highlighted ? Theme.selection : hovering ? Theme.hover : .clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
        .help("Show \(skill.name) in Skills")
    }

    private var triggers: String {
        skill.triggers.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
            .map { SkillEvent.Trigger(rawValue: $0.key)?.label ?? $0.key }
            .joined(separator: ", ")
    }

    /// Time of first use, and how far into the session that was.
    private var when: String {
        guard let first = skill.firstUsed else { return "" }
        let time = first.formatted(date: .omitted, time: .shortened)
        guard let started, first >= started else { return time }
        let minutes = Int(first.timeIntervalSince(started) / 60)
        let offset = minutes < 60 ? "+\(minutes)m" : "+\(minutes / 60)h\(String(format: "%02d", minutes % 60))"
        return "\(time) (\(offset))"
    }
}

/// Token totals, a budget bar, and the problems filter. Where Claude Code reported a real number
/// (a recorded session's API usage, or `/context` for Now), that leads and the bar attributes it
/// segment by segment, with what nothing explains as its own Unattributed segment.
struct SummaryStrip: View {
    @Environment(AppModel.self) private var model
    var snapshot: ContextSnapshot

    var body: some View {
        @Bindable var model = model
        let growth = model.presetIsActive ? nil : model.growth
        let measured = model.presetIsActive || !model.measuredApplies ? nil : model.measured
        let attribution = growth != nil ? model.attribution : measured.map(ContextAttribution.measured)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let growth, let first = growth.firstCall {
                    Text(Format.tokens(first)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("measured on the first call").font(Theme.small).foregroundStyle(Theme.ink2)
                    Text(sessionFigures(growth)).font(Theme.small).monospacedDigit().foregroundStyle(Theme.ink3).lineLimit(1)
                } else if let measured {
                    Text(Format.tokens(measured.used)).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text("measured by claude /context").font(Theme.small).foregroundStyle(Theme.ink2)
                    MeasureButton()
                    MeasurementHistory()
                } else {
                    if model.presetIsActive, let base = model.baseSnapshot, base.startingTokens != snapshot.startingTokens {
                        Text("≈\(Format.tokens(base.startingTokens))").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink3).strikethrough()
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                    }
                    Text("≈\(Format.tokens(snapshot.startingTokens))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(model.presetIsActive ? Theme.preset : Theme.ink)
                    Text(model.presetIsActive ? "tokens with \(model.preset.name)" : "tokens before the first message").font(Theme.small).foregroundStyle(Theme.ink2)
                    if model.measuredApplies, !model.presetIsActive { MeasureButton() }
                }
                Spacer()
                ProblemsToggle(count: snapshot.problemCount, on: $model.onlyProblems)
            }
            if let growth, growth.firstCall != nil {
                Text(sessionSource(growth, attribution))
                    .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.middle)
                    .help(attribution?.measurement.map { "Built-in tools, MCP tool schemas and the harness prompt come from claude /context in \($0.folder), \(Format.dateTime($0.measuredAt)). The session may have loaded a different setup." } ?? "")
            } else if let measured {
                Text("≈\(Format.tokens(snapshot.startingTokens)) estimated from files · Claude Code CLI, measured \(Format.dateTime(measured.measuredAt))\(measured.fromTranscript ? " (a /context run in a transcript)" : "")")
                    .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
                    .help("Measured in a clean login shell in this folder. Claude Desktop adds its own MCP tools, so a Desktop session starts larger.")
                if let previous = model.previousMeasurement {
                    MeasurementDiff(current: measured, previous: previous)
                }
            }
            if let error = model.measureError {
                Text(error).font(Theme.small).foregroundStyle(Theme.stale).lineLimit(2)
            }
            if let attribution {
                AttributionBar(attribution: attribution)
            } else {
                BudgetBar(snapshot: snapshot, extra: extraParts(growth: growth))
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    /// "· last 92.1k · peak 140.2k · 2 compactions"
    private func sessionFigures(_ g: ContextGrowth) -> String {
        var parts: [String] = []
        if let last = g.last, g.calls.count > 1 { parts.append("last \(Format.tokens(last))") }
        if g.peak != g.last { parts.append("peak \(Format.tokens(g.peak))") }
        if !g.compactions.isEmpty { parts.append("\(g.compactions.count) compaction\(g.compactions.count == 1 ? "" : "s")") }
        return parts.map { "· " + $0 }.joined(separator: " ")
    }

    /// "Tools and MCP schemas measured 7 Oct 15:00, may differ from the session · API usage, CLI"
    private func sessionSource(_ g: ContextGrowth, _ a: ContextAttribution?) -> String {
        let what: String
        if let m = a?.measurement {
            what = "Tools and MCP schemas measured \(Format.dateTime(m.measuredAt)), may differ from the session"
        } else if a != nil {
            what = "No /context measurement of this folder: tools and MCP schemas unattributed"
        } else {
            what = "≈\(Format.tokens(snapshot.startingTokens)) estimated from the transcript"
        }
        return "\(what) · API usage, \(g.harnessLabel)"
    }

    /// Before the attribution loads: the first message and what the transcript doesn't record.
    private func extraParts(growth: ContextGrowth?) -> [BudgetBar.Part] {
        guard let growth, let hidden = growth.hiddenTokens(estimated: snapshot.startingTokens) else { return [] }
        return [
            .init(id: "first-message", title: "First message", tokens: growth.firstMessageTokens, color: Theme.ink2),
            .init(id: "hidden", title: "Not in transcript", tokens: hidden, color: Theme.ink3.opacity(0.45)),
        ]
    }
}

/// Runs `claude -p "/context"` for the folder, or again to add to its history.
struct MeasureButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Button { model.measure() } label: {
            HStack(spacing: 3) {
                if model.measuring {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: model.measured == nil ? "gauge.with.dots.needle.33percent" : "arrow.clockwise").font(.system(size: 9.5))
                }
                Text(model.measured == nil ? "Measure" : "Measure again")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.ink2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(model.measuring)
        .help("Run claude -p \"/context\" in this folder: a few seconds, no tokens. Counts the built-in tools and MCP tool schemas no file shows. Earlier measurements stay in the history.")
    }
}

/// Earlier measurements of the folder, to show one and compare it with the one before.
struct MeasurementHistory: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.measuredHistory.count > 1 {
            Menu {
                ForEach(model.measuredHistory.reversed(), id: \.measuredAt) { m in
                    Button {
                        model.showMeasurement(m)
                    } label: {
                        Text("\(m == model.measured ? "✓ " : "")\(Format.dateTime(m.measuredAt))  \(Format.tokens(m.used))\(m.fromTranscript ? "  (transcript)" : "")")
                    }
                }
            } label: {
                Text("History \(model.measuredHistory.count)").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Every measurement of this folder. Pick one to show it, compared with the one before.")
        }
    }
}

/// "vs 7 Oct 15:00: −32.5k · plugin_garden_garden −31.6k · Built-in tools −0.4k"
struct MeasurementDiff: View {
    var current: MeasuredContext
    var previous: MeasuredContext

    var body: some View {
        let a = ContextAttribution.measured(current), b = ContextAttribution.measured(previous)
        let ids = (a.segments + b.segments).map(\.id).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let changes = ids.compactMap { id -> (String, Int)? in
            let x = a.segments.first { $0.id == id }, y = b.segments.first { $0.id == id }
            let d = (x?.tokens ?? 0) - (y?.tokens ?? 0)
            return abs(d) >= 100 ? ((x ?? y)!.title, d) : nil
        }.sorted { abs($0.1) > abs($1.1) }
        let total = current.used - previous.used
        Text((["vs \(Format.dateTime(previous.measuredAt)): \(Format.signed(total))"] + changes.prefix(4).map { "\($0.0) \(Format.signed($0.1))" }).joined(separator: " · "))
            .font(Theme.small).monospacedDigit().foregroundStyle(total < 0 ? Theme.added : (total > 0 ? Theme.removed : Theme.ink3))
            .lineLimit(1).truncationMode(.tail)
            .help(changes.map { "\($0.0): \(Format.signed($0.1))" }.joined(separator: "\n"))
    }
}

/// The measured total split into named segments. The legend's values are rounded so they sum to
/// the rounded total; hover a segment for what it holds and where its number comes from.
struct AttributionBar: View {
    var attribution: ContextAttribution

    var body: some View {
        let parts = attribution.segments
        let positive = parts.filter { $0.tokens > 0 }
        let total = max(1, positive.reduce(0) { $0 + $1.tokens })
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(positive) { part in
                        Rectangle()
                            .fill(color(part))
                            .frame(width: max(2, (geo.size.width - CGFloat(positive.count - 1)) * CGFloat(part.tokens) / CGFloat(total)))
                            .help(help(part))
                    }
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(parts) { part in
                    HStack(spacing: 4) {
                        Circle().fill(color(part)).frame(width: 6, height: 6)
                        Text(part.title).foregroundStyle(part.id == "unattributed" ? Theme.ink : Theme.ink2)
                        Text((part.id == "unattributed" ? "≈" : "") + Format.k(part.shown)).foregroundStyle(Theme.ink3).monospacedDigit()
                    }
                    .font(.system(size: 10.5))
                    .help(help(part))
                }
                Text("= \(Format.k(attribution.shownTotal))").font(.system(size: 10.5)).monospacedDigit().foregroundStyle(Theme.ink3)
                    .help(attribution.rounding)
            }
        }
    }

    private func color(_ p: ContextAttribution.Segment) -> Color {
        switch p.id {
        case "harness-prompt": ContextKind.systemPrompt.color
        case "built-in-tools": Theme.ink3.opacity(0.55)
        case "instructions": ContextKind.instructions.color
        case "skills": ContextKind.skill.color
        case "subagents": ContextKind.agent.color
        case "environment": ContextKind.environment.color
        case "reminders": ContextKind.hook.color
        case "first-message": Theme.ink2
        case "unattributed", "rounding": Theme.ink3.opacity(0.25)
        default: p.isMCP || p.id == "mcp-other" ? ContextKind.mcp.color.opacity(p.schemas == nil ? 0.45 : 1) : Theme.ink3
        }
    }

    private func help(_ p: ContextAttribution.Segment) -> String {
        var lines = ["\(p.title): \(p.tokens) tokens"]
        if let d = p.detail, !d.isEmpty { lines.append(d) }
        switch p.basis {
        case .measured: lines.append(attribution.measurement.map { "Counted by claude /context, \(Format.dateTime($0.measuredAt)) in \($0.folder)" } ?? "Counted by Claude Code")
        case .estimated: lines.append("Estimated from the transcript text" + (attribution.calibration.map { String(format: ", scaled ×%.2f", $0) } ?? ""))
        case .mixed:
            let from = p.schemasFrom ?? attribution.measurement
            lines.append("Schemas counted by claude /context" + (from.map { ", \(Format.dateTime($0.measuredAt)) in \($0.folder)" } ?? "") + "; instructions estimated from the transcript")
            if p.schemasFrom != nil { lines.append("The folder's own measurement doesn't have this server, so its schemas come from the nearest measurement that does.") }
        case .remainder:
            lines.append("The measured total minus everything attributed. Likely causes:")
            lines += attribution.causes.map { "• " + $0 }
        }
        return lines.joined(separator: "\n")
    }
}

struct ProblemsToggle: View {
    var count: Int
    @Binding var on: Bool

    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle\(on ? ".fill" : "")").font(.system(size: 10))
                Text(on ? "Problems only" : "\(count) problems").monospacedDigit()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(count == 0 ? Theme.ink3 : Theme.stale)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.stale.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(count == 0 && !on)
        .help("Stale paths, and files that changed since the session read them")
    }
}

struct BudgetBar: View {
    struct Part {
        var id: String
        var title: String
        var tokens: Int
        var color: Color
    }

    var snapshot: ContextSnapshot
    /// Measured parts no file or transcript shows, after the kinds.
    var extra: [Part] = []

    var parts: [Part] {
        let kinds = snapshot.sections.map { s in
            Part(id: s.kind.rawValue, title: s.kind.title, tokens: s.items.reduce(0) { $0 + $1.startingTokens }, color: s.kind.color)
        }
        return (kinds + extra).filter { $0.tokens > 0 }
    }

    var body: some View {
        let parts = parts
        let total = max(parts.reduce(0) { $0 + $1.tokens }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.id) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(2, (geo.size.width - CGFloat(parts.count - 1)) * CGFloat(part.tokens) / CGFloat(total)))
                            .help("\(part.title): ≈\(Format.tokens(part.tokens)) tokens")
                    }
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(parts, id: \.id) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.color).frame(width: 6, height: 6)
                        Text(part.title).foregroundStyle(Theme.ink2)
                        Text(Format.tokens(part.tokens)).foregroundStyle(Theme.ink3).monospacedDigit()
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
    }
}

/// A group's header in the tree. Click to fold the group.
struct TreeHeader: View {
    @Environment(AppModel.self) private var model
    var kind: ContextKind
    var count: Int
    var tokens: Int
    var open: Bool
    @State private var hovering = false

    var body: some View {
        Button { model.toggle(kind) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .bold))
                    .rotationEffect(.degrees(open ? 90 : 0))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 10)
                Text(kind.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
                Text("\(count)").font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                Spacer()
                if model.canEditPreset, let group = Preset.Group(kind: kind) {
                    GroupSwitch(group: group)
                }
                if let mcp = mcpTotal {
                    Text(Format.tokens(mcp)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.ink3)
                        .help("Tool schemas and instructions of every MCP server, schemas from claude /context")
                } else if tokens > 0 {
                    Text(Format.tokens(tokens)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.ink3)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(hovering ? Theme.hover.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .padding(.top, 4)
    }

    /// A session's MCP servers at their real cost, once the attribution has their schemas.
    private var mcpTotal: Int? {
        guard kind == .mcp, let a = model.attribution, a.segments.contains(where: { $0.isMCP && $0.schemas != nil }) else { return nil }
        return a.segments.filter(\.isMCP).reduce(0) { $0 + $1.tokens }
    }
}

struct TreeRow: View {
    @Environment(AppModel.self) private var model
    var item: ContextItem
    var selected: Bool
    var editable = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 7) {
            if editable { PresetToggle(item: item).padding(.leading, -20) }
            Image(systemName: item.kind.symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(item.kind.color)
                .frame(width: 14)
            Text(name).font(.system(size: 12.5)).lineLimit(1).layoutPriority(1)
                .strikethrough(item.presetOff != nil, color: Theme.ink3)
            if let location {
                Text(location).font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            if item.presetOff != nil {
                Text("off").font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.preset).lineLimit(1)
            } else if item.load != .always {
                Text(item.load.short).font(.system(size: 10)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            if !item.issues.isEmpty {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(Theme.stale)
                    .help(item.issues.map(\.message).joined(separator: "\n"))
            }
            if item.diskStatus == .changed || item.diskStatus == .deleted {
                Text(item.diskStatus == .changed ? "M" : "D")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(Theme.changed)
                    .help(item.diskStatus == .changed ? "Changed since this session read it" : "Deleted since this session read it")
            }
            Text(tokens)
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.ink3)
                .frame(minWidth: 30, alignment: .trailing)
                .help(mcpCost.map { "\($0.detail ?? ""). Tool schemas are sent with the tool definitions, which the transcript doesn't record." } ?? "")
        }
        .padding(.leading, editable ? 34 : 28)
        .padding(.trailing, 12)
        .frame(height: 22)
        .background(selected ? Theme.selection : (hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .opacity(item.load == .onDemand || item.load == .inactive ? 0.62 : 1)
    }

    private var isFile: Bool {
        item.path != nil && ![.skill, .agent, .mcp, .hook].contains(item.kind) && !item.title.hasPrefix("@")
    }

    private var name: String {
        isFile ? URL(filePath: item.path!).lastPathComponent : item.title
    }

    /// A session's MCP row holds the server's instructions; with a measurement, its real cost adds
    /// the tool schemas.
    private var mcpCost: ContextAttribution.Segment? {
        guard item.kind == .mcp, item.scope == "Server instructions" else { return nil }
        return model.attribution?.mcp(item.title)
    }

    private var tokens: String {
        guard item.kind == .mcp, item.scope == "Server instructions" else { return Format.tokens(item.tokens) }
        if let cost = mcpCost, cost.schemas != nil { return Format.tokens(cost.tokens) }
        return "\(Format.tokens(item.tokens)) + schemas unknown"
    }

    private var location: String? {
        // A session's MCP rows hold the server's instructions; its tool schemas are not in the transcript.
        if item.kind == .mcp, item.scope == "Server instructions" {
            if let cost = mcpCost, let schemas = cost.schemas {
                return "schemas \(Format.tokens(schemas)) + instructions \(Format.tokens(cost.instructions ?? 0))"
            }
            return "instructions only"
        }
        guard isFile, let slash = item.title.lastIndex(of: "/") else { return nil }
        return String(item.title[..<slash])
    }
}

/// "All on / all off" for a group of items in a custom preset.
struct GroupSwitch: View {
    @Environment(AppModel.self) private var model
    var group: Preset.Group

    var body: some View {
        let state = model.groupState(group)
        let allOff = state.on == 0 && state.total > 0
        Button { model.setGroup(group, off: !allOff) } label: {
            Text(allOff ? "Turn all on" : (state.on == state.total ? "Turn all off" : "\(state.on)/\(state.total) on · all off"))
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.preset)
        }
        .buttonStyle(.plain)
        .help(allOff ? "Switch every item in this group back on" : "Switch off this whole group, including items added to disk later")
    }
}

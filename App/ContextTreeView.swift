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
                    if let skills = model.sessionSkills, skills.id == s.id { SessionSkillsSection(skills: skills) }
                }
                if model.presetIsActive { PresetBar() }
                SummaryStrip(snapshot: snap)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.visibleSections(of: snap), id: \.kind) { section in
                                TreeSection(kind: section.kind, items: section.items)
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
        if let id = model.selectedItemID { proxy.scrollTo(id) }
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
            ForEach(skills.skills) { skill in
                SessionSkillRow(skill: skill, started: skills.started, highlighted: model.highlightedSkill == skill.name) {
                    model.skillsRequest = skill.name
                    openWindow(id: "skills")
                    NSApp.activate()
                }
            }
        }
        .padding(.bottom, skills.skills.isEmpty ? 0 : 5)
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

/// Token total, a budget bar by kind, and the problems filter.
struct SummaryStrip: View {
    @Environment(AppModel.self) private var model
    var snapshot: ContextSnapshot

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if model.presetIsActive, let base = model.baseSnapshot, base.startingTokens != snapshot.startingTokens {
                    Text("≈\(Format.tokens(base.startingTokens))").font(.system(size: 13)).monospacedDigit().foregroundStyle(Theme.ink3).strikethrough()
                    Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
                }
                Text("≈\(Format.tokens(snapshot.startingTokens))").font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(model.presetIsActive ? Theme.preset : Theme.ink)
                Text(model.presetIsActive ? "tokens with \(model.preset.name)" : "tokens before the first message").font(Theme.small).foregroundStyle(Theme.ink2)
                Spacer()
                ProblemsToggle(count: snapshot.problemCount, on: $model.onlyProblems)
            }
            BudgetBar(snapshot: snapshot)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
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
    var snapshot: ContextSnapshot

    var parts: [(kind: ContextKind, tokens: Int)] {
        snapshot.sections.map { ($0.kind, $0.items.reduce(0) { $0 + $1.startingTokens }) }.filter { $0.1 > 0 }
    }

    var body: some View {
        let total = max(parts.reduce(0) { $0 + $1.tokens }, 1)
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(parts, id: \.kind) { part in
                        Rectangle()
                            .fill(part.kind.color)
                            .frame(width: max(2, (geo.size.width - CGFloat(parts.count - 1)) * CGFloat(part.tokens) / CGFloat(total)))
                            .help("\(part.kind.title): ≈\(Format.tokens(part.tokens)) tokens")
                    }
                }
            }
            .frame(height: 4)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            FlowLayout(spacing: 10, lineSpacing: 3) {
                ForEach(parts, id: \.kind) { part in
                    HStack(spacing: 4) {
                        Circle().fill(part.kind.color).frame(width: 6, height: 6)
                        Text(part.kind.title).foregroundStyle(Theme.ink2)
                        Text(Format.tokens(part.tokens)).foregroundStyle(Theme.ink3).monospacedDigit()
                    }
                    .font(.system(size: 10.5))
                }
            }
        }
    }
}

struct TreeSection: View {
    @Environment(AppModel.self) private var model
    var kind: ContextKind
    var items: [ContextItem]
    @State private var hovering = false

    var body: some View {
        let open = !model.collapsed.contains(kind)
        let tokens = items.reduce(0) { $0 + $1.startingTokens }
        VStack(alignment: .leading, spacing: 0) {
            Button { model.toggle(kind) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8.5, weight: .bold))
                        .rotationEffect(.degrees(open ? 90 : 0))
                        .foregroundStyle(Theme.ink3)
                        .frame(width: 10)
                    Text(kind.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink2)
                    Text("\(items.count)").font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                    Spacer()
                    if model.canEditPreset, let group = Preset.Group(kind: kind) {
                        GroupSwitch(group: group)
                    }
                    if tokens > 0 { Text(Format.tokens(tokens)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.ink3) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(hovering ? Theme.hover.opacity(0.6) : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .padding(.top, 4)

            if open {
                ForEach(items) { item in
                    TreeRow(item: item, selected: model.selectedItemID == item.id, editable: model.canEditPreset)
                        .id(item.id)
                        .onTapGesture { model.selectedItemID = item.id }
                }
            }
        }
    }
}

struct TreeRow: View {
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
            Text(Format.tokens(item.tokens))
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(Theme.ink3)
                .frame(minWidth: 30, alignment: .trailing)
        }
        .padding(.leading, editable ? 34 : 28)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
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

    private var location: String? {
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

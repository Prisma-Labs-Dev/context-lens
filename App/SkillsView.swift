import AppKit
import ContextLensCore
import SwiftUI

/// Skills sessions actually used, across harnesses, and installed skills none used. Built from
/// transcripts with `SkillUsageScanner`; a listing in a session's context is not a use.
@MainActor @Observable
final class SkillsModel {
    enum Span: String, CaseIterable, Identifiable {
        case week = "7 days", month = "30 days", all = "All time"
        var id: String { rawValue }
        var since: Date? {
            switch self {
            case .week: Date().addingTimeInterval(-7 * 86_400)
            case .month: Date().addingTimeInterval(-30 * 86_400)
            case .all: nil
            }
        }
    }

    enum Selection: Hashable {
        case used(String)
        case unused(String)
    }

    var span: Span = .month { didSet { if loaded { rebuild() } } }
    var folder: String? { didSet { if loaded { rebuild() } } }
    var report: SkillReport?
    var selection: Selection?
    var loading = false
    private var files: [SkillFileScan] = []
    private var loaded = false

    /// Session folders, most sessions first, for the folder filter.
    var folders: [String] {
        var counts: [String: Int] = [:]
        for f in files where !f.cwd.isEmpty { counts[SkillReportBuilder.folder(f.cwd), default: 0] += 1 }
        return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(40).map(\.key)
    }

    /// Scans every transcript once (cached on disk); window and folder changes only rebuild.
    func load() {
        loading = true
        Task.detached {
            let files = SkillUsageScanner().scan().files
            await MainActor.run {
                self.files = files
                self.loaded = true
                self.rebuild()
            }
        }
    }

    private var generation = 0

    private func rebuild() {
        generation += 1
        let files = files, since = span.since, folder = folder, generation = generation
        loading = true
        Task.detached {
            let installed = SkillInventory().installed(folders: SkillReportBuilder.folders(files, since: since, folder: folder))
            let report = SkillReportBuilder.build(files: files, installed: installed, since: since, folder: folder)
            await MainActor.run {
                // A newer window or folder replaced this build.
                guard generation == self.generation else { return }
                self.report = report
                self.loading = false
            }
        }
    }

    func stat(_ name: String) -> SkillStat? { report?.skills.first { $0.name == name } }
    func unusedEntries(_ name: String) -> [InstalledSkill] { report?.unused.filter { $0.name == name } ?? [] }

    /// Unused skills grouped by name; a skill installed for two harnesses is one row.
    var unusedNames: [(name: String, entries: [InstalledSkill])] {
        Dictionary(grouping: report?.unused ?? [], by: \.name)
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }
}

struct SkillsView: View {
    @State private var model = SkillsModel()

    var body: some View {
        HSplitView {
            SkillsList()
                .frame(minWidth: 360, idealWidth: 440, maxWidth: 620)
                .background(Theme.window)
            SkillsDetail()
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

struct SkillsList: View {
    @Environment(SkillsModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            SkillsHeader()
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let r = model.report {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ListSection(title: "Used", trailing: "\(r.skills.count) skills · \(r.sessions) sessions") {
                            if r.skills.isEmpty {
                                Text("No skill use in this window.").font(Theme.small).foregroundStyle(Theme.ink3).padding(.horizontal, 14)
                            }
                            ForEach(r.skills) { s in
                                SkillRow(selection: .used(s.name)) {
                                    Text("\(s.uses)").font(Theme.monoSmall).monospacedDigit().foregroundStyle(Theme.ink2).frame(width: 34, alignment: .trailing)
                                    Text(s.name).lineLimit(1)
                                    if s.installed.isEmpty {
                                        Text("not installed").font(Theme.small).foregroundStyle(Theme.ink3)
                                    }
                                    Spacer(minLength: 6)
                                    Text(s.lastUsed.map { $0.formatted(.relative(presentation: .named)) } ?? "")
                                        .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
                                }
                            }
                        }
                        let unused = model.unusedNames
                        ListSection(title: "Installed, not used", trailing: "\(unused.count)") {
                            ForEach(unused, id: \.name) { name, entries in
                                SkillRow(selection: .unused(name)) {
                                    Text(name).lineLimit(1)
                                    Spacer(minLength: 6)
                                    Text(Set(entries.map(\.harness)).sorted().joined(separator: ", "))
                                        .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 12)
                }
            } else {
                Placeholder(text: model.loading ? "Reading session history…" : "No sessions found.")
            }
        }
    }
}

struct SkillsHeader: View {
    @Environment(SkillsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            Text("Skills").font(.system(size: 13, weight: .semibold))
            Picker("", selection: $model.span) {
                ForEach(SkillsModel.Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden().pickerStyle(.segmented).fixedSize()
            Picker("", selection: $model.folder) {
                Text("All folders").tag(String?.none)
                Divider()
                ForEach(model.folders, id: \.self) { f in
                    Text(URL(filePath: f).lastPathComponent).tag(String?.some(f)).help(f)
                }
            }
            .labelsHidden().frame(maxWidth: 160)
            Spacer(minLength: 6)
            if model.loading { ProgressView().controlSize(.small) }
            IconButton(systemImage: "arrow.clockwise", help: "Rescan changed transcripts") { model.load() }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

struct SkillRow<Content: View>: View {
    @Environment(SkillsModel.self) private var model
    var selection: SkillsModel.Selection
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

// MARK: - Detail

struct SkillsDetail: View {
    @Environment(SkillsModel.self) private var model

    var body: some View {
        switch model.selection {
        case .used(let name)?:
            if let s = model.stat(name) { SkillStatDetail(stat: s) } else { Placeholder(text: "No use of \(name) in this window.") }
        case .unused(let name)?:
            let entries = model.unusedEntries(name)
            if entries.isEmpty { Placeholder(text: "\(name) was used in this window.") } else { UnusedSkillDetail(name: name, entries: entries) }
        case nil:
            Placeholder(text: "Pick a skill.")
        }
    }
}

struct SkillStatDetail: View {
    var stat: SkillStat

    var body: some View {
        DetailScroll {
            Text(stat.name).font(.system(size: 16, weight: .semibold))
            Facts(items: [
                ("uses", "\(stat.uses)"),
                ("sessions", "\(stat.sessions)"),
                ("last used", stat.lastUsed?.formatted(.dateTime.month(.abbreviated).day().hour().minute()) ?? "–"),
            ] + (stat.failures > 0 ? [("failed", "\(stat.failures)")] : []))
            HStack(alignment: .top, spacing: 28) {
                CountList(title: "Trigger", counts: Dictionary(uniqueKeysWithValues: stat.triggers.map { k, v in
                    (SkillEvent.Trigger(rawValue: k)?.label ?? k, v)
                }))
                CountList(title: "Harness", counts: stat.harnesses)
            }
            CountList(title: "Folders", counts: Dictionary(stat.folders.map { (($0.name as NSString).abbreviatingWithTildeInPath, $0.count) }, uniquingKeysWith: +), mono: true)
            VStack(alignment: .leading, spacing: 5) {
                SectionHeader(title: "Recent sessions", trailing: "\(stat.examples.count) of \(stat.sessions)")
                ForEach(stat.examples) { SkillSessionLine(session: $0) }
            }
            InstalledPaths(entries: stat.installed)
        }
    }
}

struct UnusedSkillDetail: View {
    var name: String
    var entries: [InstalledSkill]

    var body: some View {
        DetailScroll {
            Text(name).font(.system(size: 16, weight: .semibold))
            Text("Installed, and no session in this window called it, ran it as a slash command or read its SKILL.md. Its description still goes into every session's skill listing.")
                .font(Theme.body).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
            InstalledPaths(entries: entries)
        }
    }
}

struct InstalledPaths: View {
    var entries: [InstalledSkill]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            SectionHeader(title: "Installed")
            if entries.isEmpty {
                Text("Not found on disk: a bundled skill, or one since removed or renamed.").font(Theme.small).foregroundStyle(Theme.ink3)
            }
            ForEach(entries) { e in
                HStack(spacing: 7) {
                    Text("\(e.harness) · \(e.scope)").font(Theme.small).foregroundStyle(Theme.ink3).frame(width: 150, alignment: .leading)
                    Text((e.path as NSString).abbreviatingWithTildeInPath).font(Theme.monoSmall).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    QuietButton(title: "Reveal", systemImage: "doc") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: e.path)])
                    }
                }
                .font(.system(size: 12))
            }
        }
    }
}

/// A session that used the skill. Claude and Codex sessions open in Past sessions; Copilot ones
/// are revealed in Finder.
struct SkillSessionLine: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    var session: SkillSession

    var body: some View {
        let harness = Harness(rawValue: session.harness)
        HStack(spacing: 7) {
            Circle().fill(session.harness == "claude" ? Theme.claude : session.harness == "codex" ? Theme.codex : Theme.ink3)
                .frame(width: 6, height: 6)
            Text(session.cwd.isEmpty ? session.id : URL(filePath: session.cwd).lastPathComponent).lineLimit(1)
            Text("\(session.time?.formatted(.dateTime.month(.abbreviated).day()) ?? "") · \(session.trigger.label)\(session.uses > 1 ? " ×\(session.uses)" : "")")
                .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
            Spacer(minLength: 6)
            if let harness, !session.cwd.isEmpty {
                QuietButton(title: "Open", systemImage: "arrow.up.right") {
                    app.select(harness: harness)
                    app.select(directory: session.cwd)
                    app.select(source: .session(session.id))
                    openWindow(id: "main")
                    NSApp.activate()
                }
            } else {
                QuietButton(title: "Reveal", systemImage: "doc") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: session.file)])
                }
            }
        }
        .font(.system(size: 12))
        .help(session.file)
    }
}

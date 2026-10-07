import ContextLensCore
import SwiftUI

/// Folders only: pinned ones first, then every folder a harness has run in, newest first.
struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                IconButton(systemImage: "arrow.clockwise", help: "Reload (⌘R)") { model.reloadAll() }
            }
            .frame(height: 38)
            .padding(.horizontal, 10)

            VStack(alignment: .leading, spacing: 6) {
                SidebarAction(title: "Open folder…", systemImage: "plus") { model.chooseFolder() }
                SidebarSearch(text: $model.search)
                let guarded = model.foldersNeedingAccess
                if guarded > 0 {
                    SidebarAction(title: "Full Disk Access for \(guarded) folder\(guarded == 1 ? "" : "s")…", systemImage: "lock") {
                        model.openFullDiskAccessSettings()
                    }
                    .help("Session folders in Documents, Desktop, iCloud Drive or other guarded places stay unread until Context Lens has Full Disk Access.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !model.pinnedEntries.isEmpty {
                            SectionHeader(title: "Pinned").padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                            ForEach(model.pinnedEntries) { row($0) }
                        }
                        SectionHeader(title: "Recent \(model.harness.displayName) folders").padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 4)
                        if model.loadingSessions && model.sessions.isEmpty {
                            Text("Reading session history…").font(Theme.small).foregroundStyle(Theme.ink3).padding(.horizontal, 10)
                        } else if model.recentDirectories.isEmpty {
                            Text(model.search.isEmpty ? "No \(model.harness.displayName) sessions yet" : "No matches")
                                .font(Theme.small).foregroundStyle(Theme.ink3).padding(.horizontal, 10)
                        }
                        ForEach(model.recentDirectories) { row($0) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 12)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(.downArrow) { model.moveDirectorySelection(1); scroll(proxy); return .handled }
                .onKeyPress(.upArrow) { model.moveDirectorySelection(-1); scroll(proxy); return .handled }
            }
        }
    }

    private func row(_ entry: DirectoryEntry) -> some View {
        DirectoryRow(entry: entry, harness: model.harness, selected: model.selectedDirectory == entry.path, showParent: model.duplicateNames.contains(entry.name))
            .id(entry.path)
            .onTapGesture { model.select(directory: entry.path); focused = true }
            .contextMenu {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: entry.path)]) }
                if entry.pinned { Button("Unpin") { model.unpin(entry.path) } } else { Button("Pin") { model.pin(entry.path) } }
            }
    }

    private func scroll(_ proxy: ScrollViewProxy) {
        if let id = model.selectedDirectory { proxy.scrollTo(id) }
    }
}

struct SidebarAction: View {
    var title: String
    var systemImage: String
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).frame(width: 16)
                Text(title).font(Theme.body)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Theme.hover : Theme.selection.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct SidebarSearch: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.ink3).frame(width: 16)
            TextField("Filter folders", text: $text).textFieldStyle(.plain).font(Theme.body)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

struct DirectoryRow: View {
    var entry: DirectoryEntry
    var harness: Harness
    var selected: Bool
    var showParent: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.pinned ? "pin" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .frame(width: 16)
            Text(entry.name).font(Theme.body).lineLimit(1)
            if showParent {
                Text(URL(filePath: entry.path).deletingLastPathComponent().lastPathComponent)
                    .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if hovering || selected {
                Text(Format.relative(entry.lastUsed[harness])).font(.system(size: 10.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Theme.selection : (hovering ? Theme.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(entry.path)
    }
}

/// Folder name, the one harness switch, and the source picker (today's files or a past session).
struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            if let dir = model.selectedDirectory {
                Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Theme.ink3)
                Text(URL(filePath: dir).lastPathComponent).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(model.abbreviate(URL(filePath: dir).deletingLastPathComponent().path))
                    .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.head)
                    .layoutPriority(-1)
                Spacer(minLength: 12)
                HarnessSwitch()
                PresetPicker()
                SourcePicker()
                LaunchButton()
                IconButton(systemImage: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: dir)])
                }
            } else {
                Spacer()
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

struct HarnessSwitch: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Harness.allCases) { h in
                let selected = model.harness == h
                Button { model.select(harness: h) } label: {
                    HStack(spacing: 6) {
                        Circle().fill(h.color).frame(width: 6, height: 6).opacity(selected ? 1 : 0.5)
                        Text(h.displayName)
                    }
                    .font(.system(size: 12, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : Theme.ink2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Theme.raised : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.selection.opacity(0.7)))
    }
}

struct SourcePicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Button { model.select(source: .now) } label: {
                Label("Now: files on disk", systemImage: model.source == .now ? "checkmark" : "doc.on.doc")
            }
            let sessions = model.sessionsHere
            if !sessions.isEmpty {
                Section("Past \(model.harness.displayName) sessions in this folder") {
                    ForEach(sessions.prefix(40)) { s in
                        Button { model.select(source: .session(s.id)) } label: {
                            let mark = model.source == .session(s.id)
                            let preset = model.launch(for: s).map { "  ·  \($0.presetName)" } ?? ""
                            Label("\(s.title)  ·  \(s.date.formatted(date: .abbreviated, time: .shortened))\(preset)", systemImage: mark ? "checkmark" : "clock")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.source == .now ? "doc.on.doc" : "clock.arrow.circlepath").font(.system(size: 11))
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.hairline))
            .frame(maxWidth: 280)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Look at today's files, or at what a past session in this folder actually received")
    }

    private var label: String {
        if let s = model.selectedSession {
            return "Session · " + s.date.formatted(date: .abbreviated, time: .shortened)
        }
        let n = model.sessionsHere.count
        return n == 0 ? "Now · no past sessions" : "Now · \(n) past session\(n == 1 ? "" : "s")"
    }
}

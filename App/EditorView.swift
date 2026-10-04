import AppKit
import ContextLensCore
import SwiftUI

enum DetailVersion: String, CaseIterable, Identifiable {
    case recorded = "Recorded"
    case current = "Current"
    case diff = "Diff"
    var id: String { rawValue }
}

/// A read-only code view of the selected item, like an editor tab.
struct EditorView: View {
    @Environment(AppModel.self) private var model
    @State private var version: DetailVersion = .recorded

    var body: some View {
        if let item = model.selectedItem {
            VStack(spacing: 0) {
                TabHeader(item: item)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                InfoStrip(item: item)
                if let off = item.presetOff { PresetOffStrip(item: item, reason: off) }
                if !item.issues.isEmpty { ProblemsStrip(issues: item.issues) }
                if item.diskStatus == .changed, item.currentContent != nil {
                    ChangeStrip(version: $version)
                } else if item.diskStatus == .deleted {
                    Notice(text: "Deleted since this session read it. Showing the recorded text.", systemImage: "trash", color: Theme.changed)
                }
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if version == .diff, let current = item.currentContent {
                    DiffView(old: item.content, new: current)
                } else {
                    CodeView(text: version == .current ? (item.currentContent ?? item.content) : item.content, home: model.home)
                }
            }
            .id(item.id)
            .onChange(of: "\(model.source)|\(model.selectedDirectory ?? "")|\(item.id)") { version = .recorded }
        } else {
            Placeholder(text: "Select an item to read exactly what the harness sees.")
        }
    }
}

struct TabHeader: View {
    @Environment(AppModel.self) private var model
    var item: ContextItem

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.kind.symbol).font(.system(size: 11)).foregroundStyle(item.kind.color)
            Text(item.path.map { URL(filePath: $0).lastPathComponent } ?? item.title)
                .font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            if let path = item.path {
                Text(model.abbreviate(URL(filePath: path).deletingLastPathComponent().path))
                    .font(Theme.small).foregroundStyle(Theme.ink3).lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 8)
            IconButton(systemImage: "doc.on.doc", help: "Copy text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.currentContent ?? item.content, forType: .string)
            }
            if let path = item.path, FileManager.default.fileExists(atPath: path) {
                IconButton(systemImage: "folder", help: "Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
                IconButton(systemImage: "arrow.up.forward.square", help: "Open in default editor") {
                    NSWorkspace.shared.open(URL(filePath: path))
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(height: 36)
    }
}

/// Scope, loading, size and age in one quiet line, plus the explanatory note.
struct InfoStrip: View {
    var item: ContextItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.scope)
                Text("·")
                Text(item.load.label)
                Text("·")
                Text("≈\(Format.tokens(item.tokens)) tokens").monospacedDigit()
                if let m = item.modified {
                    Text("·")
                    Text("edited \(Format.relative(m))").help(m.formatted(date: .complete, time: .shortened))
                }
            }
            .lineLimit(1)
            if let note = item.note {
                Text(note).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(Theme.small)
        .foregroundStyle(Theme.ink2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

struct ProblemsStrip: View {
    var issues: [Issue]

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(issues.prefix(6), id: \.self) { issue in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9.5)).foregroundStyle(Theme.stale)
                    Text(issue.message).textSelection(.enabled)
                }
            }
            if issues.count > 6 {
                Text("\(issues.count - 6) more, highlighted in the text").foregroundStyle(Theme.ink3).padding(.leading, 16)
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Theme.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Theme.stale.opacity(0.08))
    }
}

struct ChangeStrip: View {
    @Binding var version: DetailVersion

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10.5)).foregroundStyle(Theme.changed)
            Text("Changed since this session read it").font(.system(size: 11.5)).foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            Picker("Version", selection: $version) {
                ForEach(DetailVersion.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.changed.opacity(0.08))
    }
}

struct Notice: View {
    var text: String
    var systemImage: String
    var color: Color

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 10.5)).foregroundStyle(color)
            Text(text)
        }
        .font(.system(size: 11.5))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(color.opacity(0.08))
    }
}

/// Line-numbered, wrapped, read-only text. Lines with a stale path get an amber gutter mark and
/// the path itself is highlighted.
struct CodeView: View {
    var text: String
    var home: URL

    struct Line: Identifiable { var id: Int; var text: String }

    var body: some View {
        let shown = text.count > 300_000 ? String(text.prefix(300_000)) + "\n… truncated for display" : text
        let lines = shown.components(separatedBy: "\n").enumerated().map { Line(id: $0.offset, text: $0.element) }
        let missing = ReferenceChecker.missingPaths(in: shown, home: home)
        let digits = max(2, String(lines.count).count)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    let stale = missing.contains { line.text.contains($0) }
                    HStack(alignment: .top, spacing: 0) {
                        Text(String(line.id + 1))
                            .foregroundStyle(stale ? Theme.stale : Theme.ink3)
                            .frame(width: CGFloat(digits) * 7.5 + 8, alignment: .trailing)
                            .padding(.trailing, 14)
                        Text(highlight(line.text, missing: stale ? missing : []))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .font(Theme.mono)
                    .lineSpacing(2)
                    .padding(.vertical, 1)
                    .background(stale ? Theme.stale.opacity(0.07) : .clear)
                }
            }
            .padding(.vertical, 10)
            .padding(.trailing, 16)
        }
    }

    private func highlight(_ line: String, missing: [String]) -> AttributedString {
        var attr = AttributedString(line.isEmpty ? " " : line)
        attr.foregroundColor = Theme.ink
        for path in missing {
            var start = attr.startIndex
            while start < attr.endIndex, let r = attr[start...].range(of: path) {
                attr[r].foregroundColor = Theme.stale
                attr[r].underlineStyle = .single
                start = r.upperBound
            }
        }
        return attr
    }
}

/// Line diff between what a session saw and today's file, with unchanged runs collapsed.
struct DiffView: View {
    var old: String
    var new: String

    enum Kind { case same, added, removed, gap }
    struct Line: Identifiable { var id: Int; var kind: Kind; var text: String }

    var lines: [Line] {
        let a = old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var raw: [(Kind, String)] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removed.contains(i) {
                raw.append((.removed, a[i])); i += 1
            } else if j < b.count, inserted.contains(j) {
                raw.append((.added, b[j])); j += 1
            } else if i < a.count, j < b.count {
                raw.append((.same, a[i])); i += 1; j += 1
            } else if i < a.count {
                raw.append((.removed, a[i])); i += 1
            } else {
                raw.append((.added, b[j])); j += 1
            }
        }
        // Keep three lines of context around each change.
        var keep = Set<Int>()
        for c in raw.indices where raw[c].0 != .same {
            for k in max(0, c - 3)...min(raw.count - 1, c + 3) { keep.insert(k) }
        }
        var out: [Line] = []
        var skipped = 0
        for (n, line) in raw.enumerated() {
            if keep.contains(n) {
                if skipped > 0 { out.append(Line(id: out.count, kind: .gap, text: "\(skipped) unchanged lines")); skipped = 0 }
                out.append(Line(id: out.count, kind: line.0, text: line.1))
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { out.append(Line(id: out.count, kind: .gap, text: "\(skipped) unchanged lines")) }
        return out
    }

    var body: some View {
        let lines = lines
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if !lines.contains(where: { $0.kind == .added || $0.kind == .removed }) {
                    Text("Only whitespace or frontmatter differs.").font(Theme.small).foregroundStyle(Theme.ink3).padding(14)
                }
                ForEach(lines) { line in
                    switch line.kind {
                    case .gap:
                        Text("⋯ \(line.text)")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 4)
                            .background(Theme.hover.opacity(0.5))
                    default:
                        HStack(alignment: .top, spacing: 10) {
                            Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ")
                                .foregroundStyle(line.kind == .added ? Theme.added : Theme.removed)
                                .frame(width: 12)
                            Text(line.text.isEmpty ? " " : line.text)
                                .foregroundStyle(line.kind == .same ? Theme.ink2 : Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .font(Theme.mono)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 1)
                        .background(line.kind == .added ? Theme.added.opacity(0.1) : line.kind == .removed ? Theme.removed.opacity(0.1) : .clear)
                    }
                }
            }
            .padding(.vertical, 8)
        }
    }
}

/// Shown when the selected preset switches this item off.
struct PresetOffStrip: View {
    @Environment(AppModel.self) private var model
    var item: ContextItem
    var reason: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3").font(.system(size: 10.5)).foregroundStyle(Theme.preset)
            Text(reason + " The harness will not load it when launched with this preset.").font(.system(size: 11.5))
            Spacer(minLength: 8)
            if model.canEditPreset, model.toggleInfo(item).key != nil {
                QuietButton(title: "Turn on", tint: Theme.preset) { model.toggle(item) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Theme.preset.opacity(0.08))
    }
}

import AppKit
import ContextLensCore
import Foundation
import Observation

/// What the main area shows for the selected folder and harness.
enum Source: Hashable {
    /// Predicted from the files on disk today.
    case now
    /// Recorded in a past session's transcript.
    case session(SessionSummary.ID)
}

struct DirectoryEntry: Identifiable, Hashable {
    var path: String
    /// Newest session per harness.
    var lastUsed: [Harness: Date] = [:]
    var sessionCounts: [Harness: Int] = [:]
    var pinned = false
    var id: String { path }
    var name: String { URL(filePath: path).lastPathComponent }
}

/// The app answers one question: what does a harness put into its context when it runs in
/// this folder? The user picks a folder (sidebar), a harness (top bar), and whether to look at
/// today's files or at a past session in that folder (top bar).
@MainActor
@Observable
final class AppModel {
    var search = "" { didSet { rebuildFolderLists() } }
    var onlyProblems = false
    var collapsed: Set<ContextKind> = [.inactive]

    var sessions: [SessionSummary] = [] { didSet { indexFolders() } }
    private(set) var launches: [LaunchLog.Entry] = []
    var loadingSessions = false
    var pinnedDirectories: [String] = UserDefaults.standard.stringArray(forKey: "pinnedDirectories") ?? [] {
        didSet { rebuildFolderLists() }
    }

    private(set) var selectedDirectory: String?
    private(set) var harness: Harness = Harness(rawValue: UserDefaults.standard.string(forKey: "harness") ?? "") ?? .claude
    private(set) var source: Source = .now
    var selectedItemID: ContextItem.ID?

    /// What the harness finds on disk (or what a session recorded), before any preset.
    private(set) var baseSnapshot: ContextSnapshot?
    /// `baseSnapshot` as the selected preset would load it.
    private(set) var snapshot: ContextSnapshot?
    var loadingSnapshot = false

    // Presets
    let presetStore = PresetStore()
    private(set) var presets: [Preset] = []
    /// Not remembered between launches: the app opens on what the harness really loads, and a
    /// preset is a preview the user picks on purpose.
    private(set) var presetID: String = Preset.onDisk.id
    var showingInstructionsEditor = false
    var namingPreset: PresetNaming?
    var notice: String?
    private var snapshotTask: Task<Void, Never>?

    let home = FileManager.default.homeDirectoryForCurrentUser
    private var openLatestSessionOnLoad = false

    init() {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-harness"), i + 1 < args.count, let h = Harness(rawValue: args[i + 1]) {
            harness = h
        }
        if let i = args.firstIndex(of: "-directory"), i + 1 < args.count {
            let path = FileUtilApp.realPath(args[i + 1])
            if !pinnedDirectories.contains(path) { pinnedDirectories.insert(path, at: 0) }
            selectedDirectory = path
        }
        openLatestSessionOnLoad = args.contains("-latest-session")
        presets = presetStore.all()
        if let i = args.firstIndex(of: "-preset"), i + 1 < args.count { presetID = args[i + 1] }
        if !presets.contains(where: { $0.id == presetID }) { presetID = Preset.onDisk.id }
        rebuildFolderLists()
        reloadSnapshot()
        // Load history at launch, not when the window appears: the menu bar lists recent folders
        // even when no window is open.
        Task { await loadSessions() }
    }

    // MARK: - Folders

    func loadSessions() async {
        loadingSessions = true
        sessions = await Task.detached(priority: .userInitiated) { SessionIndex().all() }.value
        launches = LaunchLog().entries()
        loadingSessions = false
        if selectedDirectory == nil, let first = recentDirectories.first ?? pinnedEntries.first {
            select(directory: first.path)
        }
        if openLatestSessionOnLoad, let s = sessionsHere.first {
            openLatestSessionOnLoad = false
            select(source: .session(s.id))
        }
    }

    /// Folders with session history that still exist, grouped from `sessions`. Rebuilt only when
    /// the sessions change: the sidebar reads the lists below on every render.
    private var sessionFolders: [String: DirectoryEntry] = [:]

    private(set) var pinnedEntries: [DirectoryEntry] = []
    /// Folders where the selected harness has run and that still exist, newest first. Switching
    /// the harness switches this list, so it shows the folders of the agent in use.
    private(set) var recentDirectories: [DirectoryEntry] = []
    /// Names that appear more than once in the sidebar get a parent hint.
    private(set) var duplicateNames: Set<String> = []

    private func indexFolders() {
        var byPath: [String: DirectoryEntry] = [:]
        for s in sessions {
            var e = byPath[s.cwd] ?? DirectoryEntry(path: s.cwd)
            e.lastUsed[s.harness] = max(e.lastUsed[s.harness] ?? .distantPast, s.date)
            e.sessionCounts[s.harness, default: 0] += 1
            byPath[s.cwd] = e
        }
        let fm = FileManager.default
        sessionFolders = byPath.filter { fm.fileExists(atPath: $0.key) }
        rebuildFolderLists()
    }

    private func rebuildFolderLists() {
        func matches(_ e: DirectoryEntry) -> Bool { search.isEmpty || e.path.localizedCaseInsensitiveContains(search) }
        let pinned = Set(pinnedDirectories)
        pinnedEntries = pinnedDirectories.map { p in
            var e = sessionFolders[p] ?? DirectoryEntry(path: p)
            e.pinned = true
            return e
        }.filter(matches)
        recentDirectories = sessionFolders.values
            .filter { !pinned.contains($0.path) && $0.sessionCounts[harness, default: 0] > 0 && matches($0) }
            .sorted { ($0.lastUsed[harness] ?? .distantPast) > ($1.lastUsed[harness] ?? .distantPast) }
        var counts: [String: Int] = [:]
        for e in pinnedEntries + recentDirectories { counts[e.name, default: 0] += 1 }
        duplicateNames = Set(counts.filter { $0.value > 1 }.keys)
    }

    func select(directory path: String) {
        guard path != selectedDirectory else { return }
        selectedDirectory = path
        source = .now
        reloadSnapshot()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Inspect"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = FileUtilApp.realPath(url.path)
        pin(path)
        select(directory: path)
    }

    func pin(_ path: String) {
        guard !pinnedDirectories.contains(path) else { return }
        pinnedDirectories.insert(path, at: 0)
        UserDefaults.standard.set(pinnedDirectories, forKey: "pinnedDirectories")
    }

    func unpin(_ path: String) {
        pinnedDirectories.removeAll { $0 == path }
        UserDefaults.standard.set(pinnedDirectories, forKey: "pinnedDirectories")
    }

    func moveDirectorySelection(_ delta: Int) {
        let ids = (pinnedEntries + recentDirectories).map(\.path)
        if let next = Self.step(ids, from: selectedDirectory, by: delta) { select(directory: next) }
    }

    // MARK: - Harness and source

    func select(harness h: Harness) {
        guard h != harness else { return }
        harness = h
        UserDefaults.standard.set(h.rawValue, forKey: "harness")
        source = .now
        rebuildFolderLists()
        // Stay in the folder when it is pinned or this harness has run there; otherwise follow
        // the list to this harness's newest folder.
        let visible = (pinnedEntries + recentDirectories).map(\.path)
        if let dir = selectedDirectory, !visible.contains(dir), let first = recentDirectories.first {
            selectedDirectory = first.path
        }
        reloadSnapshot()
    }

    func select(source s: Source) {
        source = s
        reloadSnapshot()
    }

    var presetIsActive: Bool { presetApplies && preset.id != Preset.onDisk.id }

    /// Past sessions of the selected harness in the selected folder, newest first.
    var sessionsHere: [SessionSummary] {
        guard let dir = selectedDirectory else { return [] }
        return sessions.filter { $0.cwd == dir && $0.harness == harness }
    }

    func sessionCount(_ h: Harness) -> Int {
        guard let dir = selectedDirectory else { return 0 }
        return sessions.filter { $0.cwd == dir && $0.harness == h }.count
    }

    /// The preset a session was launched with, when Context Lens launched it.
    func launch(for session: SessionSummary) -> LaunchLog.Entry? {
        LaunchLog.match(session, in: launches)
    }

    var selectedSession: SessionSummary? {
        guard case .session(let id) = source else { return nil }
        return sessions.first { $0.id == id }
    }

    func reloadAll() {
        Task { await loadSessions() }
        reloadSnapshot()
    }

    // MARK: - Snapshot

    func reloadSnapshot() {
        snapshotTask?.cancel()
        let harness = harness
        let directory = selectedDirectory
        let session = selectedSession
        guard directory != nil || session != nil else {
            baseSnapshot = nil
            snapshot = nil
            return
        }
        loadingSnapshot = true
        snapshotTask = Task {
            let worker = Task.detached(priority: .userInitiated) { () -> ContextSnapshot? in
                if let session {
                    return session.harness == .claude ? ClaudeSessionParser().parse(session) : CodexSessionParser().parse(session)
                }
                guard let directory else { return nil }
                let url = URL(filePath: directory)
                return harness == .claude ? ClaudeResolver().resolve(cwd: url) : CodexResolver().resolve(cwd: url)
            }
            // Cancelling the outer task must stop the parse too, or rapid clicks pile up full
            // transcript reads.
            let snap = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            baseSnapshot = snap
            applyPreset()
            loadingSnapshot = false
            if let snap, !snap.items.contains(where: { $0.id == selectedItemID }) {
                selectedItemID = visibleSections(of: snap).first?.items.first?.id
            }
        }
    }

    // MARK: - Presets

    var preset: Preset { presets.first { $0.id == presetID } ?? .onDisk }

    /// Presets shape new launches, so they apply to "now", not to a recorded session.
    var presetApplies: Bool { source == .now }

    var canEditPreset: Bool { presetApplies && !preset.isBuiltIn }

    func applyPreset() {
        guard let base = baseSnapshot else { snapshot = nil; return }
        snapshot = presetApplies ? PresetApplier.apply(preset, to: base) : base
    }

    func select(preset id: String) {
        presetID = id
        applyPreset()
    }

    /// Saves a change to the selected custom preset and re-applies it.
    func updatePreset(_ change: (inout Preset) -> Void) {
        guard !preset.isBuiltIn, let i = presets.firstIndex(where: { $0.id == presetID }) else { return }
        change(&presets[i])
        do { try presetStore.save(presets[i]) } catch { notice = "Could not save the preset: \(error.localizedDescription)" }
        applyPreset()
    }

    func baseItem(_ id: ContextItem.ID) -> ContextItem? {
        baseSnapshot?.items.first { $0.id == id }
    }

    /// Whether the item can be switched by a preset, and why not.
    func toggleInfo(_ item: ContextItem) -> (key: String?, reason: String?) {
        guard let base = baseItem(item.id) else { return (nil, "Added by the preset.") }
        if base.load == .inactive { return (nil, "Not loaded on disk either.") }
        return PresetKeys.key(for: base, harness: harness)
    }

    func isOn(_ item: ContextItem) -> Bool { item.presetOff == nil }

    func toggle(_ item: ContextItem) {
        guard canEditPreset, let base = baseItem(item.id), let key = toggleInfo(item).key else { return }
        let turnOn = item.presetOff != nil
        updatePreset { p in
            if turnOn, let group = Preset.Group(kind: base.kind), p.offGroups.contains(group) {
                // Turning one item on inside a switched-off group: keep the rest of the group off.
                p.setGroup(group, off: false)
                for other in self.baseSnapshot?.items ?? [] where Preset.Group(kind: other.kind) == group {
                    if let k = PresetKeys.key(for: other, harness: self.harness).key, k != key { p.set(k, enabled: false, harness: self.harness) }
                }
            }
            if turnOn, base.path == PresetKeys.userInstructionsPath(self.harness), p.instructionsMode == .replace {
                p.instructionsMode = .append
            }
            p.set(key, enabled: turnOn, harness: self.harness)
        }
    }

    func setGroup(_ group: Preset.Group, off: Bool) {
        updatePreset { p in
            p.setGroup(group, off: off)
            if !off {
                for item in self.baseSnapshot?.items ?? [] where Preset.Group(kind: item.kind) == group {
                    if let k = PresetKeys.key(for: item, harness: self.harness).key { p.set(k, enabled: true, harness: self.harness) }
                }
            }
        }
    }

    func groupState(_ group: Preset.Group) -> (on: Int, total: Int) {
        let items = (snapshot?.items ?? []).filter { Preset.Group(kind: $0.kind) == group && baseItem($0.id)?.load != .inactive }
        return (items.filter { $0.presetOff == nil }.count, items.count)
    }

    func createPreset(named name: String) {
        var new = preset
        new.id = presetStore.uniqueID(for: name)
        new.name = name
        if preset.base == .cleanInstall {
            // A clean-install copy that can be edited: everything on disk, switched off.
            new.base = .onDisk
            new.offGroups = Preset.Group.allCases
            new.disableBundledSkills = true
            for harness in Harness.allCases {
                let keys = (baseSnapshot?.harness == harness ? baseSnapshot?.items ?? [] : [])
                    .filter { [.instructions, .imported, .rule, .onDemand].contains($0.kind) }
                    .compactMap { PresetKeys.key(for: $0, harness: harness).key }
                new.disabled[harness.rawValue] = keys
            }
            new.summary = "Starts from nothing; turn on only what you need."
        } else if preset.id == Preset.onDisk.id {
            new.summary = "Everything on disk, minus what you switch off."
        }
        do {
            try presetStore.save(new)
            presets = presetStore.all()
            select(preset: new.id)
        } catch {
            notice = "Could not save the preset: \(error.localizedDescription)"
        }
    }

    func renamePreset(to name: String) {
        updatePreset { $0.name = name }
        presets = presetStore.all()
    }

    func deletePreset() {
        guard !preset.isBuiltIn else { return }
        presetStore.delete(preset)
        presets = presetStore.all()
        select(preset: Preset.onDisk.id)
    }

    // MARK: - Launch

    /// The CLI bundled next to the app executable.
    var cliPath: String? {
        Bundle.main.url(forAuxiliaryExecutable: "context-lens")?.path
    }

    /// Opens Terminal in the folder with the harness started under the selected preset.
    func launch() {
        guard let dir = selectedDirectory, let cli = cliPath else { return }
        let launchDir = presetStore.root.appending(path: "launch")
        try? FileManager.default.createDirectory(at: launchDir, withIntermediateDirectories: true)
        for old in FileUtilApp.children(launchDir) where (FileUtilApp.modified(old) ?? .distantPast) < Date().addingTimeInterval(-86_400) {
            try? FileManager.default.removeItem(at: old)
        }
        let script = """
        #!/bin/zsh
        cd \(Shell.quote(dir)) || exit 1
        exec \(Shell.quote(cli)) run \(Shell.quote(preset.id)) \(harness.rawValue)
        """
        let url = launchDir.appending(path: "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))-\(preset.id)-\(harness.rawValue).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
            notice = "Opened Terminal: \(harness.displayName) with \(preset.name) in \(URL(filePath: dir).lastPathComponent)."
        } catch {
            notice = "Could not launch: \(error.localizedDescription)"
        }
    }

    /// The launch command, for pasting into any terminal. It goes through `context-lens run`,
    /// like the Launch button, so the session's generated files stay protected while it runs.
    func copyCommand() {
        guard let dir = selectedDirectory, let cli = cliPath else { return }
        let tool = cliInstalled ? "context-lens" : Shell.quote(cli)
        let command = "cd \(Shell.quote(dir)) && \(tool) run \(Shell.quote(preset.id)) \(harness.rawValue)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        notice = "Copied: \(command)"
    }

    var cliInstallPath: String { home.appending(path: ".local/bin/context-lens").path }

    var cliInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: cliInstallPath)) == cliPath
    }

    /// Links the bundled CLI into ~/.local/bin so `context-lens run <preset> claude` works anywhere.
    func installCLI() {
        guard let cli = cliPath else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: home.appending(path: ".local/bin"), withIntermediateDirectories: true)
        if let existing = try? fm.destinationOfSymbolicLink(atPath: cliInstallPath), existing != cli {
            try? fm.removeItem(atPath: cliInstallPath)
        }
        do {
            if !cliInstalled { try fm.createSymbolicLink(atPath: cliInstallPath, withDestinationPath: cli) }
            notice = "Installed: run `context-lens run \(preset.id) \(harness.rawValue)` in any folder."
        } catch {
            notice = "Could not install the command: \(error.localizedDescription)"
        }
    }

    func visibleSections(of snap: ContextSnapshot) -> [(kind: ContextKind, items: [ContextItem])] {
        snap.sections.compactMap { section in
            let items = onlyProblems ? section.items.filter(\.hasProblem) : section.items
            return items.isEmpty ? nil : (section.kind, items)
        }
    }

    func toggle(_ kind: ContextKind) {
        if collapsed.contains(kind) { collapsed.remove(kind) } else { collapsed.insert(kind) }
    }

    func moveItemSelection(_ delta: Int) {
        guard let snap = snapshot else { return }
        let ids = visibleSections(of: snap).filter { !collapsed.contains($0.kind) }.flatMap { $0.items.map(\.id) }
        selectedItemID = Self.step(ids, from: selectedItemID, by: delta)
    }

    var selectedItem: ContextItem? {
        guard let id = selectedItemID else { return nil }
        return snapshot?.items.first { $0.id == id }
    }

    static func step(_ ids: [String], from current: String?, by delta: Int) -> String? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        return ids[min(max(i + delta, 0), ids.count - 1)]
    }

    func abbreviate(_ path: String) -> String {
        let h = home.path
        if path == h { return "~" }
        return path.hasPrefix(h + "/") ? "~" + path.dropFirst(h.count) : path
    }
}

extension ContextItem {
    var hasProblem: Bool { !issues.isEmpty || diskStatus == .changed || diskStatus == .deleted }
}

extension ContextSnapshot {
    var alwaysLoadedFiles: Int { items.filter { $0.path != nil && $0.load == .always }.count }
    var changedCount: Int { items.filter { $0.diskStatus == .changed || $0.diskStatus == .deleted }.count }
    var problemCount: Int { items.filter(\.hasProblem).count }
}

enum Format {
    static func tokens(_ n: Int) -> String {
        n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
    }

    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        return date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}

/// Sheet state for naming a new or renamed preset.
enum PresetNaming: Identifiable {
    case new
    case rename
    var id: String { self == .new ? "new" : "rename" }
}

enum FileUtilApp {
    /// realpath(3): sessions record real paths such as /private/tmp, which Foundation's
    /// standardizing would shorten to /tmp.
    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(filePath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
    }

    static func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}

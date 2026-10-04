import Foundation

/// A named way to start a harness with a different context than the files on disk would give,
/// without changing those files. See docs/presets.md for the switches each harness honors.
public struct Preset: Codable, Identifiable, Hashable, Sendable {
    public enum Base: String, Codable, Sendable {
        /// Nothing user-provided: no instruction files, skills, memory, MCP servers or hooks.
        case cleanInstall
        /// Everything on disk, minus what `disabled` turns off.
        case onDisk
    }

    public enum InstructionsMode: String, Codable, CaseIterable, Sendable {
        /// Load instruction files as they are.
        case keep
        /// Load them and add the preset's instructions.
        case append
        /// Use the preset's instructions in place of the user-level file
        /// (`~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`). Project files still load.
        case replace
    }

    public var id: String
    public var name: String
    public var summary: String
    public var base: Base
    /// Toggle keys (see `PresetKeys`) that are off, per harness raw value.
    public var disabled: [String: [String]]
    public var instructionsMode: InstructionsMode
    public var instructions: String
    /// Claude Code only: hide the skills that ship with Claude Code.
    public var disableBundledSkills: Bool
    /// Whole groups that are off, so items added to disk later stay off too.
    public var offGroups: [Group]

    public enum Group: String, Codable, CaseIterable, Sendable {
        case skills, mcp, memory, hooks

        public var title: String {
            switch self {
            case .skills: "All skills"
            case .mcp: "All MCP servers"
            case .memory: "Memory"
            case .hooks: "Hooks"
            }
        }

        public init?(kind: ContextKind) {
            switch kind {
            case .skill: self = .skills
            case .mcp: self = .mcp
            case .memory: self = .memory
            case .hook: self = .hooks
            default: return nil
            }
        }
    }

    public init(
        id: String,
        name: String,
        summary: String = "",
        base: Base = .onDisk,
        disabled: [String: [String]] = [:],
        instructionsMode: InstructionsMode = .keep,
        instructions: String = "",
        disableBundledSkills: Bool = false,
        offGroups: [Group] = []
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.base = base
        self.disabled = disabled
        self.instructionsMode = instructionsMode
        self.instructions = instructions
        self.disableBundledSkills = disableBundledSkills
        self.offGroups = offGroups
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        base = try c.decodeIfPresent(Base.self, forKey: .base) ?? .onDisk
        disabled = try c.decodeIfPresent([String: [String]].self, forKey: .disabled) ?? [:]
        instructionsMode = try c.decodeIfPresent(InstructionsMode.self, forKey: .instructionsMode) ?? .keep
        instructions = try c.decodeIfPresent(String.self, forKey: .instructions) ?? ""
        disableBundledSkills = try c.decodeIfPresent(Bool.self, forKey: .disableBundledSkills) ?? false
        offGroups = try c.decodeIfPresent([Group].self, forKey: .offGroups) ?? []
    }

    public func isGroupOff(_ group: Group) -> Bool { base == .cleanInstall || offGroups.contains(group) }

    public mutating func setGroup(_ group: Group, off: Bool) {
        offGroups.removeAll { $0 == group }
        if off { offGroups.append(group) }
        offGroups.sort { $0.rawValue < $1.rawValue }
    }

    /// Whether the preset switches this item off, and why.
    public func offReason(_ item: ContextItem, harness: Harness, env: HarnessEnvironment = .current) -> String? {
        if instructionsMode == .replace, addsInstructions, item.path == PresetKeys.userInstructionsPath(harness, env: env) {
            return "Replaced by \(name)'s instructions."
        }
        if base == .cleanInstall { return "Not loaded in a clean install." }
        if let group = Group(kind: item.kind), offGroups.contains(group) { return "\(group.title) off in \(name)." }
        if let key = PresetKeys.key(for: item, harness: harness).key, disabledKeys(harness).contains(key) {
            return "Off in \(name)."
        }
        return nil
    }

    public var isBuiltIn: Bool { id == Preset.cleanInstall.id || id == Preset.onDisk.id }

    /// IDs become file and directory names, so they must be one plain path component.
    public static func isSafeID(_ id: String) -> Bool {
        guard (1...64).contains(id.count), let first = id.first, first.isASCII, first.isLetter || first.isNumber else { return false }
        return id.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }
    }

    public func disabledKeys(_ harness: Harness) -> Set<String> {
        Set(disabled[harness.rawValue] ?? [])
    }

    public mutating func set(_ key: String, enabled: Bool, harness: Harness) {
        var keys = disabledKeys(harness)
        if enabled { keys.remove(key) } else { keys.insert(key) }
        disabled[harness.rawValue] = keys.sorted()
    }

    /// Instructions the preset adds, when it adds any.
    public var addsInstructions: Bool {
        base == .onDisk && instructionsMode != .keep && !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public static let cleanInstall = Preset(
        id: "clean-install",
        name: "Clean install",
        summary: "A clean install: no CLAUDE.md or AGENTS.md, skills, memory, MCP servers or hooks.",
        base: .cleanInstall
    )

    public static let onDisk = Preset(
        id: "on-disk",
        name: "On disk",
        summary: "Everything the harness finds on disk, exactly as a plain launch loads it."
    )

    public static func slug(_ name: String) -> String {
        let s = name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let joined = String(s).split(separator: "-").joined(separator: "-")
        return joined.isEmpty ? "preset" : joined
    }
}

/// Stable keys for the parts of the context a preset can switch off.
public enum PresetKeys {
    public static let memory = "memory"
    public static let hooks = "hooks"
    /// Codex can only drop project AGENTS.md files all together.
    public static let codexProjectDocs = "codex-project-docs"

    public static func file(_ path: String) -> String { "file:" + path }

    /// The user-level instruction file a `replace` preset stands in for.
    public static func userInstructionsPath(_ harness: Harness, env: HarnessEnvironment = .current) -> String {
        switch harness {
        case .claude: return env.claudeHome.appending(path: "CLAUDE.md").path
        case .codex:
            let override = env.codexHome.appending(path: "AGENTS.override.md")
            return (FileUtil.isFile(override) ? override : env.codexHome.appending(path: "AGENTS.md")).path
        }
    }
    public static func skill(_ name: String) -> String { "skill:" + name }
    public static func mcp(_ name: String) -> String { "mcp:" + name }
    public static func plugin(_ id: String) -> String { "plugin:" + id }

    /// The key that switches this item, or nil with the reason it cannot be switched.
    public static func key(for item: ContextItem, harness: Harness) -> (key: String?, reason: String?) {
        switch item.kind {
        case .memory:
            return (memory, nil)
        case .hook:
            return harness == .claude ? (hooks, nil) : (nil, "Codex hooks are not switchable.")
        case .mcp:
            return (mcp(item.title), nil)
        case .skill:
            if harness == .claude, item.scope.hasPrefix("Plugin ") {
                return (plugin(String(item.scope.dropFirst("Plugin ".count))), nil)
            }
            return (skill(item.title), nil)
        case .agent:
            return (nil, "Subagents cannot be switched off individually; use Clean install to drop them.")
        case .systemPrompt, .environment, .command:
            return (nil, "Part of the harness itself.")
        case .instructions, .imported, .rule, .onDemand, .inactive:
            guard let path = item.path else { return (nil, "Not a file.") }
            if harness == .codex, item.scope == "Project" { return (codexProjectDocs, nil) }
            return (file(path), nil)
        }
    }
}

/// Reads and writes presets in `~/.context-lens/presets/<id>.json`. The path has no spaces, so
/// generated launch commands stay simple.
public struct PresetStore: Sendable {
    public var root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".context-lens")
    }

    public var presetsDir: URL { root.appending(path: "presets") }

    /// Built-ins first, then saved presets by name. Seeds examples on first use.
    public func all() -> [Preset] {
        seedIfNeeded()
        let saved = FileUtil.children(presetsDir)
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Preset? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(Preset.self, from: data)
            }
            .filter { !$0.isBuiltIn && Preset.isSafeID($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [Preset.cleanInstall, Preset.onDisk] + saved
    }

    public func preset(id: String) -> Preset? {
        all().first { $0.id == id || Preset.slug($0.name) == id }
    }

    public func save(_ preset: Preset) throws {
        guard !preset.isBuiltIn else { return }
        guard Preset.isSafeID(preset.id) else { throw PresetError.unsafeID(preset.id) }
        try FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(preset).write(to: presetsDir.appending(path: "\(preset.id).json"), options: .atomic)
    }

    public func delete(_ preset: Preset) {
        guard !preset.isBuiltIn, Preset.isSafeID(preset.id) else { return }
        try? FileManager.default.removeItem(at: presetsDir.appending(path: "\(preset.id).json"))
        try? FileManager.default.removeItem(at: root.appending(path: "generated/\(preset.id)"))
    }

    /// A new id that does not collide with existing presets.
    public func uniqueID(for name: String) -> String {
        let base = Preset.slug(name)
        let taken = Set(all().map(\.id))
        var id = base
        var n = 2
        while taken.contains(id) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }

    func seedIfNeeded() {
        let marker = root.appending(path: ".seeded")
        guard !FileUtil.exists(marker) else { return }
        try? FileManager.default.createDirectory(at: presetsDir, withIntermediateDirectories: true)
        for preset in PresetExamples.all { try? save(preset) }
        try? Data().write(to: marker)
    }
}

public enum PresetError: Error, CustomStringConvertible {
    case unsafeID(String)

    public var description: String {
        switch self {
        case .unsafeID(let id): "Preset id \"\(id)\" must be lowercase letters, digits and dashes."
        }
    }
}

/// Starting points that show what presets are for. Users edit or delete them freely.
public enum PresetExamples {
    public static let autonomousText = """
    # Working mode: autonomous

    Carry the task as far as it can go without stopping.

    - Do not ask for confirmation on routine decisions. Pick the reasonable option, note it in
      one line, and keep going.
    - Run the checks that matter for the change (build, tests that cover it), fix what fails,
      and move on. Skip extra review rounds unless something risky changed.
    - Stop only for actions that cannot be undone, spend money, or reach other people.
    - Finish with a short summary: what changed, what you decided, what is left.
    """

    public static let carefulText = """
    # Working mode: careful

    Prefer correctness over speed.

    - Before changing code, read the surrounding code and state the plan in two or three lines.
    - Work in small steps. After each step run the relevant tests and the build.
    - Get an independent review of every non-trivial change before calling it done, and fix
      what the review finds.
    - Verify the result in the running app or with a real command, not only by reading code.
    - Report what you verified and how, and anything you could not verify.
    """

    public static let all: [Preset] = [
        Preset(
            id: "autonomous",
            name: "Autonomous",
            summary: "Your project files, but the global instructions say: go as far as you can without stopping.",
            instructionsMode: .replace,
            instructions: autonomousText
        ),
        Preset(
            id: "careful",
            name: "Careful",
            summary: "Everything on disk plus instructions for small steps, tests and independent review.",
            instructionsMode: .append,
            instructions: carefulText
        ),
        Preset(
            id: "lean",
            name: "Lean",
            summary: "Instruction files only: no skills, memory, MCP servers or hooks.",
            disableBundledSkills: true,
            offGroups: [.hooks, .mcp, .memory, .skills]
        ),
    ]
}

/// Remembers preset launches so past sessions can show which preset they ran with.
/// One JSON object per line in `~/.context-lens/launches.jsonl`.
public struct LaunchLog: Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public var date: Date
        public var preset: String
        public var presetName: String
        public var harness: Harness
        public var cwd: String
    }

    public var url: URL

    public init(store: PresetStore = PresetStore()) {
        url = store.root.appending(path: "launches.jsonl")
    }

    public func record(_ preset: Preset, harness: Harness, cwd: URL) {
        let entry = Entry(date: Date(), preset: preset.id, presetName: preset.name, harness: harness, cwd: FileUtil.realPath(cwd).path)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard var line = try? enc.encode(entry) else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
        } else {
            try? line.write(to: url)
        }
    }

    public func entries() -> [Entry] {
        guard let text = FileUtil.read(url) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// The launch that started this session: same folder and harness, shortly before it began.
    public static func match(_ session: SessionSummary, in entries: [Entry]) -> Entry? {
        guard let started = session.started else { return nil }
        let cwd = FileUtil.realPath(URL(filePath: session.cwd)).path
        return entries
            .filter { $0.harness == session.harness && $0.cwd == cwd }
            .filter { started.timeIntervalSince($0.date) > -30 && started.timeIntervalSince($0.date) < 600 }
            .min { abs(started.timeIntervalSince($0.date)) < abs(started.timeIntervalSince($1.date)) }
    }
}

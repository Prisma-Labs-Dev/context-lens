import Foundation

public enum Harness: String, CaseIterable, Codable, Sendable, Identifiable {
    case claude
    case codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// What part of the context an item belongs to. The order of cases is the display order.
public enum ContextKind: String, CaseIterable, Codable, Sendable, Comparable {
    case systemPrompt
    case instructions
    case imported
    case rule
    case memory
    case skill
    case agent
    case command
    case mcp
    case hook
    case environment
    case onDemand
    case inactive

    public var title: String {
        switch self {
        case .systemPrompt: "System prompt"
        case .instructions: "Instruction files"
        case .imported: "Imported files"
        case .rule: "Rules"
        case .memory: "Memory"
        case .skill: "Skills"
        case .agent: "Subagents"
        case .command: "Commands"
        case .mcp: "MCP servers"
        case .hook: "Hooks"
        case .environment: "Environment"
        case .onDemand: "Loaded on demand"
        case .inactive: "Present but not loaded"
        }
    }

    public static func < (lhs: ContextKind, rhs: ContextKind) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// How an item reaches the model.
public enum LoadMode: String, Codable, Sendable {
    /// Full text is in the context from the first turn.
    case always
    /// Only a name and description line is in the context; the body loads when invoked.
    case listing
    /// Loaded only when the agent touches matching files or reads it.
    case onDemand
    /// Exists on disk but this harness does not load it here.
    case inactive

    public var label: String {
        switch self {
        case .always: "Always loaded"
        case .listing: "Listed (name + description)"
        case .onDemand: "On demand"
        case .inactive: "Not loaded"
        }
    }
}

/// For items read from a recorded session: does the file on disk still match what the session saw?
public enum DiskStatus: String, Codable, Sendable {
    case same
    case changed
    case deleted
    case unknown
}

public struct Issue: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case missingPath, missingImport, truncated, note }
    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }
}

public struct ContextItem: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var kind: ContextKind
    public var title: String
    public var scope: String
    public var path: String?
    /// The text that enters the context. For listed items this is the listing line.
    public var content: String
    public var load: LoadMode
    public var note: String?
    public var modified: Date?
    public var issues: [Issue]
    public var diskStatus: DiskStatus?
    /// For a recorded item whose file changed since: the current text on disk.
    public var currentContent: String?
    /// Set when the selected preset switches this item off: the reason.
    public var presetOff: String?

    public init(
        id: String? = nil,
        kind: ContextKind,
        title: String,
        scope: String,
        path: String? = nil,
        content: String,
        load: LoadMode,
        note: String? = nil,
        modified: Date? = nil,
        issues: [Issue] = [],
        diskStatus: DiskStatus? = nil,
        currentContent: String? = nil
    ) {
        self.id = id ?? "\(kind.rawValue)|\(scope)|\(path ?? title)"
        self.kind = kind
        self.title = title
        self.scope = scope
        self.path = path
        self.content = content
        self.load = load
        self.note = note
        self.modified = modified
        self.issues = issues
        self.diskStatus = diskStatus
        self.currentContent = currentContent
    }

    /// Rough token estimate of what this item adds to the starting context (4 characters per token).
    public var startingTokens: Int {
        switch load {
        case .always, .listing: TokenEstimate.tokens(content)
        case .onDemand, .inactive: 0
        }
    }

    public var tokens: Int { TokenEstimate.tokens(content) }

    public var hasProblem: Bool { !issues.isEmpty || diskStatus == .changed || diskStatus == .deleted }
}

public enum TokenEstimate {
    public static func tokens(_ text: String) -> Int { tokens(chars: text.utf8.count) }
    public static func tokens(chars: Int) -> Int { (chars + 3) / 4 }
}

public struct ContextSnapshot: Sendable {
    public var harness: Harness
    public var cwd: String
    public var items: [ContextItem]
    public var notes: [String]

    public init(harness: Harness, cwd: String, items: [ContextItem], notes: [String] = []) {
        self.harness = harness
        self.cwd = cwd
        self.items = items
        self.notes = notes
    }

    public var startingTokens: Int { items.reduce(0) { $0 + $1.startingTokens } }
    public var issueCount: Int { items.reduce(0) { $0 + $1.issues.count } }

    public var sections: [(kind: ContextKind, items: [ContextItem])] {
        Dictionary(grouping: items, by: \.kind)
            .sorted { $0.key < $1.key }
            .map { ($0.key, $0.value) }
    }
}

public struct SessionSummary: Identifiable, Hashable, Sendable {
    public var id: String
    public var harness: Harness
    public var file: URL
    public var title: String
    public var cwd: String
    public var date: Date
    public var sizeBytes: Int
    /// When the session began, when the transcript says.
    public var started: Date?

    public init(id: String, harness: Harness, file: URL, title: String, cwd: String, date: Date, sizeBytes: Int, started: Date? = nil) {
        self.id = id
        self.harness = harness
        self.file = file
        self.title = title
        self.cwd = cwd
        self.date = date
        self.sizeBytes = sizeBytes
        self.started = started
    }
}

/// Where the harnesses keep their state. Tests point this at a fixture directory.
public struct HarnessEnvironment: Sendable {
    public var home: URL
    public var claudeHome: URL
    public var codexHome: URL
    public var managedClaudeMd: URL

    public init(home: URL, claudeHome: URL? = nil, codexHome: URL? = nil, managedClaudeMd: URL? = nil) {
        self.home = home
        self.claudeHome = claudeHome ?? home.appending(path: ".claude")
        self.codexHome = codexHome ?? home.appending(path: ".codex")
        self.managedClaudeMd = managedClaudeMd
            ?? URL(filePath: "/Library/Application Support/ClaudeCode/CLAUDE.md")
    }

    public static var current: HarnessEnvironment {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codex = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(filePath: $0) }
        return HarnessEnvironment(home: home, codexHome: codex)
    }
}

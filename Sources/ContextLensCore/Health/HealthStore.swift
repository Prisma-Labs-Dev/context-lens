import Foundation

/// A proposed fix for a friction source: one specific edit, with the evidence behind it. The
/// weekly judge writes these; the user (or an agent acting for them) applies or briefs them and sets `status`.
public struct HealthProposal: Codable, Sendable, Identifiable, Hashable {
    public enum Status: String, Codable, Sendable, CaseIterable {
        case open, applied, briefed, rejected
    }

    public struct Quote: Codable, Sendable, Hashable {
        public var session: String
        public var link: String?
        public var text: String

        public init(session: String, link: String? = nil, text: String) {
            self.session = session
            self.link = link
            self.text = text
        }
    }

    public var id: String
    public var created: Date
    public var title: String
    /// The file or setting to change: `~/.claude/CLAUDE.md`, `~/bin/x`, a skill, a setting name.
    public var target: String
    /// rule, skill, script, setting or other.
    public var kind: String
    public var status: Status
    /// Why, in two or three sentences.
    public var summary: String
    /// The exact text to add or the change to make.
    public var edit: String
    /// The report group this addresses, so later runs can measure it.
    public var group: String?
    public var events: Int
    public var sessions: Int
    public var quotes: [Quote]
    public var author: String
    /// Set when status changes: who changed it, and the group's count at the time, for measuring.
    public var decided: Date?
    public var baselineEvents: Int?
    public var note: String?

    public init(id: String, created: Date, title: String, target: String, kind: String, status: Status, summary: String,
                edit: String, group: String?, events: Int, sessions: Int, quotes: [Quote], author: String,
                decided: Date? = nil, baselineEvents: Int? = nil, note: String? = nil) {
        self.id = id
        self.created = created
        self.title = title
        self.target = target
        self.kind = kind
        self.status = status
        self.summary = summary
        self.edit = edit
        self.group = group
        self.events = events
        self.sessions = sessions
        self.quotes = quotes
        self.author = author
        self.decided = decided
        self.baselineEvents = baselineEvents
        self.note = note
    }
}

/// Files under `~/.context-lens/health/`: the latest report, the run it came from, proposals.
public struct HealthStore: Sendable {
    public var root: URL

    public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".context-lens/health")) {
        self.root = root
    }

    public var proposalsDir: URL { root.appending(path: "proposals") }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    public func report() -> HealthReport? {
        guard let data = try? Data(contentsOf: root.appending(path: "report.json")) else { return nil }
        return try? Self.decoder.decode(HealthReport.self, from: data)
    }

    /// The run folder the latest report came from (it holds events, sessions and labels).
    public func latestRun() -> URL? {
        guard let data = try? Data(contentsOf: root.appending(path: "latest.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = obj["report"] as? String else { return nil }
        return URL(filePath: path).deletingLastPathComponent()
    }

    public func sessions(in run: URL) -> [String: HealthSession] {
        Dictionary(Self.lines(HealthSession.self, run.appending(path: "sessions.jsonl")).map { ($0.id, $0) },
                   uniquingKeysWith: { a, _ in a })
    }

    public func events(in run: URL) -> [HealthEvent] { Self.lines(HealthEvent.self, run.appending(path: "events.jsonl")) }

    public func labels(in run: URL) -> [HealthLabel] { Self.lines(HealthLabel.self, run.appending(path: "labels.jsonl")) }

    public func proposals() -> [HealthProposal] {
        FileUtil.children(proposalsDir).filter { $0.pathExtension == "json" }.compactMap { url in
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(HealthProposal.self, from: $0) }
        }.sorted { ($0.created, $0.id) > ($1.created, $1.id) }
    }

    public func save(_ p: HealthProposal) throws {
        try FileManager.default.createDirectory(at: proposalsDir, withIntermediateDirectories: true)
        try Self.encoder.encode(p).write(to: proposalsDir.appending(path: "\(p.id).json"), options: .atomic)
    }

    /// Sets a proposal's status and records the group's current count as the baseline to measure against.
    public func setStatus(_ id: String, _ status: HealthProposal.Status, note: String?) throws -> HealthProposal {
        guard var p = proposals().first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSLocalizedDescriptionKey: "no proposal \(id)"])
        }
        p.status = status
        p.decided = Date()
        if let note { p.note = note }
        if let group = p.group, let r = report() { p.baselineEvents = r.groups.first { $0.name == group }?.events ?? p.events }
        try save(p)
        return p
    }

    static func lines<T: Decodable>(_ type: T.Type, _ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: $0) }
    }

    /// A short id from a date and a title: `2026-10-04-quote-zsh-separators`.
    public static func proposalID(_ title: String, date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        let slug = String(title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" })
            .split(separator: "-").prefix(6).joined(separator: "-")
        return "\(f.string(from: date))-\(slug)"
    }
}

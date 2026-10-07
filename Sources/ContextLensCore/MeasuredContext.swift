import Foundation

/// What Claude Code itself reports for a folder: the output of `claude -p "/context"`, which
/// counts the tool definitions and MCP tool schemas no file or transcript shows.
public struct MeasuredContext: Codable, Hashable, Sendable {
    public struct Row: Codable, Hashable, Sendable {
        public var name: String
        /// MCP server, skill or agent source, memory file type.
        public var detail: String?
        public var tokens: Int
    }

    public var folder: String
    public var measuredAt: Date
    /// Always `cli`: the measurement runs the CLI. Claude Desktop adds its own MCP tools.
    public var harness: String = "cli"
    public var model: String?
    public var used: Int
    public var window: Int?
    /// System prompt, System tools, MCP tools, Memory files, Skills... Free space and the
    /// autocompact buffer are left out.
    public var categories: [Row]
    public var mcpTools: [Row]
    public var skills: [Row]
    /// Instruction files by path. Nil in measurements saved before this was kept.
    public var memoryFiles: [Row]?
    /// Where the numbers come from: `measure` (Context Lens ran /context) or
    /// `transcript <session id>` (a /context run Claude Code recorded in a transcript).
    public var source: String?

    public func category(_ name: String) -> Int {
        categories.first { $0.name == name }?.tokens ?? 0
    }

    /// MCP tool schemas per server, largest first. Names as /context prints them
    /// (`plugin_garden_garden`); `serverKey` matches them to transcript names (`plugin:garden:garden`).
    public var mcpServers: [Row] {
        var byServer: [String: Int] = [:]
        for t in mcpTools { byServer[t.detail ?? t.name, default: 0] += t.tokens }
        return byServer.map { Row(name: $0.key, tokens: $0.value) }.sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
    }

    public func mcpSchemas(_ server: String) -> Int? {
        let key = Self.serverKey(server)
        return mcpServers.first { Self.serverKey($0.name) == key }?.tokens
    }

    static func serverKey(_ name: String) -> String {
        String(name.map { $0.isLetter || $0.isNumber ? Character($0.lowercased()) : "_" })
    }

    /// What no file shows: the harness prompt, the built-in tool definitions and MCP tool schemas.
    public var notInFiles: Int { category("System prompt") + category("System tools") + category("MCP tools") }

    /// Parses the markdown `/context` prints.
    public static func parse(_ text: String, folder: String, at date: Date = Date()) -> MeasuredContext? {
        var model: String?, used: Int?, window: Int?
        var section = ""
        var categories: [Row] = [], mcp: [Row] = [], skills: [Row] = [], memory: [Row] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") { section = String(line.dropFirst(4)); continue }
            if line.hasPrefix("**Model:**") { model = line.dropFirst(10).trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix("**Tokens:**") {
                // "**Tokens:** 28.7k / 200k (14%)"
                let parts = line.dropFirst(11).split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
                used = parts.first.flatMap(tokens)
                window = parts.dropFirst().first.flatMap { $0.split(separator: " ").first.map(String.init) }.flatMap(tokens)
            }
            guard line.hasPrefix("|"), !line.hasPrefix("|-") else { continue }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 2 else { continue }
            switch section {
            case "Estimated usage by category":
                guard let t = tokens(cells[1]), !["Free space", "Autocompact buffer"].contains(cells[0]) else { continue }
                categories.append(Row(name: cells[0], tokens: t))
            case "MCP Tools":
                guard cells.count >= 3, let t = tokens(cells[2]) else { continue }
                mcp.append(Row(name: cells[0], detail: cells[1], tokens: t))
            case "Skills":
                guard cells.count >= 3, let t = tokens(cells[2]) else { continue }
                skills.append(Row(name: cells[0], detail: cells[1], tokens: t))
            case "Memory Files":
                guard cells.count >= 3, let t = tokens(cells[2]) else { continue }
                memory.append(Row(name: cells[1], detail: cells[0], tokens: t))
            default:
                break
            }
        }
        guard let used else { return nil }
        return MeasuredContext(folder: folder, measuredAt: date, model: model, used: used, window: window,
                               categories: categories, mcpTools: mcp, skills: skills, memoryFiles: memory, source: "measure")
    }

    /// Reads the `contextUsage` Claude Code records with a `/context` run in a transcript. Exact
    /// counts, where the printed table rounds to 0.1k.
    public static func parse(contextUsage u: [String: Any], folder: String, at date: Date, session: String?) -> MeasuredContext? {
        func int(_ v: Any?) -> Int? { (v as? Int) ?? (v as? NSNumber)?.intValue }
        func rows(_ key: String, name: String, detail: String) -> [Row] {
            (u[key] as? [[String: Any]] ?? []).compactMap { r in
                guard let n = r[name] as? String, let t = int(r["tokens"]) else { return nil }
                return Row(name: n, detail: r[detail] as? String, tokens: t)
            }
        }
        guard let used = int(u["total_tokens"]) else { return nil }
        let categories = (u["categories"] as? [[String: Any]] ?? []).compactMap { c -> Row? in
            guard c["kind"] as? String == "used", let n = c["name"] as? String, let t = int(c["tokens"]) else { return nil }
            return Row(name: n, tokens: t)
        }
        var model = u["model"] as? String
        if let m = model, m.hasSuffix("]"), let bracket = m.firstIndex(of: "[") { model = String(m[..<bracket]) }
        return MeasuredContext(folder: folder, measuredAt: date, model: model, used: used, window: int(u["raw_max_tokens"]),
                               categories: categories, mcpTools: rows("mcp_tools", name: "name", detail: "server_name"),
                               skills: rows("skills", name: "name", detail: "source"), memoryFiles: rows("memory_files", name: "path", detail: "type"),
                               source: "transcript" + (session.map { " " + $0 } ?? ""))
    }

    public var fromTranscript: Bool { source?.hasPrefix("transcript") == true }

    /// "1.9k" → 1900, "68" → 68, "~80" → 80, "< 20" → 0 (too small to say), "1.2M" → 1200000.
    static func tokens(_ s: String) -> Int? {
        var s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("<") { return 0 }
        if s.hasPrefix("~") { s.removeFirst() }
        var scale = 1.0
        if s.hasSuffix("k") { scale = 1000; s.removeLast() } else if s.hasSuffix("M") { scale = 1_000_000; s.removeLast() }
        return Double(s.replacingOccurrences(of: ",", with: "")).map { Int(($0 * scale).rounded()) }
    }
}

/// Runs `claude -p "/context"` in a folder and keeps every result as history in
/// `~/.context-lens/context/<folder>/<time>.json`, so a session can be matched with the
/// measurement nearest its start and a folder compared before and after a change. `/context` runs
/// Claude Code recorded in transcripts are added to the same history.
public struct MeasuredContextStore: Sendable {
    public let root: URL
    public let claudeHome: URL

    public init(root: URL? = nil, claudeHome: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.root = root ?? home.appending(path: ".context-lens/context")
        self.claudeHome = claudeHome ?? home.appending(path: ".claude")
    }

    func key(_ folder: String) -> String { folder.replacingOccurrences(of: "/", with: "-") }

    /// Before history was kept: one file per folder.
    func legacyFile(_ folder: String) -> URL { root.appending(path: key(folder) + ".json") }

    func file(_ m: MeasuredContext) -> URL {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss.SSS'Z'"
        return root.appending(path: key(m.folder)).appending(path: f.string(from: m.measuredAt) + ".json")
    }

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    static func read(_ url: URL) -> MeasuredContext? {
        (try? Data(contentsOf: url)).flatMap { try? decoder.decode(MeasuredContext.self, from: $0) }
    }

    /// Every measurement of a folder, oldest first.
    public func history(_ folder: String) -> [MeasuredContext] {
        let dir = root.appending(path: key(folder))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var all = files.filter { $0.pathExtension == "json" }.compactMap(Self.read)
        if let legacy = Self.read(legacyFile(folder)), !all.contains(where: { $0.measuredAt == legacy.measuredAt }) { all.append(legacy) }
        return all.filter { $0.folder == folder }.sorted { $0.measuredAt < $1.measuredAt }
    }

    /// Every folder's measurements, oldest first.
    public func all() -> [MeasuredContext] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var out: [MeasuredContext] = []
        for e in entries {
            if e.pathExtension == "json" {
                if let m = Self.read(e) { out.append(m) }
            } else if e.hasDirectoryPath {
                let files = (try? FileManager.default.contentsOfDirectory(at: e, includingPropertiesForKeys: nil)) ?? []
                out += files.filter { $0.pathExtension == "json" }.compactMap(Self.read)
            }
        }
        var seen = Set<String>()
        return out.sorted { $0.measuredAt < $1.measuredAt }.filter { seen.insert("\($0.folder)|\($0.measuredAt.timeIntervalSince1970)").inserted }
    }

    /// The latest measurement of a folder.
    public func cached(_ folder: String) -> MeasuredContext? { history(folder).last }

    /// The measurement of a folder nearest `date`, before or after.
    public func nearest(_ folder: String, to date: Date) -> MeasuredContext? {
        history(folder).min { abs($0.measuredAt.timeIntervalSince(date)) < abs($1.measuredAt.timeIntervalSince(date)) }
    }

    /// Attributes a recorded session's first call, with the measurement of its folder nearest its
    /// start. Reads new /context runs from transcripts first.
    public func attribute(_ snapshot: ContextSnapshot, growth: ContextGrowth, cwd: String) -> ContextAttribution? {
        harvest(around: cwd)
        let m = nearest(cwd, to: growth.calls.first?.time ?? Date())
        return ContextAttribution.session(snapshot: snapshot, growth: growth, measurement: m, others: all())
    }

    public enum Failure: Error, CustomStringConvertible {
        case launch(String), exit(Int32, String), timeout, unreadable(String)
        public var description: String {
            switch self {
            case .launch(let e): "could not start claude: \(e)"
            case .exit(let code, let out): "claude exited with \(code): \(out.prefix(200))"
            case .timeout: "claude took longer than a minute"
            case .unreadable(let out): "unexpected /context output: \(out.prefix(200))"
            }
        }
    }

    /// Takes a few seconds and sends nothing to the model. The environment is a clean login
    /// shell, so variables from the app or a parent Claude session don't change what loads, and
    /// `--no-session-persistence` keeps the run out of the session list.
    public func measure(_ folder: String, timeout: TimeInterval = 60) throws -> MeasuredContext {
        let p = Process()
        p.executableURL = URL(filePath: "/bin/zsh")
        p.arguments = ["-lc", "claude -p '/context' --no-session-persistence"]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        p.environment = ["HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(), "SHELL": "/bin/zsh",
                         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TERM": "dumb"]
        p.currentDirectoryURL = URL(filePath: folder)
        let output = Pipe()
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = output
        p.standardError = output
        do { try p.run() } catch { throw Failure.launch("\(error)") }
        let timer = DispatchWorkItem { p.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        let text = String(decoding: data, as: UTF8.self)
        if p.terminationReason == .uncaughtSignal { throw Failure.timeout }
        guard p.terminationStatus == 0 else { throw Failure.exit(p.terminationStatus, text) }
        guard let measured = MeasuredContext.parse(text, folder: folder) else { throw Failure.unreadable(text) }
        save(measured)
        return measured
    }

    /// Adds a measurement to the history; an existing one is never overwritten.
    public func save(_ m: MeasuredContext) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = file(m)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? encoder.encode(m).write(to: url, options: .atomic)
    }

    /// Adds the `/context` runs Claude Code recorded in the transcripts of `folder` and the
    /// folders above it. A transcript is read again only when it changed; `harvested.json`
    /// remembers sizes.
    public func harvest(around folder: String) {
        var folders: [String] = []
        var url = URL(filePath: folder)
        while url.path != "/" && folders.count < 8 {
            folders.append(url.path)
            url = url.deletingLastPathComponent()
        }
        let indexURL = root.appending(path: "harvested.json")
        var index = (try? Data(contentsOf: indexURL)).flatMap { try? JSONDecoder().decode([String: Int].self, from: $0) } ?? [:]
        let before = index
        let needle = Data("\"contextUsage\"".utf8)
        for f in folders {
            let dir = claudeHome.appending(path: "projects/\(ClaudePaths.slug(f))")
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                guard index[file.path] != size else { continue }
                index[file.path] = size
                guard let data = try? Data(contentsOf: file, options: .mappedIfSafe), data.range(of: needle) != nil else { continue }
                JSONLines.forEachLine(in: file, containing: ["\"contextUsage\""]) { obj in
                    guard let usage = obj["contextUsage"] as? [String: Any], let cwd = obj["cwd"] as? String,
                          let date = (obj["timestamp"] as? String).flatMap(HealthText.date),
                          let m = MeasuredContext.parse(contextUsage: usage, folder: cwd, at: date, session: obj["sessionId"] as? String)
                    else { return }
                    save(m)
                }
            }
        }
        if index != before {
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try? JSONEncoder().encode(index).write(to: indexURL, options: .atomic)
        }
    }
}

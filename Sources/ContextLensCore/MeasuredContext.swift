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

    public func category(_ name: String) -> Int {
        categories.first { $0.name == name }?.tokens ?? 0
    }

    /// MCP tool schemas per server, largest first.
    public var mcpServers: [Row] {
        var byServer: [String: Int] = [:]
        for t in mcpTools { byServer[t.detail ?? t.name, default: 0] += t.tokens }
        return byServer.map { Row(name: $0.key, tokens: $0.value) }.sorted { ($0.tokens, $1.name) > ($1.tokens, $0.name) }
    }

    /// What no file shows: the harness prompt, the built-in tool definitions and MCP tool schemas.
    public var notInFiles: Int { category("System prompt") + category("System tools") + category("MCP tools") }

    /// Parses the markdown `/context` prints.
    public static func parse(_ text: String, folder: String, at date: Date = Date()) -> MeasuredContext? {
        var model: String?, used: Int?, window: Int?
        var section = ""
        var categories: [Row] = [], mcp: [Row] = [], skills: [Row] = []
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
            default:
                break
            }
        }
        guard let used else { return nil }
        return MeasuredContext(folder: folder, measuredAt: date, model: model, used: used, window: window,
                               categories: categories, mcpTools: mcp, skills: skills)
    }

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

/// Runs `claude -p "/context"` in a folder and keeps the result in
/// `~/.context-lens/context/<folder>.json`.
public struct MeasuredContextStore: Sendable {
    public let root: URL

    public init(root: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".context-lens/context")
    }

    func file(_ folder: String) -> URL {
        root.appending(path: folder.replacingOccurrences(of: "/", with: "-") + ".json")
    }

    public func cached(_ folder: String) -> MeasuredContext? {
        guard let data = try? Data(contentsOf: file(folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeasuredContext.self, from: data)
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

    public func save(_ m: MeasuredContext) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? encoder.encode(m).write(to: file(m.folder), options: .atomic)
    }
}

import Foundation

/// One time a session used a skill. Being listed in the context is not a use; only these are:
///
/// - `model`: the agent called the skill tool (Claude Code `Skill`, Copilot `agent-invoked`).
/// - `user`: the user typed `/skill` (Claude Code `<command-name>`, Copilot `user-invoked`).
/// - `subagent`: a Claude Code subagent called the `Skill` tool.
/// - `read`: the agent read a `SKILL.md` itself (Claude Code `Read` or a shell reader such as
///   `cat` or `sed -n`; Codex has no skill tool, so this is how Codex uses skills).
/// - `subagentRead`: a Claude Code subagent read a `SKILL.md`.
/// - `cli`: the agent ran a skill's own command line tool through a package runner
///   (`npx -y deckify-cli` for a skill named `deckify`) without loading the skill.
public struct SkillEvent: Codable, Sendable, Hashable {
    public enum Trigger: String, Codable, Sendable, CaseIterable {
        case model, user, subagent, read, subagentRead, cli

        public var label: String {
            switch self {
            case .model: "model"
            case .user: "slash command"
            case .subagent: "subagent"
            case .read: "read SKILL.md"
            case .subagentRead: "subagent read SKILL.md"
            case .cli: "ran its CLI"
            }
        }

        /// Signs of use rather than loads: they count once per session, and not at all in a
        /// session that loaded the skill.
        public var once: Bool { self == .read || self == .subagentRead || self == .cli }
    }

    public var skill: String
    public var trigger: Trigger
    public var harness: String
    public var time: Date?
    /// The SKILL.md the session read or loaded, when the transcript names it.
    public var path: String?
    /// The skill tool reported an error, such as `Unknown skill`.
    public var failed: Bool = false

    public init(skill: String, trigger: Trigger, harness: String, time: Date?, path: String? = nil, failed: Bool = false) {
        self.skill = skill
        self.trigger = trigger
        self.harness = harness
        self.time = time
        self.path = path
        self.failed = failed
    }
}

/// What one transcript file contributed: its session, folder and skill events.
public struct SkillFileScan: Codable, Sendable {
    public var harness: String
    /// `claude:<id>`, `codex:<id>` or `copilot:<id>`. Subagent files point at their parent session.
    public var session: String
    /// The transcript to open for this session (the parent transcript for a subagent).
    public var file: String
    public var cwd: String
    public var modified: Date
    public var events: [SkillEvent]
    /// Skill names Claude Code recorded in `invoked_skills`, which tell skill slash commands apart
    /// from built-in ones such as `/model`.
    public var invoked: [String] = []
    /// The first timestamp in the file.
    public var started: Date?
    /// The first prompt, for harnesses Past sessions does not list (Copilot CLI).
    public var title: String?
}

/// Every transcript's skill events, read from the cache where the file is unchanged.
public struct SkillScan: Sendable {
    public var files: [SkillFileScan]
    public var parsed: Int
    public var cached: Int
    public var seconds: Double
}

/// Finds skill events in Claude Code transcripts, Codex rollouts and Copilot CLI session logs.
/// No model calls. A full pass reads every byte once, so results are cached per file under
/// `~/.context-lens/skills/` keyed by size and modification time.
public struct SkillUsageScanner: Sendable {
    public var env: HarnessEnvironment
    public var copilotHome: URL
    public var cacheFile: URL

    static let cacheVersion = 3

    public init(env: HarnessEnvironment = .current, cacheFile: URL? = nil) {
        self.env = env
        copilotHome = env.home.appending(path: ".copilot")
        self.cacheFile = cacheFile ?? env.home.appending(path: ".context-lens/skills/scan-cache.json")
    }

    struct Source {
        var file: URL
        var harness: String
        var size: Int
        var modified: Date
    }

    struct CacheEntry: Codable {
        var size: Int
        var modified: Double
        var scan: SkillFileScan?
    }

    struct Cache: Codable {
        var version: Int
        var files: [String: CacheEntry]
    }

    /// Scans files modified since `since` (all files when nil).
    public func scan(since: Date? = nil) -> SkillScan {
        let started = Date()
        let sources = files(since: since)
        var cache = loadCache()
        var todo: [Int] = []
        var results = [SkillFileScan?](repeating: nil, count: sources.count)
        for (i, s) in sources.enumerated() {
            if let hit = cache.files[s.file.path], hit.size == s.size, hit.modified == s.modified.timeIntervalSince1970 {
                results[i] = hit.scan
            } else {
                todo.append(i)
            }
        }
        let parsed = UnsafeMutableBufferPointer<SkillFileScan?>.allocate(capacity: todo.count)
        parsed.initialize(repeating: nil)
        defer {
            parsed.deinitialize()
            parsed.deallocate()
        }
        let jobs = todo
        DispatchQueue.concurrentPerform(iterations: jobs.count) { j in
            parsed[j] = parse(sources[jobs[j]])
        }
        for (j, i) in todo.enumerated() {
            results[i] = parsed[j]
            let s = sources[i]
            cache.files[s.file.path] = CacheEntry(size: s.size, modified: s.modified.timeIntervalSince1970, scan: parsed[j])
        }
        if !todo.isEmpty {
            // Drop entries for transcripts that no longer exist.
            cache.files = cache.files.filter { FileManager.default.fileExists(atPath: $0.key) }
            saveCache(cache)
        }
        return SkillScan(files: results.compactMap { $0 }, parsed: todo.count, cached: sources.count - todo.count,
                         seconds: Date().timeIntervalSince(started))
    }

    func parse(_ s: Source) -> SkillFileScan? {
        switch s.harness {
        case "claude": ClaudeSkillParser(file: s.file, modified: s.modified, home: env.home.path).parse()
        case "codex": CodexSkillParser(file: s.file, modified: s.modified, home: env.home.path).parse()
        default: CopilotSkillParser(file: s.file, modified: s.modified).parse()
        }
    }

    /// One transcript and, for Claude Code, its subagent transcripts, read directly without the cache.
    public func scan(transcript file: URL, harness: String) -> [SkillFileScan] {
        var urls = [file]
        if harness == "claude" {
            let subagents = file.deletingPathExtension().appending(path: "subagents")
            urls += FileUtil.children(subagents).filter { $0.pathExtension == "jsonl" }
        }
        return urls.compactMap { url in
            let modified = FileUtil.modified(url) ?? .distantPast
            return parse(Source(file: url, harness: harness, size: 0, modified: modified))
        }
    }

    func files(since: Date?) -> [Source] {
        var out: [Source] = []
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        func walk(_ root: URL, harness: String, match: (URL) -> Bool) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
            for case let url as URL in e where url.pathExtension == "jsonl" && match(url) {
                guard let v = try? url.resourceValues(forKeys: keys), let size = v.fileSize, size > 0 else { continue }
                let modified = v.contentModificationDate ?? .distantPast
                if let since, modified < since { continue }
                out.append(Source(file: url, harness: harness, size: size, modified: modified))
            }
        }
        walk(env.claudeHome.appending(path: "projects"), harness: "claude") { _ in true }
        for root in [env.codexHome.appending(path: "sessions"), env.codexHome.appending(path: "archived_sessions")] {
            walk(root, harness: "codex") { $0.lastPathComponent.hasPrefix("rollout-") }
        }
        walk(copilotHome.appending(path: "session-state"), harness: "copilot") { $0.lastPathComponent == "events.jsonl" }
        return out
    }

    func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheFile),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              cache.version == Self.cacheVersion else { return Cache(version: Self.cacheVersion, files: [:]) }
        return cache
    }

    func saveCache(_ cache: Cache) {
        try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
    }
}

// MARK: - Recognizing SKILL.md reads

enum SkillPaths {
    /// Programs that print a file. Anything else that names a SKILL.md (an editor, `ls`, `rg -g`,
    /// `apply_patch`) is not a use.
    static let readers: Set<String> = ["cat", "head", "tail", "sed", "less", "more", "bat", "nl", "awk", "view"]

    /// The skill name for a SKILL.md path: `plugin:skill` for plugin caches, else the folder name.
    static func name(_ path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        // Skills live under a `skills/` folder; other SKILL.md files (scheduled tasks) are not skills.
        guard parts.count >= 3, parts.last == "SKILL.md", parts.dropLast(2).contains("skills") else { return nil }
        let skill = parts[parts.count - 2]
        guard !skill.isEmpty, skill != ".", skill != "..", !skill.hasPrefix("$") else { return nil }
        if let i = parts.indices.dropLast().last(where: { parts[$0] == "plugins" && ["cache", "marketplaces"].contains(parts[$0 + 1]) }) {
            let rest = Array(parts[(i + 1)...])
            // cache/<marketplace>/<plugin>/<version>/skills/<skill>/SKILL.md
            if rest.first == "cache", rest.count >= 7, rest[rest.count - 3] == "skills" { return "\(rest[2]):\(skill)" }
            // marketplaces/<marketplace>/plugins/<plugin>/skills/<skill>/SKILL.md
            if let p = rest.firstIndex(of: "plugins"), p + 3 < rest.count, rest[p + 2] == "skills" { return "\(rest[p + 1]):\(skill)" }
        }
        return skill
    }

    /// SKILL.md paths that a shell command prints. Only absolute, `~/`, `$HOME/` and `./` paths
    /// count, so `gh api …/SKILL.md` and globs do not. Variables set earlier in the command
    /// (`K=/repo/.claude/skills`) and `for s in a b; do cat $K/$s/SKILL.md; done` loops resolve
    /// to each path they name.
    static func reads(inCommand command: String) -> [String] {
        var out: [String] = []
        var vars: [String: [String]] = [:]
        for segment in segments(command) {
            var tokens = shellWords(segment)
            if tokens.count >= 3, tokens[0] == "for", tokens[2] == "in" {
                vars[tokens[1]] = Array(tokens.dropFirst(3))
                continue
            }
            if !tokens.isEmpty, tokens.allSatisfy(isAssignment) {
                for t in tokens {
                    let i = t.firstIndex(of: "=")!
                    let values = substitute(String(t[t.index(after: i)...]), vars)
                    vars[String(t[..<i])] = values.isEmpty || t.contains("$(") || t.contains("`") ? nil : values
                }
                continue
            }
            guard segment.contains("SKILL.md") else { continue }
            while let t = tokens.first, isAssignment(t) || ["sudo", "command", "noglob", "builtin", "do", "then", "else", "time"].contains(t) {
                tokens.removeFirst()
            }
            guard let head = tokens.first.map({ URL(filePath: $0).lastPathComponent }), readers.contains(head) else { continue }
            if head == "sed", tokens.contains(where: { $0.hasPrefix("-i") }) { continue }
            for t in tokens.dropFirst() where t.hasSuffix("/SKILL.md") && !t.contains("*") {
                for p in substitute(t, vars) where p.hasPrefix("/") || p.hasPrefix("~/") || p.hasPrefix("$HOME/") || p.hasPrefix("${HOME}/") || p.hasPrefix(".") {
                    out.append(p)
                }
            }
        }
        return out
    }

    /// Package runners that start a tool by name.
    static let runners = ["npx ", "bunx ", "pnpm dlx ", "yarn dlx ", "uvx ", "pipx run "]

    /// Tools a shell command starts through a package runner: `deckify-cli` for `npx -y deckify-cli@1 plan`.
    static func runs(inCommand command: String) -> [String] {
        var out: [String] = []
        for segment in segments(command) {
            var tokens = shellWords(segment)
            while let t = tokens.first, isAssignment(t) || ["sudo", "command", "do", "then", "else", "time"].contains(t) {
                tokens.removeFirst()
            }
            guard let head = tokens.first else { continue }
            let skip = ["pnpm", "yarn", "pipx"].contains(head) ? 2 : 1
            guard runners.contains(tokens.prefix(skip).joined(separator: " ") + " ") else { continue }
            guard var tool = tokens.dropFirst(skip).first(where: { !$0.hasPrefix("-") }), !tool.contains("$") else { continue }
            // `@scope/tool@1.2` is `tool`.
            if let slash = tool.lastIndex(of: "/") { tool = String(tool[tool.index(after: slash)...]) }
            if let at = tool.dropFirst().firstIndex(of: "@") { tool = String(tool[..<at]) }
            if !tool.isEmpty { out.append(tool) }
        }
        return out
    }

    static func isAssignment(_ word: String) -> Bool {
        guard let i = word.firstIndex(of: "="), i > word.startIndex else { return false }
        return word[..<i].allSatisfy { $0 == "_" || $0.isASCII && ($0.isLetter || $0.isNumber) } && !word.first!.isNumber
    }

    static let variable = try! NSRegularExpression(pattern: #"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"#)

    /// Every expansion of the variables in `word`. Empty when a variable other than `HOME` is
    /// unknown, so `$TMP/x/SKILL.md` names nothing.
    static func substitute(_ word: String, _ vars: [String: [String]]) -> [String] {
        guard let m = variable.matches(in: word, range: NSRange(word.startIndex..., in: word))
            .first(where: { Range($0.range(at: 1), in: word).map { word[$0] != "HOME" } ?? false }),
            let whole = Range(m.range, in: word), let name = Range(m.range(at: 1), in: word) else { return [word] }
        guard let values = vars[String(word[name])] else { return [] }
        return values.flatMap { substitute(word.replacingCharacters(in: whole, with: $0), vars) }
    }

    /// Splits a command on `;`, `|`, `&` and newlines outside quotes.
    static func segments(_ command: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        for c in command {
            if let q = quote {
                if c == q { quote = nil }
                current.append(c)
            } else if c == "'" || c == "\"" {
                quote = c
                current.append(c)
            } else if c == ";" || c == "|" || c == "&" || c == "\n" {
                out.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        out.append(current)
        return out
    }

    /// Splits on whitespace, keeping quoted runs together and dropping the quotes. Redirections
    /// (`2>/dev/null`, `> out`) end a word and swallow the word after them.
    static func shellWords(_ s: String) -> [String] {
        var words: [String] = []
        var current = ""
        var quote: Character?
        var skipNext = false
        func flush() {
            if !current.isEmpty {
                if skipNext { skipNext = false } else { words.append(current) }
            }
            current = ""
        }
        for c in s {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "'" || c == "\"" {
                quote = c
            } else if c == ">" || c == "<" {
                // `2>` or `>`: drop a bare fd number, then skip the target.
                if current.allSatisfy(\.isNumber) { current = "" }
                flush()
                skipNext = true
            } else if c.isWhitespace {
                flush()
            } else {
                current.append(c)
            }
        }
        flush()
        return words
    }

    static func expand(_ path: String, home: String) -> String {
        for prefix in ["~/", "$HOME/", "${HOME}/"] where path.hasPrefix(prefix) {
            return home + "/" + path.dropFirst(prefix.count)
        }
        return path
    }
}

// MARK: - Claude Code

struct ClaudeSkillParser {
    let file: URL
    let modified: Date
    let home: String

    static let commandPattern = try! NSRegularExpression(pattern: #"<command-name>/?([^<\s]+)</command-name>"#)

    func parse() -> SkillFileScan? {
        guard let scanner = LineScanner(file) else { return nil }
        let subagent = file.path.contains("/subagents/")
        let stem = file.deletingPathExtension().lastPathComponent
        // `<project>/<session>/subagents/agent-x.jsonl` belongs to `<project>/<session>.jsonl`.
        let sessionDir = file.deletingLastPathComponent().deletingLastPathComponent()
        let parentID = subagent ? sessionDir.lastPathComponent : stem
        let transcript = subagent ? sessionDir.deletingLastPathComponent().appending(path: "\(parentID).jsonl") : file
        var out = SkillFileScan(harness: "claude", session: "claude:" + parentID, file: transcript.path, cwd: "",
                                modified: modified, events: [])
        var pending: [String: Int] = [:]

        scanner.forEach { line in
            if out.started == nil { out.started = LineScanner.timestamp(line) }
            if out.cwd.isEmpty, LineScanner.has(line, "\"cwd\":\""), let obj = LineScanner.json(line), let cwd = obj["cwd"] as? String {
                out.cwd = cwd
            }
            let toolUse = LineScanner.has(line, "\"tool_use\"") && (LineScanner.has(line, "\"name\":\"Skill\"") || LineScanner.has(line, "SKILL.md")
                || LineScanner.has(line, "\"name\":\"Bash\"") && (LineScanner.has(line, "npx ") || LineScanner.has(line, "bunx ")
                    || LineScanner.has(line, " dlx ") || LineScanner.has(line, "uvx ") || LineScanner.has(line, "pipx run ")))
            let toolError = !pending.isEmpty && LineScanner.has(line, "\"is_error\":true")
            let command = LineScanner.has(line, "<command-name>")
            if toolUse || toolError || command, let obj = LineScanner.json(line) {
                let type = obj["type"] as? String
                let content = (obj["message"] as? [String: Any])?["content"]
                let parts = content as? [[String: Any]] ?? []
                let time = LineScanner.timestamp(line)
                if type == "assistant", toolUse {
                    for part in parts where part["type"] as? String == "tool_use" {
                        let name = part["name"] as? String ?? ""
                        let input = part["input"] as? [String: Any] ?? [:]
                        if name == "Skill", let skill = input["skill"] as? String {
                            if let id = part["id"] as? String { pending[id] = out.events.count }
                            out.events.append(SkillEvent(skill: skill, trigger: subagent ? .subagent : .model, harness: "claude", time: time))
                        } else if name == "Read", let path = input["file_path"] as? String, path.hasSuffix("/SKILL.md") {
                            addRead(path, time: time, to: &out)
                        } else if name == "Bash", let command = input["command"] as? String {
                            for path in SkillPaths.reads(inCommand: command) { addRead(path, time: time, to: &out) }
                            for tool in SkillPaths.runs(inCommand: command) {
                                out.events.append(SkillEvent(skill: tool, trigger: .cli, harness: "claude", time: time))
                            }
                        }
                    }
                } else if type == "user" {
                    for part in parts where part["is_error"] as? Bool == true {
                        if let id = part["tool_use_id"] as? String, let i = pending[id] { out.events[i].failed = true }
                    }
                    // Only a message that is the command itself; a pasted transcript mentioning one is not.
                    if command, let text = Self.typed(content)?.trimmingCharacters(in: .whitespacesAndNewlines), text.hasPrefix("<command-"),
                       let m = Self.commandPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                       let r = Range(m.range(at: 1), in: text) {
                        out.events.append(SkillEvent(skill: String(text[r]), trigger: .user, harness: "claude", time: time))
                    }
                }
            } else if LineScanner.has(line, "\"invoked_skills\"") {
                guard let obj = LineScanner.json(line), let a = obj["attachment"] as? [String: Any], a["type"] as? String == "invoked_skills" else { return true }
                for s in a["skills"] as? [[String: Any]] ?? [] {
                    if let n = s["name"] as? String, !out.invoked.contains(n) { out.invoked.append(n) }
                }
            }
            return true
        }
        return out
    }

    func addRead(_ path: String, time: Date?, to out: inout SkillFileScan) {
        let full = SkillPaths.expand(path, home: home)
        guard let name = SkillPaths.name(full) else { return }
        let subagent = file.path.contains("/subagents/")
        out.events.append(SkillEvent(skill: name, trigger: subagent ? .subagentRead : .read, harness: "claude", time: time, path: full))
    }

    static func typed(_ content: Any?) -> String? {
        if let s = content as? String { return s }
        return (content as? [[String: Any]])?.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.first
    }
}

// MARK: - Codex

struct CodexSkillParser {
    let file: URL
    let modified: Date
    let home: String

    func parse() -> SkillFileScan? {
        guard let scanner = LineScanner(file) else { return nil }
        let id = String(file.deletingPathExtension().lastPathComponent.suffix(36))
        var out = SkillFileScan(harness: "codex", session: "codex:" + id, file: file.path, cwd: "", modified: modified, events: [])
        scanner.forEach { line in
            if out.started == nil { out.started = LineScanner.timestamp(line) }
            if out.cwd.isEmpty, LineScanner.has(line, "\"session_meta\""), let obj = LineScanner.json(line), obj["type"] as? String == "session_meta" {
                out.cwd = (obj["payload"] as? [String: Any])?["cwd"] as? String ?? ""
                return true
            }
            // The instructions list every skill's path; only tool calls are uses.
            guard LineScanner.has(line, "SKILL.md"), let obj = LineScanner.json(line), obj["type"] as? String == "response_item",
                  let p = obj["payload"] as? [String: Any],
                  ["custom_tool_call", "function_call", "local_shell_call"].contains(p["type"] as? String ?? "") else { return true }
            if p["name"] as? String == "apply_patch" { return true }
            let time = LineScanner.timestamp(line)
            var seen = Set<String>()
            for command in Self.commands(p) {
                for path in SkillPaths.reads(inCommand: command) {
                    let full = SkillPaths.expand(path, home: home)
                    guard seen.insert(full).inserted, let name = SkillPaths.name(full) else { continue }
                    out.events.append(SkillEvent(skill: name, trigger: .read, harness: "codex", time: time, path: full))
                }
            }
            return true
        }
        return out
    }

    /// Shell commands in a call: every `cmd:` in an `exec` script, or the argument object's command.
    static func commands(_ p: [String: Any]) -> [String] {
        if let action = p["action"] as? [String: Any], let c = action["command"] as? [String] { return [c.joined(separator: " ")] }
        let raw = p["input"] as? String ?? p["arguments"] as? String ?? ""
        if raw.hasPrefix("{") {
            return CodexHealthParser.command(raw).map { [$0] } ?? []
        }
        return CodexHealthParser.cmdPattern.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)).compactMap { m in
            guard let r = Range(m.range(at: 1), in: raw) else { return nil }
            let quoted = String(raw[r])
            if quoted.hasPrefix("\""), let s = try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: .fragmentsAllowed) as? String {
                return s
            }
            return String(quoted.dropFirst().dropLast())
        }
    }
}

// MARK: - Copilot CLI

/// `~/.copilot/session-state/<id>/events.jsonl` records `skill.invoked` with the skill's name,
/// path and whether the agent or the user invoked it.
struct CopilotSkillParser {
    let file: URL
    let modified: Date

    func parse() -> SkillFileScan? {
        guard let scanner = LineScanner(file) else { return nil }
        let id = file.deletingLastPathComponent().lastPathComponent
        var out = SkillFileScan(harness: "copilot", session: "copilot:" + id, file: file.path, cwd: "", modified: modified, events: [])
        scanner.forEach { line in
            if out.started == nil { out.started = LineScanner.timestamp(line) }
            if out.title == nil, LineScanner.has(line, "\"type\":\"user.message\""),
               let obj = LineScanner.json(line), obj["type"] as? String == "user.message",
               let text = (obj["data"] as? [String: Any])?["content"] as? String {
                let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                out.title = String(first.trimmingCharacters(in: .whitespaces).prefix(120))
            }
            if out.cwd.isEmpty, LineScanner.has(line, "\"type\":\"session.start\"") {
                if let obj = LineScanner.json(line), let ctx = (obj["data"] as? [String: Any])?["context"] as? [String: Any] {
                    out.cwd = ctx["cwd"] as? String ?? ""
                }
            } else if LineScanner.has(line, "\"type\":\"skill.invoked\"") {
                guard let obj = LineScanner.json(line), obj["type"] as? String == "skill.invoked",
                      let data = obj["data"] as? [String: Any], let name = data["name"] as? String else { return true }
                let plugin = data["pluginName"] as? String
                let trigger: SkillEvent.Trigger = data["trigger"] as? String == "user-invoked" ? .user : .model
                out.events.append(SkillEvent(
                    skill: plugin.map { "\($0):\(name)" } ?? name, trigger: trigger, harness: "copilot",
                    time: (obj["timestamp"] as? String).flatMap(HealthText.date), path: data["path"] as? String
                ))
            }
            return true
        }
        return out
    }
}

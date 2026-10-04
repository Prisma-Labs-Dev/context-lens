import Foundation

/// Pulls friction events and per-session stats out of Claude Code transcripts, Codex rollouts and
/// OpenClaw's Codex rollouts. No model calls: everything here is byte scanning and JSON parsing.
///
/// Speed: a week of transcripts is about 2 GB, mostly tool output. Each line is first checked with
/// `memmem` for the few markers that matter; only those lines are JSON-parsed, and files run in
/// parallel.
public struct HealthExtractor: Sendable {
    public var env: HarnessEnvironment
    public var openClawHome: URL
    public var claudeDesktopSessions: URL

    public init(env: HarnessEnvironment = .current) {
        self.env = env
        openClawHome = env.home.appending(path: ".openclaw")
        claudeDesktopSessions = env.home.appending(path: "Library/Application Support/Claude/claude-code-sessions")
    }

    struct Source {
        var file: URL
        var harness: String
        var subagent: Bool
    }

    public func extract(since: Date) -> HealthExtract {
        let started = Date()
        let sources = transcriptFiles(since: since)
        let desktop = desktopLinks()
        let names = SessionIndex(env: env).codexThreadNames()
        let results = UnsafeMutableBufferPointer<(HealthSession, [HealthEvent])?>.allocate(capacity: sources.count)
        results.initialize(repeating: nil)
        defer {
            results.deinitialize()
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: sources.count) { i in
            let s = sources[i]
            results[i] = s.harness == "claude"
                ? ClaudeHealthParser(source: s, since: since, links: desktop).parse()
                : CodexHealthParser(source: s, since: since, names: names).parse()
        }
        let all = results.compactMap { $0 }
        let bytes = sources.reduce(0) { $0 + ((try? $1.file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return HealthExtract(
            since: since,
            sessions: all.map(\.0).sorted { ($0.started ?? .distantPast) < ($1.started ?? .distantPast) },
            events: all.flatMap(\.1),
            files: sources.count, bytes: bytes, seconds: Date().timeIntervalSince(started)
        )
    }

    func transcriptFiles(since: Date) -> [Source] {
        var out: [Source] = []
        func recent(_ url: URL) -> Bool {
            ((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >= since
        }
        func walk(_ root: URL, harness: String, match: (URL) -> Bool) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
            for case let url as URL in e where url.pathExtension == "jsonl" && match(url) && recent(url) {
                out.append(Source(file: url, harness: harness, subagent: url.path.contains("/subagents/")))
            }
        }
        walk(env.claudeHome.appending(path: "projects"), harness: "claude") { _ in true }
        for root in [env.codexHome.appending(path: "sessions"), env.codexHome.appending(path: "archived_sessions")] {
            walk(root, harness: "codex") { $0.lastPathComponent.hasPrefix("rollout-") }
        }
        for agent in FileUtil.children(openClawHome.appending(path: "agents")) {
            walk(agent.appending(path: "agent/codex-home/sessions"), harness: "openclaw") { $0.lastPathComponent.hasPrefix("rollout-") }
        }
        return out
    }

    /// Claude desktop app session ids by CLI session id, for `claude://` links.
    func desktopLinks() -> [String: String] {
        var out: [String: String] = [:]
        guard let e = FileManager.default.enumerator(at: claudeDesktopSessions, includingPropertiesForKeys: nil) else { return out }
        for case let url as URL in e where url.lastPathComponent.hasPrefix("local_") && url.pathExtension == "json" {
            let head = JSONLines.head(url, bytes: 2048)
            if let cli = JSONLines.firstString("cliSessionId", in: head) {
                out[cli] = url.deletingPathExtension().lastPathComponent
            }
        }
        return out
    }
}

// MARK: - Shared helpers

enum HealthText {
    /// The program a shell command runs, for blame: `gh`, `xcodebuild`, `~/bin/sim-lease`,
    /// `scripts/run.sh`. Skips `cd`, `source`, `export` and env assignments in front of it.
    static func commandHead(_ command: String, home: String) -> String {
        let firstLine = command.split(separator: "\n").first.map(String.init) ?? command
        let segments = firstLine.components(separatedBy: CharacterSet(charactersIn: ";|&")).map { $0.trimmingCharacters(in: .whitespaces) }
        let skip: Set<String> = ["cd", "source", ".", "export", "set", "unset", "pushd", "popd", "true", "echo", "sleep", "local", "trap"]
        let wrappers: Set<String> = ["env", "time", "sudo", "nohup", "exec", "command", "xcrun", "npx", "pnpm", "bunx", "uv", "uvx"]
        for segment in segments where !segment.isEmpty {
            var tokens = segment.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            while let t = tokens.first, t.contains("="), !t.hasPrefix("-"), !t.contains("/") || t.firstIndex(of: "=")! < t.firstIndex(of: "/")! {
                tokens.removeFirst()
            }
            guard var head = tokens.first?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()`{}$")) else { continue }
            if skip.contains(head) || head.isEmpty { continue }
            if wrappers.contains(head), tokens.count > 1 {
                let next = tokens.dropFirst().first { !$0.hasPrefix("-") } ?? head
                head = head == "xcrun" || head == "pnpm" || head == "npx" ? "\(head) \(next)" : next
                if head.hasPrefix("timeout") { continue }
            }
            if head.hasPrefix(home + "/bin/") { return "~/bin/" + head.dropFirst(home.count + 5) }
            if head.hasPrefix("/") { return URL(filePath: head).lastPathComponent }
            if head.hasPrefix("./") { head.removeFirst(2) }
            return head.count > 60 ? String(head.prefix(60)) : head
        }
        return "shell"
    }

    /// The same file in the main checkout: worktree copies of a rule file are one rule file.
    /// `repo/.claude/worktrees/<name>/x` becomes `repo/x`; `~/.codex/worktrees/<id>/` becomes `~/.codex/worktrees/*/`.
    static func mainCheckout(_ path: String) -> String {
        var p = path.replacingOccurrences(of: #"/\.claude/worktrees/[^/]+/"#, with: "/", options: .regularExpression)
        p = p.replacingOccurrences(of: #"/\.codex/worktrees/[^/]+/"#, with: "/.codex/worktrees/*/", options: .regularExpression)
        return p
    }

    /// Seconds spent between timestamps, ignoring idle gaps over 5 minutes.
    static func activeSeconds(_ times: [Date]) -> Double {
        var total = 0.0
        for (a, b) in zip(times, times.dropFirst()) {
            let gap = b.timeIntervalSince(a)
            if gap > 0, gap < 300 { total += gap }
        }
        return total
    }

    /// Fast parse of `2026-10-04T10:00:36.189Z`; falls back to ISO8601DateFormatter.
    static func date(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count >= 19, u[4] == 45, u[7] == 45, u[10] == 84 else { return SessionIndex.parseISO(s) }
        func n(_ a: Int, _ b: Int) -> Int { u[a..<b].reduce(0) { $0 * 10 + Int($1) - 48 } }
        var c = DateComponents()
        c.year = n(0, 4); c.month = n(5, 7); c.day = n(8, 10)
        c.hour = n(11, 13); c.minute = n(14, 16); c.second = n(17, 19)
        guard u.count == 19 || u.last == 90 else { return SessionIndex.parseISO(s) }
        guard let d = utcCalendar.date(from: c) else { return nil }
        var frac = 0.0
        if u.count > 20, u[19] == 46 {
            var scale = 0.1
            for b in u[20...] where b >= 48 && b <= 57 {
                frac += Double(b - 48) * scale
                scale /= 10
            }
        }
        return d.addingTimeInterval(frac)
    }

    static let utcCalendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
}

/// Line scanning over a memory-mapped file with `memmem` prefilters.
struct LineScanner {
    let data: Data

    init?(_ url: URL) {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        data = d
    }

    /// Calls `body` with each line's bytes. Return false to stop.
    func forEach(_ body: (UnsafeRawBufferPointer) -> Bool) {
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var start = 0
            let count = buf.count
            while start < count {
                let rest = count - start
                let nl = memchr(base + start, 0x0A, rest)
                let end = nl.map { base.distance(to: UnsafeRawPointer($0)) } ?? count
                if end > start, !body(UnsafeRawBufferPointer(rebasing: buf[start..<end])) { return }
                start = end + 1
            }
        }
    }

    static func has(_ line: UnsafeRawBufferPointer, _ needle: StaticString) -> Bool {
        guard let base = line.baseAddress else { return false }
        return memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
    }

    /// The ISO timestamp after the first `"timestamp":"` in the line.
    static func timestamp(_ line: UnsafeRawBufferPointer) -> Date? {
        let needle: StaticString = "\"timestamp\":\""
        guard let base = line.baseAddress,
              let hit = memmem(base, line.count, needle.utf8Start, needle.utf8CodeUnitCount) else { return nil }
        let start = base.distance(to: UnsafeRawPointer(hit)) + needle.utf8CodeUnitCount
        guard start + 19 <= line.count else { return nil }
        var end = start
        while end < line.count, end - start < 40, line[end] != 0x22 { end += 1 }
        return HealthText.date(String(decoding: line[start..<end], as: UTF8.self))
    }

    /// The first two `"type":"…"` values in the line.
    static func types(_ line: UnsafeRawBufferPointer) -> (String?, String?) {
        let needle: StaticString = "\"type\":\""
        guard let base = line.baseAddress else { return (nil, nil) }
        var found: [String] = []
        var offset = 0
        while found.count < 2, offset < line.count,
              let hit = memmem(base + offset, line.count - offset, needle.utf8Start, needle.utf8CodeUnitCount) {
            let start = base.distance(to: UnsafeRawPointer(hit)) + needle.utf8CodeUnitCount
            var end = start
            while end < line.count, end - start < 64, line[end] != 0x22 { end += 1 }
            found.append(String(decoding: line[start..<end], as: UTF8.self))
            offset = end
        }
        return (found.first, found.count > 1 ? found[1] : nil)
    }

    static func json(_ line: UnsafeRawBufferPointer) -> [String: Any]? {
        let d = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: line.baseAddress!), count: line.count, deallocator: .none)
        return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
    }
}

/// Builds events for one session, with the bookkeeping both parsers share.
struct SessionRecorder {
    var session: HealthSession
    var events: [HealthEvent] = []
    var times: [Date] = []
    var failures: [String: Int] = [:]
    let since: Date
    let home = FileManager.default.homeDirectoryForCurrentUser.path

    mutating func add(_ kind: HealthEvent.Kind, time: Date?, tool: String? = nil, source: String, input: String? = nil,
                      text: String, context: String? = nil, retryKey: String? = nil) {
        var repeats = 0
        if let retryKey {
            repeats = failures[retryKey, default: 0]
            failures[retryKey] = repeats + 1
        }
        if let time, time < since { return }
        events.append(HealthEvent(
            id: "\(session.id)#\(events.count)", session: session.id, harness: session.harness, kind: kind, time: time,
            tool: tool, source: source, input: input.map { Redactor.clip($0, 300) }, text: Redactor.clip(text, 700),
            context: context.map { Redactor.clip($0, 400) }, repeats: repeats, skills: session.skills
        ))
    }

    mutating func finish() -> (HealthSession, [HealthEvent]) {
        times.sort()
        session.started = times.first
        session.ended = times.last
        session.activeSeconds = HealthText.activeSeconds(times.filter { $0 >= since })
        session.ruleFiles = Array(NSOrderedSet(array: session.ruleFiles.map {
            FileUtil.abbreviate(HealthText.mainCheckout($0), home: URL(filePath: home))
        })) as? [String] ?? session.ruleFiles
        session.title = session.title.map { Redactor.clip(SessionIndex.clean($0), 140) }
        return (session, events)
    }
}

// MARK: - Claude Code

struct ClaudeHealthParser {
    let source: HealthExtractor.Source
    let since: Date
    let links: [String: String]

    func parse() -> (HealthSession, [HealthEvent])? {
        guard let scanner = LineScanner(source.file) else { return nil }
        let stem = source.file.deletingPathExtension().lastPathComponent
        let parentID = source.subagent ? source.file.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent : stem
        let id = "claude:" + (source.subagent ? "\(parentID)/\(stem)" : stem)
        var r = SessionRecorder(
            session: HealthSession(id: id, harness: "claude", file: source.file.path, cwd: "", link: links[parentID].map { "claude://claude.ai/epitaxy/\($0)" },
                                   subagent: source.subagent),
            since: since
        )
        var tools: [String: (name: String, input: String, source: String)] = [:]
        var seenMessages = Set<String>()
        var lastAssistantText: String?
        var sawPrompt = false

        scanner.forEach { line in
            let time = LineScanner.timestamp(line)
            if let time { r.times.append(time) }
            if LineScanner.has(line, "\"type\":\"assistant\"") {
                guard let obj = LineScanner.json(line), let msg = obj["message"] as? [String: Any] else { return true }
                if r.session.cwd.isEmpty { r.session.cwd = obj["cwd"] as? String ?? "" }
                if let model = msg["model"] as? String, model != "<synthetic>" { r.session.model = model }
                if let mid = msg["id"] as? String, seenMessages.insert(mid).inserted, let u = msg["usage"] as? [String: Any] {
                    r.session.inputTokens += u["input_tokens"] as? Int ?? 0
                    r.session.outputTokens += u["output_tokens"] as? Int ?? 0
                    r.session.cacheReadTokens += u["cache_read_input_tokens"] as? Int ?? 0
                    r.session.cacheWriteTokens += u["cache_creation_input_tokens"] as? Int ?? 0
                }
                for part in msg["content"] as? [[String: Any]] ?? [] {
                    switch part["type"] as? String {
                    case "text":
                        if let t = part["text"] as? String, !t.isEmpty { lastAssistantText = t }
                    case "tool_use":
                        let name = part["name"] as? String ?? "tool"
                        let input = part["input"] as? [String: Any] ?? [:]
                        let summary = Self.summary(name, input)
                        let src = Self.blame(name, input, home: r.home)
                        if let tid = part["id"] as? String { tools[tid] = (name, summary, src) }
                        r.session.toolCalls += 1
                        if name == "Skill", let skill = input["skill"] as? String, !r.session.skills.contains(skill) {
                            r.session.skills.append(skill)
                        }
                        if name == "AskUserQuestion" {
                            r.session.questions += 1
                            r.add(.question, time: time, tool: name, source: "AskUserQuestion", text: summary)
                        }
                    default: break
                    }
                }
            } else if LineScanner.has(line, "\"type\":\"user\"") {
                if LineScanner.has(line, "\"tool_result\"") {
                    guard LineScanner.has(line, "\"is_error\":true"), let obj = LineScanner.json(line),
                          let msg = obj["message"] as? [String: Any] else { return true }
                    for part in msg["content"] as? [[String: Any]] ?? [] where part["is_error"] as? Bool == true {
                        let tid = part["tool_use_id"] as? String ?? ""
                        let call = tools[tid] ?? ("tool", "", "tool")
                        r.session.toolErrors += 1
                        r.add(.toolError, time: time, tool: call.name, source: call.source, input: call.input,
                              text: Self.text(part["content"]), retryKey: call.name + "|" + call.input.prefix(300))
                    }
                    return true
                }
                guard let obj = LineScanner.json(line), obj["isMeta"] as? Bool != true, obj["isCompactSummary"] as? Bool != true,
                      let msg = obj["message"] as? [String: Any] else { return true }
                if r.session.cwd.isEmpty { r.session.cwd = obj["cwd"] as? String ?? "" }
                let text = Self.typedText(msg["content"])
                guard !text.isEmpty else { return true }
                if text.hasPrefix("[Request interrupted") {
                    r.session.interrupts += 1
                    r.add(.interrupt, time: time, source: "user", text: text, context: lastAssistantText.map { String($0.suffix(400)) })
                    return true
                }
                guard !text.hasPrefix("<") else { return true }
                r.session.userMessages += 1
                if !sawPrompt {
                    sawPrompt = true
                    if r.session.title == nil { r.session.title = text }
                    return true
                }
                // Subagent "user" turns are the parent agent's prompts, not a person.
                guard !source.subagent else { return true }
                r.add(.userMessage, time: time, source: "user", text: text, context: lastAssistantText.map { String($0.suffix(400)) })
            } else if LineScanner.has(line, "\"type\":\"attachment\"") {
                guard LineScanner.has(line, "\"instructions\"") || LineScanner.has(line, "\"invoked_skills\"") || LineScanner.has(line, "\"nested_memory\""),
                      let obj = LineScanner.json(line), let a = obj["attachment"] as? [String: Any] else { return true }
                switch a["type"] as? String {
                case "instructions":
                    for f in a["files"] as? [[String: Any]] ?? [] {
                        if let p = f["path"] as? String, !r.session.ruleFiles.contains(p) { r.session.ruleFiles.append(p) }
                    }
                case "nested_memory":
                    if let p = (a["content"] as? [String: Any])?["path"] as? String, !r.session.ruleFiles.contains(p) { r.session.ruleFiles.append(p) }
                case "invoked_skills":
                    for s in a["skills"] as? [[String: Any]] ?? [] {
                        if let n = s["name"] as? String, !r.session.skills.contains(n) { r.session.skills.append(n) }
                    }
                default: break
                }
            } else if LineScanner.has(line, "\"subtype\":\"api_error\"") {
                guard let obj = LineScanner.json(line) else { return true }
                r.session.apiErrors += 1
                let err = obj["error"] ?? obj["content"] ?? "API error"
                r.add(.apiError, time: time, source: "model API", text: Self.text(err))
            } else if LineScanner.has(line, "\"type\":\"custom-title\"") || LineScanner.has(line, "\"type\":\"ai-title\"") {
                if let obj = LineScanner.json(line), let t = (obj["customTitle"] ?? obj["aiTitle"]) as? String { r.session.title = t }
            }
            return true
        }
        guard !r.times.isEmpty, r.times.max()! >= since else { return nil }
        return r.finish()
    }

    /// One line describing the call, for retry detection and for the classifier.
    static func summary(_ name: String, _ input: [String: Any]) -> String {
        for key in ["command", "file_path", "path", "pattern", "url", "query", "skill", "prompt", "description"] {
            if let v = input[key] as? String { return v }
        }
        if let q = (input["questions"] as? [[String: Any]])?.first?["question"] as? String { return q }
        let data = (try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])) ?? Data()
        return String(decoding: data.prefix(400), as: UTF8.self)
    }

    static func blame(_ name: String, _ input: [String: Any], home: String) -> String {
        if name == "Bash", let cmd = input["command"] as? String { return "Bash: " + HealthText.commandHead(cmd, home: home) }
        if name == "Skill", let s = input["skill"] as? String { return "Skill: " + s }
        return name
    }

    static func text(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined(separator: "\n")
        }
        if let d = content as? [String: Any] {
            if let m = d["message"] as? String { return m }
            if let inner = d["error"] { return text(inner) }
        }
        return content.map { "\($0)" } ?? ""
    }

    /// What the user typed: a string, or text parts that are not injected reminders.
    static func typedText(_ content: Any?) -> String {
        if let s = content as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let parts = content as? [[String: Any]] else { return "" }
        return parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.hasPrefix("<system-reminder>") && !$0.isEmpty }
            .joined(separator: "\n")
    }
}

// MARK: - Codex (and OpenClaw's Codex homes)

struct CodexHealthParser {
    let source: HealthExtractor.Source
    let since: Date
    let names: [String: String]

    static let cmdPattern = try! NSRegularExpression(pattern: #"\bcmd\s*:\s*("(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`)"#)
    static let exitPattern = try! NSRegularExpression(pattern: #""exit_code"\s*:\s*(-?\d+)"#)
    static let skillPattern = try! NSRegularExpression(pattern: #"/skills/([A-Za-z0-9_.:-]+)/SKILL\.md"#)
    static let agentsPattern = try! NSRegularExpression(pattern: #"(?:BEGIN [A-Z ]*AGENTS\.md: |AGENTS\.md instructions for )(/[^\s<>"\\]+)"#)
    static let modelPattern = try! NSRegularExpression(pattern: #""model"\s*:\s*"([^"]+)""#)

    func parse() -> (HealthSession, [HealthEvent])? {
        guard let scanner = LineScanner(source.file) else { return nil }
        let stem = source.file.deletingPathExtension().lastPathComponent
        let threadID = String(stem.suffix(36))
        let prefix = source.harness == "openclaw" ? "openclaw:" : "codex:"
        var r = SessionRecorder(
            session: HealthSession(id: prefix + threadID, harness: source.harness, file: source.file.path, cwd: "",
                                   title: names[threadID], link: source.harness == "codex" ? "codex://threads/\(threadID)" : nil,
                                   subagent: false),
            since: since
        )
        var calls: [String: (name: String, input: String, source: String)] = [:]
        var lastAssistantText: String?
        var sawPrompt = false
        var sawAgents = false
        var lastUsage: [String: Any]?

        scanner.forEach { line in
            let time = LineScanner.timestamp(line)
            if let time { r.times.append(time) }
            // Rollout lines start with timestamp and ordinal, so the first two `type` values are the
            // line's and its payload's. Nested items repeat these names, so never search for them.
            let types = LineScanner.types(line)
            let top = types.0, kind = types.1
            if top == "response_item" {
                if kind == "reasoning" { return true }
                let isOutput = kind?.hasSuffix("_call_output") == true
                if isOutput, !(LineScanner.has(line, "exit_code") || LineScanner.has(line, "Script failed") || LineScanner.has(line, "rror")) {
                    return true
                }
                guard let obj = LineScanner.json(line), let p = obj["payload"] as? [String: Any] else { return true }
                switch p["type"] as? String {
                case "custom_tool_call", "function_call", "local_shell_call":
                    let name = p["name"] as? String ?? "tool"
                    let raw = p["input"] as? String ?? p["arguments"] as? String ?? ""
                    let cmd = Self.command(raw)
                    let src = cmd.map { "\(name): " + HealthText.commandHead($0, home: r.home) } ?? (p["namespace"] as? String).map { "\($0).\(name)" } ?? name
                    if let id = p["call_id"] as? String { calls[id] = (name, cmd ?? raw, src) }
                    r.session.toolCalls += 1
                    for skill in Self.matches(Self.skillPattern, raw) where !r.session.skills.contains(skill) { r.session.skills.append(skill) }
                    if name == "request_user_input" {
                        r.session.questions += 1
                        r.add(.question, time: time, tool: name, source: name, text: raw)
                    }
                case "custom_tool_call_output", "function_call_output":
                    let call = calls[p["call_id"] as? String ?? ""] ?? ((p["name"] as? String) ?? "tool", "", (p["name"] as? String) ?? "tool")
                    guard let failure = Self.failure(p["output"]) else { return true }
                    r.session.toolErrors += 1
                    r.add(.toolError, time: time, tool: call.name, source: call.source, input: call.input, text: failure,
                          retryKey: call.name + "|" + call.input.prefix(300))
                case "message":
                    let role = p["role"] as? String
                    let text = (p["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if role == "assistant", !text.isEmpty { lastAssistantText = text }
                    guard role == "user", !text.isEmpty, !text.hasPrefix("<"), !text.hasPrefix("# AGENTS.md") else { return true }
                    r.session.userMessages += 1
                    if !sawPrompt {
                        sawPrompt = true
                        if r.session.title == nil { r.session.title = text }
                        return true
                    }
                    r.add(.userMessage, time: time, source: "user", text: text, context: lastAssistantText.map { String($0.suffix(400)) })
                default: break
                }
            } else if top == "event_msg" {
                if kind == "token_count" {
                    if let obj = LineScanner.json(line), let info = (obj["payload"] as? [String: Any])?["info"] as? [String: Any],
                       let total = info["total_token_usage"] as? [String: Any] { lastUsage = total }
                } else if kind == "turn_aborted" {
                    guard LineScanner.has(line, "interrupted") else { return true }
                    r.session.interrupts += 1
                    r.add(.interrupt, time: time, source: "user", text: "Turn interrupted by the user", context: lastAssistantText.map { String($0.suffix(400)) })
                } else if kind == "error" || kind == "stream_error" {
                    guard let obj = LineScanner.json(line), let p = obj["payload"] as? [String: Any] else { return true }
                    r.session.apiErrors += 1
                    r.add(.apiError, time: time, source: "model API", text: p["message"] as? String ?? "API error")
                } else if kind == "thread_settings_applied" {
                    if let m = Self.matches(Self.modelPattern, String(decoding: line, as: UTF8.self)).first { r.session.model = m }
                }
            } else if top == "session_meta" {
                if let obj = LineScanner.json(line), let p = obj["payload"] as? [String: Any] { r.session.cwd = p["cwd"] as? String ?? "" }
            } else if top == "turn_context" {
                if r.session.model == nil, let m = Self.matches(Self.modelPattern, String(decoding: line.prefix(4096), as: UTF8.self)).first {
                    r.session.model = m
                }
            }
            if !sawAgents, LineScanner.has(line, "AGENTS.md") {
                let found = Self.matches(Self.agentsPattern, String(decoding: line, as: UTF8.self))
                if !found.isEmpty {
                    sawAgents = true
                    r.session.ruleFiles = Array(NSOrderedSet(array: found)) as? [String] ?? found
                }
            }
            return true
        }
        if let u = lastUsage {
            let input = u["input_tokens"] as? Int ?? 0
            let cached = u["cached_input_tokens"] as? Int ?? 0
            r.session.inputTokens = input - cached
            r.session.cacheReadTokens = cached
            r.session.cacheWriteTokens = u["cache_write_input_tokens"] as? Int ?? 0
            r.session.outputTokens = u["output_tokens"] as? Int ?? 0
        }
        guard !r.times.isEmpty, r.times.max()! >= since else { return nil }
        return r.finish()
    }

    /// The shell command inside an `exec` script or a function-call argument object.
    static func command(_ raw: String) -> String? {
        if raw.hasPrefix("{"), let d = raw.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            if let c = obj["cmd"] as? String { return c }
            if let c = obj["command"] as? String { return c }
            if let c = obj["command"] as? [String] { return c.last.flatMap { c.count >= 3 && c[1] == "-lc" ? $0 : nil } ?? c.joined(separator: " ") }
            return nil
        }
        guard let m = cmdPattern.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let r = Range(m.range(at: 1), in: raw) else { return nil }
        let quoted = String(raw[r])
        if quoted.hasPrefix("\""), let s = try? JSONSerialization.jsonObject(with: Data(quoted.utf8), options: .fragmentsAllowed) as? String {
            return s
        }
        return String(quoted.dropFirst().dropLast())
    }

    /// The error text when a tool output reports a failure, else nil.
    static func failure(_ output: Any?) -> String? {
        var texts: [String] = []
        if let s = output as? String { texts = [s] }
        if let parts = output as? [[String: Any]] { texts = parts.compactMap { $0["text"] as? String } }
        let joined = texts.joined(separator: "\n")
        if joined.hasPrefix("Script failed") {
            return joined.replacingOccurrences(of: #"^Script failed\nWall time [0-9.]+ seconds\nOutput:\n"#, with: "", options: .regularExpression)
        }
        var parsed = false
        for t in texts {
            guard t.hasPrefix("{"), let d = t.data(using: .utf8), let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { continue }
            parsed = true
            let inner = (obj["value"] as? [String: Any]) ?? obj
            if let code = inner["exit_code"] as? Int, code != 0 {
                return "Exit code \(code)\n" + (inner["output"] as? String ?? "")
            }
        }
        if !parsed, let m = exitPattern.firstMatch(in: joined, range: NSRange(joined.startIndex..., in: joined)),
           let r = Range(m.range(at: 1), in: joined), let code = Int(joined[r]), code != 0 {
            return joined
        }
        let body = joined.replacingOccurrences(of: #"^Wall time:? [0-9.]+ seconds\nOutput:\n?"#, with: "", options: .regularExpression)
        if body.hasPrefix("Error") || body.hasPrefix("error:") { return body }
        return nil
    }

    static func matches(_ re: NSRegularExpression, _ s: String) -> [String] {
        re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
    }
}

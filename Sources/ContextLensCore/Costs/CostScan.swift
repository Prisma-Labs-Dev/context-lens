import Foundation

/// One API call as a Claude Code transcript records it: the `usage` of an assistant message.
/// Claude Code writes one line per content block with the same message ID; output tokens grow
/// across those lines, so the call keeps the largest.
public struct CostCall: Codable, Sendable, Hashable {
    public var id: String
    public var time: Date
    public var model: String
    public var input: Int
    public var cacheWrite5m: Int
    public var cacheWrite1h: Int
    public var cacheRead: Int
    /// Includes thinking.
    public var output: Int
    public var thinking: Int
    public var fast: Bool
    public var webSearches: Int
    /// Seconds since the previous call in the same transcript; nil for the first.
    public var gap: Double?
    /// The previous call's context (everything it sent plus what it wrote), what a warm cache
    /// would have served this call.
    public var previousContext: Int?
    /// The line's own session ID differs from the file's: a resumed or forked session that
    /// copied history from another transcript.
    public var copied: Bool = false

    /// Everything the call sent: uncached input, cache writes and cache reads.
    public var context: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    public var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    public init(id: String, time: Date, model: String, input: Int = 0, cacheWrite5m: Int = 0, cacheWrite1h: Int = 0,
                cacheRead: Int = 0, output: Int = 0, thinking: Int = 0, fast: Bool = false, webSearches: Int = 0) {
        self.id = id; self.time = time; self.model = model; self.input = input; self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h; self.cacheRead = cacheRead; self.output = output; self.thinking = thinking
        self.fast = fast; self.webSearches = webSearches
    }

    /// List-price cost in USD, or nil for a model the price table does not know.
    public var cost: Double? {
        guard let p = Pricing.price(model, promptTokens: context, fast: fast) else { return nil }
        return (Double(input) * p.input + Double(cacheWrite5m) * p.cacheWrite5m + Double(cacheWrite1h) * p.cacheWrite1h
            + Double(cacheRead) * p.cacheRead + Double(output) * p.output) / 1_000_000 + Double(webSearches) * Pricing.webSearch
    }
}

/// How a session was started, read from the transcript and the harness's own files.
public enum CostKind: String, Codable, Sendable, CaseIterable {
    /// A subagent transcript (`<session>/subagents/agent-*.jsonl`).
    case subagent
    /// `claude -p` and SDK runs.
    case headless
    /// A background job (`claude --bg`, listed under `~/.claude/jobs`).
    case background
    /// A Claude desktop app thread.
    case desktop
    /// An interactive terminal session.
    case terminal
    /// A Copilot CLI session, priced in AI credits rather than dollars.
    case copilot

    public var label: String {
        switch self {
        case .subagent: "Subagents"
        case .headless: "Headless (claude -p)"
        case .background: "Background jobs"
        case .desktop: "Desktop threads"
        case .terminal: "Terminal sessions"
        case .copilot: "Copilot CLI"
        }
    }

    /// The harness that made the calls, for the harness slice.
    public var harness: String {
        switch self {
        case .subagent: "Subagents"
        case .headless: "Headless (claude -p)"
        case .background: "Background (claude --bg)"
        case .desktop: "Desktop Code tab"
        case .terminal: "Claude Code CLI"
        case .copilot: "Copilot CLI"
        }
    }
}

/// The cost-relevant facts of one transcript.
public struct CostFileScan: Codable, Sendable {
    public var file: String
    /// The top-level session this file belongs to (the parent, for a subagent).
    public var session: String
    public var kind: CostKind
    public var title: String?
    public var cwd: String = ""
    public var entrypoint: String?
    /// Subagent type, such as `Explore`.
    public var agentType: String?
    public var modified: Date
    public var calls: [CostCall] = []
    /// Claude Code's own running total (`cost-state` lines): the last value seen, in USD.
    public var reportedCost: Double?
    /// Copilot: AI credits spent between successive usage checkpoints, so a period counts only
    /// what was spent in it. Its calls carry tokens only.
    public var creditSteps: [CreditStep] = []
    public var copilotModel: String?

    public struct CreditStep: Codable, Sendable, Hashable {
        public var time: Date
        public var credits: Double
        /// The model of the last call before the checkpoint.
        public var model: String?
    }
}

/// Reads token usage from Claude Code and Copilot CLI transcripts. No model calls; per-file
/// results are cached under `~/.context-lens/costs/`, keyed by size and modification time, so a
/// repeat scan only reads transcripts that changed.
public struct CostScanner: Sendable {
    public var env: HarnessEnvironment
    public var cacheFile: URL
    public var copilotHome: URL
    static let cacheVersion = 3

    public init(env: HarnessEnvironment = .current, cacheFile: URL? = nil, copilotHome: URL? = nil) {
        self.env = env
        self.cacheFile = cacheFile ?? env.home.appending(path: ".context-lens/costs/scan-cache.json")
        self.copilotHome = copilotHome ?? env.home.appending(path: ".copilot")
    }

    struct Source {
        var file: URL
        var copilot: Bool
        var size: Int
        var modified: Date
    }

    struct CacheEntry: Codable {
        var size: Int
        var modified: Double
        var scan: CostFileScan?
    }

    struct Cache: Codable {
        var version: Int
        var files: [String: CacheEntry]
    }

    /// Transcripts modified since `since` (all when nil). A transcript written before the window
    /// has no calls in it.
    public func scan(since: Date? = nil) -> [CostFileScan] {
        let sources = files(since: since)
        var cache = loadCache()
        var results = [CostFileScan?](repeating: nil, count: sources.count)
        var todo: [Int] = []
        for (i, s) in sources.enumerated() {
            if let hit = cache.files[s.file.path], hit.size == s.size, hit.modified == s.modified.timeIntervalSince1970 {
                results[i] = hit.scan
            } else {
                todo.append(i)
            }
        }
        let parsed = UnsafeMutableBufferPointer<CostFileScan?>.allocate(capacity: todo.count)
        parsed.initialize(repeating: nil)
        defer { parsed.deinitialize(); parsed.deallocate() }
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
            cache.files = cache.files.filter { FileManager.default.fileExists(atPath: $0.key) }
            saveCache(cache)
        }
        return results.compactMap { $0 }
    }

    func parse(_ s: Source) -> CostFileScan? {
        s.copilot ? CopilotCostParser(file: s.file, modified: s.modified).parse()
            : ClaudeCostParser(file: s.file, modified: s.modified, jobs: env.claudeHome.appending(path: "jobs")).parse()
    }

    func files(since: Date?) -> [Source] {
        var out: [Source] = []
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        func walk(_ root: URL, copilot: Bool, match: (URL) -> Bool) {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return }
            for case let url as URL in e where url.pathExtension == "jsonl" && match(url) {
                guard let v = try? url.resourceValues(forKeys: keys), let size = v.fileSize, size > 0 else { continue }
                let modified = v.contentModificationDate ?? .distantPast
                if let since, modified < since { continue }
                out.append(Source(file: url, copilot: copilot, size: size, modified: modified))
            }
        }
        walk(env.claudeHome.appending(path: "projects"), copilot: false) { _ in true }
        walk(copilotHome.appending(path: "session-state"), copilot: true) { $0.lastPathComponent == "events.jsonl" }
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

struct ClaudeCostParser {
    let file: URL
    let modified: Date
    /// `~/.claude/jobs`: a folder named after the first 8 characters of a session ID marks a
    /// background job.
    let jobs: URL

    func parse() -> CostFileScan? {
        guard let scanner = LineScanner(file) else { return nil }
        let subagent = file.path.contains("/subagents/")
        let stem = file.deletingPathExtension().lastPathComponent
        let sessionDir = file.deletingLastPathComponent().deletingLastPathComponent()
        let session = subagent ? sessionDir.lastPathComponent : stem
        var out = CostFileScan(file: file.path, session: session, kind: subagent ? .subagent : .terminal, modified: modified)
        if subagent,
           let data = try? Data(contentsOf: file.deletingPathExtension().appendingPathExtension("meta.json")),
           let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            out.agentType = meta["agentType"] as? String
            out.title = meta["description"] as? String
        }
        var index: [String: Int] = [:]
        var calls: [CostCall] = []
        var customTitle: String?, aiTitle: String?, agentName: String?

        scanner.forEach { line in
            if LineScanner.has(line, "\"type\":\"assistant\""), LineScanner.has(line, "\"usage\""),
               let obj = LineScanner.json(line), obj["type"] as? String == "assistant",
               let message = obj["message"] as? [String: Any], let usage = message["usage"] as? [String: Any] {
                if out.cwd.isEmpty, let cwd = obj["cwd"] as? String { out.cwd = cwd }
                if out.entrypoint == nil { out.entrypoint = obj["entrypoint"] as? String }
                // Sidechain lines in a main transcript are old-style subagents; they have their own file now.
                if !subagent, obj["isSidechain"] as? Bool == true { return true }
                guard let model = message["model"] as? String, model != "<synthetic>",
                      let time = LineScanner.timestamp(line) else { return true }
                let id = message["id"] as? String ?? obj["requestId"] as? String ?? obj["uuid"] as? String ?? UUID().uuidString
                let creation = usage["cache_creation"] as? [String: Any]
                let written = Self.int(usage["cache_creation_input_tokens"])
                var w1h = Self.int(creation?["ephemeral_1h_input_tokens"])
                var w5m = Self.int(creation?["ephemeral_5m_input_tokens"])
                // Without the TTL split, Claude Code's default 5-minute TTL is the safe reading.
                if creation == nil || w1h + w5m != written { w5m = max(0, written - w1h); w1h = min(w1h, written) }
                var call = CostCall(
                    id: id, time: time, model: model,
                    input: Self.int(usage["input_tokens"]), cacheWrite5m: w5m, cacheWrite1h: w1h,
                    cacheRead: Self.int(usage["cache_read_input_tokens"]), output: Self.int(usage["output_tokens"]),
                    thinking: Self.int((usage["output_tokens_details"] as? [String: Any])?["thinking_tokens"]),
                    fast: usage["speed"] as? String == "fast",
                    webSearches: Self.int((usage["server_tool_use"] as? [String: Any])?["web_search_requests"]))
                if !subagent, let sid = obj["sessionId"] as? String, sid != stem { call.copied = true }
                if let i = index[id] {
                    calls[i].output = max(calls[i].output, call.output)
                    calls[i].thinking = max(calls[i].thinking, call.thinking)
                } else {
                    index[id] = calls.count
                    calls.append(call)
                }
            } else if LineScanner.has(line, "\"type\":\"cost-state\""), let obj = LineScanner.json(line),
                      let total = obj["totalCostUSD"] as? Double {
                out.reportedCost = total
            } else if LineScanner.has(line, "\"customTitle\""), let obj = LineScanner.json(line), let t = obj["customTitle"] as? String {
                customTitle = t
            } else if LineScanner.has(line, "\"aiTitle\""), let obj = LineScanner.json(line), let t = obj["aiTitle"] as? String {
                aiTitle = t
            } else if LineScanner.has(line, "\"agentName\""), let obj = LineScanner.json(line), let t = obj["agentName"] as? String {
                agentName = t
            } else if out.entrypoint == nil, LineScanner.has(line, "\"entrypoint\":\""), let obj = LineScanner.json(line) {
                out.entrypoint = obj["entrypoint"] as? String
                if out.cwd.isEmpty, let cwd = obj["cwd"] as? String { out.cwd = cwd }
            }
            return true
        }
        guard !calls.isEmpty || out.reportedCost != nil else { return nil }
        calls.sort { $0.time < $1.time }
        for i in calls.indices.dropFirst() {
            calls[i].gap = calls[i].time.timeIntervalSince(calls[i - 1].time)
            calls[i].previousContext = calls[i - 1].context + calls[i - 1].output
        }
        out.calls = calls
        if !subagent {
            // A sidecar written by the desktop app wins over titles in the transcript.
            let sidecar = file.deletingPathExtension().appending(path: "custom-title.json")
            if let data = try? Data(contentsOf: sidecar), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let t = obj["customTitle"] as? String { customTitle = t }
            out.title = customTitle ?? agentName ?? aiTitle
            out.kind = Self.kind(entrypoint: out.entrypoint, background: FileUtil.exists(jobs.appending(path: String(stem.prefix(8)))))
        }
        return out
    }

    static func kind(entrypoint: String?, background: Bool) -> CostKind {
        if background { return .background }
        let e = entrypoint ?? ""
        if e.hasPrefix("sdk") || e == "headless" { return .headless }
        if e.hasPrefix("claude-desktop") || e.hasPrefix("desktop") { return .desktop }
        return .terminal
    }

    static func int(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }
}

/// Copilot CLI `session-state/<id>/events.jsonl`: `totalNanoAiu` / 1e9 in a usage checkpoint is
/// the running "AI Credits" figure the CLI prints at exit; tokens come from usage records.
struct CopilotCostParser {
    let file: URL
    let modified: Date

    func parse() -> CostFileScan? {
        guard let scanner = LineScanner(file) else { return nil }
        let session = file.deletingLastPathComponent().lastPathComponent
        var out = CostFileScan(file: file.path, session: "copilot:" + session, kind: .copilot, modified: modified)
        var spent = 0.0
        var lastModel: String?
        scanner.forEach { line in
            let time = LineScanner.timestamp(line) ?? modified
            if LineScanner.has(line, "\"session.start\""), let obj = LineScanner.json(line), let d = obj["data"] as? [String: Any] {
                out.copilotModel = d["selectedModel"] as? String
                if let c = (d["context"] as? [String: Any])?["cwd"] as? String { out.cwd = c }
            } else if LineScanner.has(line, "\"session.usage_record\""), let obj = LineScanner.json(line),
                      let u = (obj["data"] as? [String: Any])?["usage"] as? [String: Any] {
                let model = u["model"] as? String ?? out.copilotModel ?? "copilot"
                if out.copilotModel == nil { out.copilotModel = model }
                lastModel = model
                out.calls.append(CostCall(
                    id: "\(out.session):\(out.calls.count)", time: time, model: model,
                    input: ClaudeCostParser.int(u["inputTokens"]), cacheWrite5m: ClaudeCostParser.int(u["cacheWriteTokens"]),
                    cacheRead: ClaudeCostParser.int(u["cacheReadTokens"]), output: ClaudeCostParser.int(u["outputTokens"]),
                    thinking: ClaudeCostParser.int(u["reasoningTokens"])))
            } else if LineScanner.has(line, "\"totalNanoAiu\""), let obj = LineScanner.json(line), let d = obj["data"] as? [String: Any] {
                let value = d["totalNanoAiu"] ?? (d["accountingSnapshot"] as? [String: Any])?["totalNanoAiu"]
                // The total is cumulative; a step is what it grew by since the last checkpoint.
                if let n = (value as? NSNumber)?.doubleValue, n / 1e9 > spent {
                    out.creditSteps.append(.init(time: time, credits: n / 1e9 - spent, model: lastModel ?? out.copilotModel))
                    spent = n / 1e9
                }
            } else if out.title == nil, LineScanner.has(line, "\"user.message\""), let obj = LineScanner.json(line),
                      let text = (obj["data"] as? [String: Any])?["content"] as? String {
                out.title = String(text.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?.prefix(80) ?? "")
            }
            return true
        }
        return out.creditSteps.isEmpty ? nil : out
    }
}

import Foundation

/// How a Claude Code session's context grew, one model call at a time.
///
/// Every assistant entry records the API usage of its call, so the context size of a call is
/// `input_tokens + cache_read_input_tokens + cache_creation_input_tokens`. A call that returns
/// several content blocks writes one entry per block with the same message id; those count once.
/// The text that entered the context between two calls (tool results, skill bodies, command text,
/// the user's messages) is estimated at 4 characters per token, to say what caused a jump.
public struct ContextGrowth: Codable, Hashable, Sendable {
    public struct Source: Codable, Hashable, Sendable {
        /// "Read GUIDE.md", "Skill deploy", "/review", "Your message", "Model output".
        public var label: String
        /// Estimated from the text length.
        public var tokens: Int
    }

    public struct Call: Codable, Hashable, Sendable, Identifiable {
        /// 1-based, in transcript order.
        public var index: Int
        public var id: String { "call|\(index)" }
        /// Context size the API reported for this call.
        public var tokens: Int
        public var output: Int
        public var time: Date?
        /// Change from the previous call; negative after a compaction.
        public var delta: Int
        /// What entered the context since the previous call, largest first.
        public var added: [Source]

        /// The largest addition, the likely cause of the jump.
        public var cause: Source? { added.first }
    }

    public struct Compaction: Codable, Hashable, Sendable {
        /// Number of calls before the compaction.
        public var afterCall: Int
        public var trigger: String
        public var preTokens: Int
        public var postTokens: Int
        public var time: Date?
    }

    /// How the session ran: `cli`, `claude-desktop`, `sdk-ts` and so on. Desktop adds its own tools.
    public var entrypoint: String?
    public var model: String?
    public var calls: [Call]
    public var compactions: [Compaction]
    /// Estimated tokens of the user's first message and the command text it expanded to: part of
    /// the first call, but not of the context a session starts with.
    public var firstMessageTokens: Int
    /// What the harness added to the first call that the context tree doesn't list as an item:
    /// hook output, the model and date lines, permission-mode guidance and so on. Estimated.
    public var firstTurnReminders: [Source] = []
    /// How the first call's input split: read from the prompt cache (a prefix an earlier
    /// session with the same setup already sent) and newly written.
    public var firstCallCacheRead: Int?
    public var firstCallCacheWritten: Int?

    public var firstCall: Int? { calls.first?.tokens }
    public var peak: Int { calls.map(\.tokens).max() ?? 0 }
    public var last: Int? { calls.last?.tokens }

    /// The calls whose context grew most, biggest first.
    public func topJumps(_ n: Int = 5) -> [Call] {
        Array(calls.filter { $0.delta > 0 && $0.index > 1 }.sorted { ($0.delta, -$0.index) > ($1.delta, -$1.index) }.prefix(n))
    }

    /// What the first call held that no transcript entry shows: tool definitions, the harness
    /// system prompt, MCP tool schemas. `estimated` is what the transcript does show before the
    /// first message.
    public func hiddenTokens(estimated: Int) -> Int? {
        firstCall.map { max(0, $0 - estimated - firstMessageTokens) }
    }
}

public struct ContextGrowthReader: Sendable {
    public init() {}

    /// Reads the main thread of a Claude Code transcript. Subagent calls run in their own context
    /// and are left out. Nil when the transcript records no usage.
    public func read(_ file: URL) -> ContextGrowth? {
        var calls: [ContextGrowth.Call] = []
        var compactions: [ContextGrowth.Compaction] = []
        var seen = Set<String>()
        var toolLabels: [String: String] = [:]
        var pending: [String: Int] = [:]
        var order: [String] = []
        var entrypoint: String?, model: String?
        var firstMessage = 0
        var lastCommand: String?
        var sawPrompt = false, sawInstructions = false
        var reminders: [String: Int] = [:]
        var cacheRead: Int?, cacheWritten: Int?

        func add(_ label: String, chars: Int, user: Bool = false) {
            guard chars > 0 else { return }
            if user, calls.isEmpty { firstMessage += chars }
            if pending[label] == nil { order.append(label) }
            pending[label, default: 0] += chars
        }

        JSONLines.forEachLine(in: file, containing: ["\"type\":\"assistant\"", "\"type\":\"user\"", "\"type\":\"attachment\"", "\"compact_boundary\""]) { obj in
            if obj["isSidechain"] as? Bool == true { return }
            let time = (obj["timestamp"] as? String).flatMap(HealthText.date)
            switch obj["type"] as? String {
            case "assistant":
                guard let m = obj["message"] as? [String: Any] else { return }
                let parts = m["content"] as? [[String: Any]] ?? []
                for p in parts where p["type"] as? String == "tool_use" {
                    if let id = p["id"] as? String { toolLabels[id] = Self.label(tool: p["name"] as? String ?? "Tool", input: p["input"] as? [String: Any] ?? [:]) }
                }
                if let id = m["id"] as? String, let u = m["usage"] as? [String: Any], seen.insert(id).inserted {
                    let tokens = Self.int(u["input_tokens"]) + Self.int(u["cache_read_input_tokens"]) + Self.int(u["cache_creation_input_tokens"])
                    if calls.isEmpty {
                        entrypoint = obj["entrypoint"] as? String
                        model = m["model"] as? String
                        cacheRead = Self.int(u["cache_read_input_tokens"])
                        cacheWritten = Self.int(u["cache_creation_input_tokens"]) + Self.int(u["input_tokens"])
                    }
                    let added = order.map { ContextGrowth.Source(label: $0, tokens: TokenEstimate.tokens(chars: pending[$0]!)) }
                        .filter { $0.tokens > 0 }
                        .sorted { ($0.tokens, $1.label) > ($1.tokens, $0.label) }
                    calls.append(ContextGrowth.Call(index: calls.count + 1, tokens: tokens, output: Self.int(u["output_tokens"]), time: time,
                                                    delta: calls.last.map { tokens - $0.tokens } ?? 0, added: added))
                    pending = [:]
                    order = []
                }
                // What the model wrote is part of the next call's context. Thinking is not resent.
                add("Model output", chars: parts.reduce(0) { n, p in
                    switch p["type"] as? String {
                    case "text": n + (p["text"] as? String ?? "").utf8.count
                    case "tool_use": n + Self.length(p["input"])
                    default: n
                    }
                })
            case "user":
                guard let m = obj["message"] as? [String: Any] else { return }
                let meta = obj["isMeta"] as? Bool == true
                if let text = m["content"] as? String {
                    if let name = Self.between(text, "<command-name>", "</command-name>") {
                        lastCommand = name.hasPrefix("/") ? name : "/" + name
                        add(lastCommand!, chars: text.utf8.count, user: true)
                    } else {
                        add(meta ? lastCommand ?? "Harness" : "Your message", chars: text.utf8.count, user: true)
                        if !meta { lastCommand = nil }
                    }
                    return
                }
                for p in m["content"] as? [[String: Any]] ?? [] {
                    switch p["type"] as? String {
                    case "tool_result":
                        let id = p["tool_use_id"] as? String ?? ""
                        add(toolLabels[id] ?? "Tool result", chars: Self.length(p["content"]))
                    case "text":
                        let chars = (p["text"] as? String ?? "").utf8.count
                        if let source = obj["sourceToolUseID"] as? String, let label = toolLabels[source] {
                            add(label, chars: chars)
                        } else {
                            add(meta ? lastCommand ?? "Harness" : "Your message", chars: chars, user: true)
                        }
                    case "image":
                        add("Image", chars: 6000)
                    default:
                        break
                    }
                }
            case "attachment":
                // What the harness injects. The system prompt and instruction files are recorded
                // again when they change; only the first copy adds to the context.
                guard let a = obj["attachment"] as? [String: Any], let type = a["type"] as? String else { return }
                if calls.isEmpty, let r = Self.reminderLabel(type) {
                    reminders[r, default: 0] += Self.textLength(a)
                }
                let label: String
                switch type {
                case "prompt_snapshot":
                    guard !sawPrompt else { return }
                    sawPrompt = true
                    label = "System prompt"
                case "instructions":
                    guard !sawInstructions else { return }
                    sawInstructions = true
                    label = "Instruction files"
                case "skill_listing": label = "Skill listing"
                case "mcp_instructions_delta": label = "MCP server instructions"
                case "deferred_tools_delta": label = "Deferred tool list"
                case "agent_listing_delta": label = "Subagent listing"
                case "invoked_skills": label = "Skill bodies"
                case "nested_memory":
                    let path = (a["content"] as? [String: Any])?["path"] as? String
                    label = path.map { "Memory " + URL(filePath: $0).lastPathComponent } ?? "Memory"
                default: label = "Harness"
                }
                add(label, chars: Self.length(a))
            case "system":
                guard obj["subtype"] as? String == "compact_boundary" else { return }
                let meta = obj["compactMetadata"] as? [String: Any] ?? [:]
                compactions.append(ContextGrowth.Compaction(afterCall: calls.count, trigger: meta["trigger"] as? String ?? "auto",
                                                            preTokens: Self.int(meta["preTokens"]), postTokens: Self.int(meta["postTokens"]), time: time))
            default:
                break
            }
        }
        guard !calls.isEmpty else { return nil }
        return ContextGrowth(entrypoint: entrypoint, model: model, calls: calls, compactions: compactions,
                             firstMessageTokens: TokenEstimate.tokens(chars: firstMessage),
                             firstTurnReminders: reminders.map { ContextGrowth.Source(label: $0.key, tokens: TokenEstimate.tokens(chars: $0.value)) }
                                 .filter { $0.tokens > 0 }.sorted { ($0.tokens, $1.label) > ($1.tokens, $0.label) },
                             firstCallCacheRead: cacheRead, firstCallCacheWritten: cacheWritten)
    }

    /// Attachment types the session parser lists as context items; the rest of what the harness
    /// adds before the first call is a reminder. Hook output is listed, but as loaded on demand.
    static let listedTypes: Set<String> = [
        "instructions", "nested_memory", "prompt_snapshot", "skill_listing", "invoked_skills", "mcp_instructions_delta",
        "agent_listing_delta", "deferred_tools_delta", "context_sections", "session_context", "environment",
    ]

    static func reminderLabel(_ type: String) -> String? {
        guard !listedTypes.contains(type) else { return nil }
        switch type {
        case let t where t.hasPrefix("hook"): return "Hook output"
        case "model": return "Model identity"
        case "date": return "Date"
        case "auto_mode", "plan_mode", "permission_mode": return "Permission mode guidance"
        case "total_tokens_reminder", "token_usage", "budget_usd": return "Token budget reminder"
        case "remote_session_change": return "Session links"
        case "todo_reminder", "task_status": return "Task reminders"
        default: return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Characters of the text in an attachment: string values, not keys or the type.
    static func textLength(_ value: Any?, key: String? = nil) -> Int {
        switch value {
        case let s as String: return key == "type" ? 0 : s.utf8.count
        case let d as [String: Any]: return d.reduce(0) { $0 + textLength($1.value, key: $1.key) }
        case let a as [Any]: return a.reduce(0) { $0 + textLength($1) }
        default: return 0
        }
    }

    /// "Read GUIDE.md", "Bash: run the tests", "Skill deploy", "Agent: find callers", "garden water_plants".
    static func label(tool: String, input: [String: Any]) -> String {
        func clip(_ s: String) -> String {
            let line = s.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return line.count > 60 ? String(line.prefix(60)) + "…" : line
        }
        func file(_ key: String) -> String? { (input[key] as? String).map { URL(filePath: $0).lastPathComponent } }
        switch tool {
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return file("file_path").map { "\(tool) \($0)" } ?? file("notebook_path").map { "\(tool) \($0)" } ?? tool
        case "Bash":
            if let d = input["description"] as? String { return "Bash: " + clip(d) }
            guard var command = input["command"] as? String else { return tool }
            // `cd <folder> && make test` says nothing until after the cd.
            while command.hasPrefix("cd "), let r = command.range(of: #"^cd +("[^"]*"|'[^']*'|\S+) *(&&|;) *"#, options: .regularExpression) {
                command.removeSubrange(r)
            }
            return "Bash: " + clip(command)
        case "Grep", "Glob":
            return (input["pattern"] as? String).map { "\(tool) " + clip($0) } ?? tool
        case "Skill":
            return (input["skill"] as? String).map { "Skill \($0)" } ?? tool
        case "Agent", "Task":
            return (input["description"] as? String).map { "Agent: " + clip($0) } ?? "Agent"
        case "WebFetch":
            return (input["url"] as? String).flatMap { URL(string: $0)?.host() }.map { "WebFetch \($0)" } ?? tool
        case "WebSearch":
            return (input["query"] as? String).map { "WebSearch " + clip($0) } ?? tool
        default:
            // mcp__server__tool
            let parts = tool.components(separatedBy: "__")
            if parts.count >= 3, parts[0] == "mcp" { return "\(parts[1]) \(parts[2...].joined(separator: "__"))" }
            return tool
        }
    }

    static func between(_ s: String, _ open: String, _ close: String) -> String? {
        guard let a = s.range(of: open), let b = s.range(of: close, range: a.upperBound..<s.endIndex) else { return nil }
        return String(s[a.upperBound..<b.lowerBound]).trimmingCharacters(in: .whitespaces)
    }

    /// Text length of a tool result or tool input: strings as they are, structures as JSON.
    static func length(_ value: Any?) -> Int {
        switch value {
        case let s as String: return s.utf8.count
        case let parts as [[String: Any]]:
            return parts.reduce(0) { n, p in
                if let t = p["text"] as? String { return n + t.utf8.count }
                if p["type"] as? String == "image" { return n + 6000 }
                return n + length(p)
            }
        case let v? where JSONSerialization.isValidJSONObject(v):
            return (try? JSONSerialization.data(withJSONObject: v))?.count ?? 0
        default: return 0
        }
    }

    static func int(_ v: Any?) -> Int { (v as? Int) ?? (v as? NSNumber)?.intValue ?? 0 }

}

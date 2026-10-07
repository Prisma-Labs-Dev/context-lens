import Foundation

/// Reads the context a Claude Code session recorded in its transcript.
///
/// Claude Code 2.1.2xx writes `attachment` entries for what it injects: `instructions` (CLAUDE.md,
/// AGENTS.md, auto memory), `prompt_snapshot` (system prompt), `skill_listing`, `nested_memory`,
/// `mcp_instructions_delta`, `agent_listing_delta`, `invoked_skills`, `session_context` and more.
public struct ClaudeSessionParser: Sendable {
    public var env: HarnessEnvironment

    public init(env: HarnessEnvironment = .current) {
        self.env = env
    }

    public func parse(_ session: SessionSummary) -> ContextSnapshot {
        var items: [ContextItem] = []
        var seen = Set<String>()
        var gotInstructions = false, gotPrompt = false, gotSkills = false
        var promptVersions = 0

        func add(_ item: ContextItem) {
            guard seen.insert(item.id).inserted else { return }
            items.append(item)
        }

        let liveSkills = Dictionary(
            ClaudeResolver(env: env).skills(cwd: URL(filePath: session.cwd), git: Git.roots(for: URL(filePath: session.cwd)))
                .map { ($0.title, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var origin: String?
        JSONLines.forEachLine(in: session.file, containing: ["\"type\":\"attachment\""]) { obj in
            if origin == nil, let version = obj["version"] as? String {
                origin = "Claude Code \(version) via \(obj["entrypoint"] as? String ?? "unknown entrypoint")."
            }
            guard let a = obj["attachment"] as? [String: Any], let type = a["type"] as? String else { return }
            switch type {
            case "instructions" where !gotInstructions:
                gotInstructions = true
                for f in a["files"] as? [[String: Any]] ?? [] {
                    let path = f["path"] as? String ?? ""
                    let scope = f["type"] as? String ?? "Project"
                    let kind: ContextKind = scope == "AutoMem" ? .memory : (path.contains("/.claude/rules/") ? .rule : .instructions)
                    var item = recorded(kind: kind, scope: scope == "AutoMem" ? "Auto memory" : scope, path: path,
                                        content: f["content"] as? String ?? "", load: .always)
                    if kind == .memory { item.title = URL(filePath: path).lastPathComponent }
                    if let r = path.range(of: "/.context-lens/generated/") {
                        // Instructions a Context Lens preset added; the path names the preset.
                        let presetID = path[r.upperBound...].split(separator: "/").first.map(String.init) ?? "preset"
                        item.title = "\(presetID) preset instructions"
                        item.scope = "Preset"
                        item.diskStatus = nil
                    }
                    add(item)
                }
            case "nested_memory":
                guard let c = a["content"] as? [String: Any], let path = c["path"] as? String else { return }
                var item = recorded(kind: .onDemand, scope: c["type"] as? String ?? "Project", path: path,
                                    content: c["content"] as? String ?? "", load: .onDemand)
                item.note = "Loaded during the session when matching files were touched."
                add(item)
            case "prompt_snapshot":
                promptVersions += 1
                guard !gotPrompt else { return }
                gotPrompt = true
                for (i, part) in (a["systemPrompt"] as? [String] ?? []).enumerated() where !part.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    add(ContextItem(id: "prompt|\(i)", kind: .systemPrompt, title: Self.heading(part, fallback: "Part \(i + 1)"),
                                    scope: "Harness", content: part, load: .always))
                }
            case "skill_listing" where !gotSkills:
                gotSkills = true
                for line in Self.listingEntries(a["content"] as? String ?? "") {
                    let name = Self.listingName(line)
                    var item = ContextItem(id: "skill|\(name)", kind: .skill, title: name, scope: "Listed", content: line, load: .listing)
                    if let live = liveSkills[name] {
                        item.path = live.path
                        item.scope = live.scope
                        item.modified = live.modified
                    }
                    add(item)
                }
            case "invoked_skills":
                for s in a["skills"] as? [[String: Any]] ?? [] {
                    let name = s["name"] as? String ?? "skill"
                    var item = ContextItem(id: "invoked|\(name)", kind: .skill, title: "\(name) (invoked)", scope: "Invoked",
                                           path: liveSkills[name]?.path, content: s["content"] as? String ?? "", load: .onDemand)
                    item.note = "Full skill body loaded when the skill ran."
                    add(item)
                }
            case "mcp_instructions_delta":
                let names = a["addedNames"] as? [String] ?? []
                for (i, block) in (a["addedBlocks"] as? [String] ?? []).enumerated() {
                    let name = i < names.count ? names[i] : Self.heading(block, fallback: "MCP server")
                    var item = ContextItem(id: "mcp|\(name)", kind: .mcp, title: name, scope: "Server instructions", content: block, load: .always)
                    item.note = "Instructions only. The server's tool schemas are sent with the tool definitions, which the transcript does not record."
                    add(item)
                }
            case "agent_listing_delta":
                let lines = (a["addedLines"] as? [String] ?? []).joined(separator: "\n")
                add(ContextItem(id: "agents", kind: .agent, title: "Subagent listing", scope: "Harness", content: lines, load: .listing))
            case "deferred_tools_delta":
                let names = a["addedNames"] as? [String] ?? []
                add(ContextItem(id: "deferred", kind: .environment, title: "Deferred tools (\(names.count))", scope: "Harness",
                                content: names.joined(separator: "\n"), load: .listing,
                                note: "Tool names listed in the context; schemas load on demand."))
            case "context_sections":
                for s in a["sections"] as? [[String: Any]] ?? [] {
                    let name = s["name"] as? String ?? "Section"
                    add(ContextItem(id: "section|\(name)", kind: name == "Memory" ? .memory : .environment, title: "\(name) instructions",
                                    scope: "Harness", content: s["text"] as? String ?? "", load: .always))
                }
            case "session_context":
                let ctx = a["context"] as? [String: String] ?? [:]
                for (k, v) in ctx.sorted(by: { $0.key < $1.key }) {
                    add(ContextItem(id: "ctx|\(k)", kind: .environment, title: k, scope: "Session", content: v, load: .always))
                }
            case "environment":
                if let snap = a["snapshot"] {
                    add(ContextItem(id: "env", kind: .environment, title: "Environment", scope: "Session", content: Self.pretty(snap), load: .always))
                }
            case "hook_additional_context":
                let name = a["hookName"] as? String ?? "Hook"
                let content = (a["content"] as? [String] ?? []).joined(separator: "\n")
                add(ContextItem(id: "hook|\(name)|\(content.hashValue)", kind: .hook, title: name, scope: "Hook output", content: content, load: .onDemand))
            default:
                break
            }
        }

        var notes: [String] = []
        if let origin {
            notes.append(origin.contains("sdk") ? origin + " Agent SDK runs can limit which settings sources load, so they may skip files an interactive session would load." : origin)
        }
        if items.isEmpty {
            notes.append("This transcript has no context snapshot. Claude Code started recording injected context in its transcripts around version 2.1.2xx.")
        }
        if promptVersions > 1 {
            notes.append("The system prompt was re-sent \(promptVersions) times; showing the first.")
        }
        return ContextSnapshot(harness: .claude, cwd: session.cwd, items: Unique.ids(items), notes: notes)
    }

    func recorded(kind: ContextKind, scope: String, path: String, content: String, load: LoadMode) -> ContextItem {
        var item = ContextItem(kind: kind, title: FileUtil.abbreviate(path, home: env.home), scope: scope, path: path,
                               content: content, load: load, issues: ReferenceChecker.issues(for: content, home: env.home))
        DiskCompare.apply(to: &item)
        return item
    }

    static func listingEntries(_ text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("- ") { out.append(line) } else if !out.isEmpty, !line.isEmpty { out[out.count - 1] += "\n" + line }
        }
        return out
    }

    /// `- plugin:skill-name: description` -> `plugin:skill-name`. Names can contain colons, so
    /// split at the first colon followed by a space.
    static func listingName(_ line: String) -> String {
        let body = String(line.dropFirst(2).prefix { $0 != "\n" })
        if let r = body.range(of: ": ") { return String(body[..<r.lowerBound]) }
        return body.hasSuffix(":") ? String(body.dropLast()) : body
    }

    static func heading(_ text: String, fallback: String) -> String {
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { return t.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }
            if t.hasPrefix("<"), let close = t.firstIndex(of: ">") {
                return String(t[t.index(after: t.startIndex)..<close])
            }
            if !t.isEmpty { return t.count > 60 ? String(t.prefix(60)) + "…" : t }
        }
        return fallback
    }

    static func pretty(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return "\(value)"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Reads the context a Codex session recorded in its rollout file.
///
/// Rollouts store `session_meta.base_instructions`, developer messages (memory, skills,
/// permissions, collaboration mode), and a user message `# AGENTS.md instructions for <cwd>`
/// with the global file between `BEGIN/END GLOBAL AGENTS.md` markers and the project docs after
/// `--- project-doc ---`.
public struct CodexSessionParser: Sendable {
    public var env: HarnessEnvironment

    public init(env: HarnessEnvironment = .current) {
        self.env = env
    }

    public func parse(_ session: SessionSummary) -> ContextSnapshot {
        var items: [ContextItem] = []
        var seenText = Set<Int>()
        var resent: [String: Int] = [:]
        var notes: [String] = []

        JSONLines.forEachLine(in: session.file, containing: ["\"type\":\"session_meta\"", "\"role\":\"developer\"", "\"role\":\"user\"", "\"type\":\"turn_context\""]) { obj in
            let type = obj["type"] as? String
            guard let p = obj["payload"] as? [String: Any] else { return }
            if type == "session_meta" {
                if let base = (p["base_instructions"] as? [String: Any])?["text"] as? String, seenText.insert(base.hashValue).inserted {
                    items.append(ContextItem(id: "base", kind: .systemPrompt, title: "Base instructions", scope: "Harness", content: base, load: .always))
                }
                if let v = p["cli_version"] as? String { notes.append("codex-cli \(v), \(p["originator"] as? String ?? "")") }
                return
            }
            if type == "turn_context" {
                if !items.contains(where: { $0.id == "turn" }) {
                    var ctx = p
                    ctx.removeValue(forKey: "user_instructions")
                    ctx.removeValue(forKey: "developer_instructions")
                    items.append(ContextItem(id: "turn", kind: .environment, title: "Turn settings", scope: "Session",
                                             content: ClaudeSessionParser.pretty(ctx), load: .always,
                                             note: "Model, sandbox and approval settings of the first turn."))
                }
                return
            }
            guard type == "response_item", p["type"] as? String == "message", let role = p["role"] as? String else { return }
            for part in p["content"] as? [[String: Any]] ?? [] {
                guard let text = part["text"] as? String, seenText.insert(text.hashValue).inserted else { continue }
                // Long sessions re-send these blocks every turn or after compaction. Keep the first
                // copy of each kind and count the rest.
                let block = Self.blockKind(text, role: role)
                if let block {
                    resent[block, default: 0] += 1
                    if resent[block]! > 1 { continue }
                }
                if role == "developer" {
                    items += developerItems(text)
                } else if text.hasPrefix("# AGENTS.md instructions") {
                    items += agentsItems(text, cwd: session.cwd)
                } else if text.hasPrefix("<environment_context>"), !items.contains(where: { $0.id == "envctx" }) {
                    items.append(ContextItem(id: "envctx", kind: .environment, title: "Environment context", scope: "Session", content: text, load: .always))
                }
            }
        }
        if !items.contains(where: { $0.kind == .instructions }) {
            notes.append("No AGENTS.md instructions were recorded for this session.")
        }
        for (block, count) in resent.sorted(by: { $0.key < $1.key }) where count > 1 {
            notes.append("\(block) was sent \(count) times with different text; showing the first.")
        }
        return ContextSnapshot(harness: .codex, cwd: session.cwd, items: Unique.ids(items), notes: notes)
    }

    static func blockKind(_ text: String, role: String) -> String? {
        if text.hasPrefix("# AGENTS.md instructions") { return "AGENTS.md instructions" }
        if text.hasPrefix("<environment_context>") { return "Environment context" }
        guard role == "developer" else { return nil }
        if text.hasPrefix("<skills_instructions>") { return "Skill instructions" }
        if text.hasPrefix("## Memory") { return "Memory instructions" }
        if text.hasPrefix("<"), let close = text.firstIndex(of: ">") { return String(text[..<close]) + ">" }
        return nil
    }

    func developerItems(_ text: String) -> [ContextItem] {
        if text.hasPrefix("<skills_instructions>") {
            return skillItems(text)
        }
        if text.hasPrefix("## Memory") {
            return [ContextItem(id: "dev|memory", kind: .memory, title: "Memory instructions and summary", scope: "Memories", content: text, load: .always)]
        }
        let title = ClaudeSessionParser.heading(text, fallback: "Developer message")
        let isTurnNotice = text.hasPrefix("<turn_aborted>")
        if isTurnNotice { return [] }
        return [ContextItem(id: "dev|\(title)|\(text.hashValue)", kind: .environment, title: title, scope: "Developer message", content: text, load: .always)]
    }

    func skillItems(_ text: String) -> [ContextItem] {
        var roots: [String: String] = [:]
        let rootRegex = try! NSRegularExpression(pattern: #"^- `(r\d+)` = `([^`]+)`"#, options: .anchorsMatchLines)
        let ns = text as NSString
        for m in rootRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            roots[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        let preamble = text.components(separatedBy: "\n").filter { !($0.hasPrefix("- ") && !$0.hasPrefix("- `r")) }.joined(separator: "\n")
        var out = [ContextItem(id: "skills|header", kind: .skill, title: "Skill instructions", scope: "Harness",
                               content: preamble, load: .always, note: "The developer message around the skill list. Each listed skill is its own item below.")]
        let fileRegex = try! NSRegularExpression(pattern: #"\(file: (r\d+)/([^)]+)\)\s*$"#)
        for line in text.components(separatedBy: "\n") where line.hasPrefix("- ") && !line.hasPrefix("- `r") {
            let name = ClaudeSessionParser.listingName(line)
            var path: String?
            let lns = line as NSString
            if let m = fileRegex.firstMatch(in: line, range: NSRange(location: 0, length: lns.length)),
               let root = roots[lns.substring(with: m.range(at: 1))] {
                path = root + "/" + lns.substring(with: m.range(at: 2))
            }
            var item = ContextItem(id: "skill|\(name)", kind: .skill, title: name, scope: "Listed", path: path, content: line, load: .listing)
            if let path {
                item.modified = FileUtil.modified(URL(filePath: path))
                if !FileUtil.exists(URL(filePath: path)) { item.diskStatus = .deleted }
            }
            out.append(item)
        }
        return out
    }

    func agentsItems(_ text: String, cwd: String) -> [ContextItem] {
        var out: [ContextItem] = []
        var body = text
        if let start = body.range(of: "<INSTRUCTIONS>"),
           let end = body.range(of: "</INSTRUCTIONS>", options: .backwards, range: start.upperBound..<body.endIndex) {
            body = String(body[start.upperBound..<end.lowerBound])
        }
        // Codex sends the global file, then `--- project-doc ---`, then the project docs. Some
        // global files carry pasted BEGIN/END marker comments; they are not structure.
        body = body.replacingOccurrences(of: #"<!-- (BEGIN|END) GLOBAL AGENTS\.md: [^>]*-->\n?"#, with: "", options: .regularExpression)
        var globalText = ""
        var projectPart = body
        if let sep = body.range(of: "--- project-doc ---") {
            globalText = String(body[..<sep.lowerBound])
            projectPart = String(body[sep.upperBound...])
        }
        var remainder = projectPart
        for url in CodexResolver(env: env).projectDocFiles(cwd: URL(filePath: cwd)) {
            guard let current = FileUtil.read(url) else { continue }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let range = remainder.range(of: trimmed) else { continue }
            remainder.removeSubrange(range)
            out.append(ContextItem(kind: .instructions, title: FileUtil.abbreviate(url.path, home: env.home), scope: "Project", path: url.path,
                                   content: current, load: .always, modified: FileUtil.modified(url),
                                   issues: ReferenceChecker.issues(for: current, home: env.home), diskStatus: .same))
        }
        var leftover = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        // Without a separator the block is the global file alone, or project docs alone.
        if globalText.isEmpty, !leftover.isEmpty, FileUtil.isFile(URL(filePath: PresetKeys.userInstructionsPath(.codex, env: env))) {
            globalText = leftover
            leftover = ""
        }
        let global = globalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty {
            let path = PresetKeys.userInstructionsPath(.codex, env: env)
            var item = ContextItem(kind: .instructions, title: FileUtil.abbreviate(path, home: env.home), scope: "Global", path: path,
                                   content: global, load: .always, issues: ReferenceChecker.issues(for: global, home: env.home))
            DiskCompare.apply(to: &item)
            out.insert(item, at: 0)
        }
        if !leftover.isEmpty {
            out.append(ContextItem(id: "agents|unmatched|\(leftover.hashValue)", kind: .instructions, title: "Project AGENTS.md text (changed or moved since)", scope: "Project",
                                   content: leftover, load: .always,
                                   note: "Codex concatenates project docs without file markers. This text no longer matches any file Codex would load from this directory today.",
                                   issues: ReferenceChecker.issues(for: leftover, home: env.home), diskStatus: .changed))
        }
        return out
    }
}

enum DiskCompare {
    /// Marks whether the file on disk still matches the recorded text.
    static func apply(to item: inout ContextItem) {
        guard let path = item.path, !path.isEmpty else { return }
        let url = URL(filePath: path)
        item.modified = FileUtil.modified(url)
        guard let current = FileUtil.read(url) else {
            item.diskStatus = .deleted
            return
        }
        if normalize(current) == normalize(item.content) {
            item.diskStatus = .same
        } else {
            item.diskStatus = .changed
            item.currentContent = current
        }
    }

    static func normalize(_ s: String) -> String {
        Frontmatter(s).body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum Unique {
    /// SwiftUI selection needs unique ids; suffix repeats instead of dropping them.
    static func ids(_ items: [ContextItem]) -> [ContextItem] {
        var counts: [String: Int] = [:]
        return items.map { item in
            var item = item
            let n = counts[item.id, default: 0]
            counts[item.id] = n + 1
            if n > 0 { item.id += "#\(n)" }
            return item
        }
    }
}

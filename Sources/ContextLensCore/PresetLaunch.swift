import Foundation
import TOMLKit

/// Shows a snapshot as a preset would load it.
public enum PresetApplier {
    public static func apply(_ preset: Preset, to snapshot: ContextSnapshot, env: HarnessEnvironment = .current) -> ContextSnapshot {
        guard preset.id != Preset.onDisk.id else { return snapshot }
        var snap = snapshot
        snap.items = snapshot.items.map { original in
            var item = original
            guard item.load != .inactive, let reason = preset.offReason(item, harness: snapshot.harness, env: env) else { return item }
            item.load = .inactive
            item.presetOff = reason
            return item
        }
        if preset.addsInstructions {
            let replaced = PresetKeys.userInstructionsPath(snapshot.harness, env: env)
            let item = ContextItem(
                id: "preset|\(preset.id)",
                kind: .instructions,
                title: "\(preset.name) instructions",
                scope: "Preset",
                content: preset.instructions,
                load: .always,
                note: preset.instructionsMode == .replace
                    ? "Loaded in place of \(FileUtil.abbreviate(replaced, home: env.home)); project files still load."
                    : "Loaded in addition to the instruction files on disk."
            )
            let index = snap.items.firstIndex { $0.kind == .instructions && $0.path == replaced }.map { $0 + 1 } ?? 0
            snap.items.insert(item, at: index)
        }
        if preset.base == .cleanInstall {
            snap.notes.insert(snapshot.harness == .claude
                ? "Clean install starts Claude Code with --safe-mode: its built-in skills and system prompt remain."
                : "Clean install starts Codex with a separate home: its base instructions and built-in tools remain.", at: 0)
        }
        return snap
    }
}

/// How to start a harness under a preset: environment, arguments, and files written for it.
public struct LaunchPlan: Sendable, Equatable {
    public var harness: Harness
    public var env: [String: String]
    public var args: [String]
    public var notes: [String]
    /// This launch's generated directory, when it has one.
    public var directory: URL?

    public init(harness: Harness, env: [String: String], args: [String], notes: [String], directory: URL? = nil) {
        self.harness = harness
        self.env = env
        self.args = args
        self.notes = notes
        self.directory = directory
    }

    /// Marks the generated directory as in use by `pid`, so cleanup leaves it alone while the
    /// process lives. `context-lens run` execs into the harness, which keeps the pid.
    public func markInUse(pid: Int32) {
        guard let directory else { return }
        try? String(pid).write(to: directory.appending(path: "pid"), atomically: true, encoding: .utf8)
    }

    /// Codex subcommands. Codex ignores `-c` overrides given before a subcommand, so preset
    /// arguments go after it (verified with codex-cli 0.159).
    static let codexSubcommands: Set<String> = [
        "exec", "e", "review", "resume", "fork", "apply", "a", "mcp", "plugin", "login", "logout", "sandbox",
        "debug", "doctor", "app", "app-server", "agents", "queue", "archive", "delete", "completion", "update",
    ]

    /// The full argument list for the harness, with the user's extra arguments.
    /// Codex root options that take a value (codex-cli 0.159 `--help`).
    static let codexValueOptions: Set<String> = [
        "-c", "--config", "--enable", "--disable", "--remote", "--remote-auth-token-env", "-i", "--image",
        "-m", "--model", "--local-provider", "-p", "--profile", "-s", "--sandbox", "-C", "--cd", "--add-dir",
        "-a", "--ask-for-approval",
    ]

    /// The index of the Codex subcommand in `extra`, skipping option values; nil for an
    /// interactive launch (no subcommand, or a prompt).
    static func codexSubcommandIndex(_ extra: [String]) -> Int? {
        var i = 0
        while i < extra.count {
            let token = extra[i]
            if token == "--" { return nil }
            if token.hasPrefix("-") {
                i += (codexValueOptions.contains(token) && !token.contains("=")) ? 2 : 1
                continue
            }
            return codexSubcommands.contains(token) ? i : nil
        }
        return nil
    }

    public func arguments(extra: [String] = []) -> [String] {
        if harness == .codex, let i = Self.codexSubcommandIndex(extra) {
            // Options before the subcommand stay there; the preset's overrides go right after it.
            return Array(extra[...i]) + args + Array(extra[(i + 1)...])
        }
        return args + extra
    }

    /// A command a person can paste into a shell in `cwd`.
    public func commandLine(cwd: String) -> String {
        let envPart = env.sorted { $0.key < $1.key }.map { "\($0.key)=\(Shell.quote($0.value))" }
        let parts = envPart + [harness.command] + args.map(Shell.quote)
        return "cd \(Shell.quote(cwd)) && " + parts.joined(separator: " ")
    }
}

extension Harness {
    /// The command name; the user's shell may wrap it in an alias or function.
    public var command: String { rawValue == "claude" ? "claude" : "codex" }
}

public enum Shell {
    public static func quote(_ s: String) -> String {
        if !s.isEmpty, s.allSatisfy({ $0.isLetter || $0.isNumber || "-_./=:@,+%".contains($0) }) { return s }
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

public enum TOML {
    public static func string(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04X", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    public static func key(_ s: String) -> String {
        s.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) ? s : string(s)
    }
}

/// Turns a preset into a `LaunchPlan`, writing generated settings under
/// `~/.context-lens/generated/<preset>/<harness>/`. Files on disk that the harness reads
/// normally are never modified.
public struct PresetLauncher: Sendable {
    public var env: HarnessEnvironment
    public var store: PresetStore

    public init(env: HarnessEnvironment = .current, store: PresetStore = PresetStore()) {
        self.env = env
        self.store = store
    }

    /// Generated directories older than this are removed. Each launch gets its own directory,
    /// so a running session's files are never replaced by a later launch.
    static let generatedLifetime: TimeInterval = 14 * 86_400

    public func plan(_ preset: Preset, harness: Harness, cwd: URL) throws -> LaunchPlan {
        guard Preset.isSafeID(preset.id) else { throw PresetError.unsafeID(preset.id) }
        let parent = store.root.appending(path: "generated/\(preset.id)/\(harness.rawValue)")
        collectGarbage(in: parent)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let dir = parent.appending(path: "\(stamp)-\(UUID().uuidString.prefix(8).lowercased())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var plan: LaunchPlan
        switch harness {
        case .claude: plan = try claudePlan(preset, cwd: cwd, dir: dir)
        case .codex: plan = try codexPlan(preset, cwd: cwd, dir: dir)
        }
        plan.directory = dir
        return plan
    }

    // MARK: - Claude Code

    func claudePlan(_ preset: Preset, cwd: URL, dir: URL) throws -> LaunchPlan {
        var plan = LaunchPlan(harness: .claude, env: [:], args: [], notes: [])
        if preset.id == Preset.onDisk.id { return plan }
        if preset.base == .cleanInstall {
            try writeJSON(["autoMemoryEnabled": false], to: dir.appending(path: "settings.json"))
            plan.args = ["--safe-mode", "--settings", dir.appending(path: "settings.json").path]
            plan.notes.append("--safe-mode turns off CLAUDE.md, skills, plugins, hooks, MCP servers, agents and output styles.")
            return plan
        }

        let snap = ClaudeResolver(env: env).resolve(cwd: cwd)
        var settings: [String: Any] = [:]
        var excludes: [String] = []
        var skillOverrides: [String: String] = [:]
        var plugins: [String: Bool] = [:]
        for item in snap.items where preset.offReason(item, harness: .claude, env: env) != nil {
            guard let key = PresetKeys.key(for: item, harness: .claude).key else { continue }
            if key.hasPrefix("file:"), let path = item.path { excludes.append(path) }
            if key.hasPrefix("skill:"), !preset.isGroupOff(.skills) { skillOverrides[item.title] = "off" }
            if key.hasPrefix("plugin:") { plugins[String(key.dropFirst("plugin:".count))] = false }
        }
        if !excludes.isEmpty { settings["claudeMdExcludes"] = Array(Set(excludes)).sorted() }
        if !skillOverrides.isEmpty { settings["skillOverrides"] = skillOverrides }
        if !plugins.isEmpty { settings["enabledPlugins"] = plugins }
        if preset.disableBundledSkills { settings["disableBundledSkills"] = true }
        if preset.isGroupOff(.memory) || preset.disabledKeys(.claude).contains(PresetKeys.memory) { settings["autoMemoryEnabled"] = false }
        if preset.isGroupOff(.hooks) || preset.disabledKeys(.claude).contains(PresetKeys.hooks) { settings["disableAllHooks"] = true }
        if preset.isGroupOff(.skills) {
            plan.args.append("--disable-slash-commands")
            plan.notes.append("--disable-slash-commands also hides skills from /-completion.")
        }

        let servers = snap.items.filter { $0.kind == .mcp }
        let offServers = servers.filter { preset.offReason($0, harness: .claude, env: env) != nil }
        if preset.isGroupOff(.mcp) || !offServers.isEmpty {
            var keep: [String: Any] = [:]
            for item in servers where preset.offReason(item, harness: .claude, env: env) == nil {
                if let data = item.content.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: data) { keep[item.title] = obj }
            }
            plan.args.append("--strict-mcp-config")
            if !keep.isEmpty {
                let url = dir.appending(path: "mcp.json")
                try writeJSON(["mcpServers": keep], to: url)
                plan.args += ["--mcp-config", url.path]
            }
            plan.notes.append("MCP servers come from an explicit list, so claude.ai connectors are not loaded.")
        }

        if preset.addsInstructions {
            let instructionsDir = dir.appending(path: "instructions")
            try FileManager.default.createDirectory(at: instructionsDir, withIntermediateDirectories: true)
            try preset.instructions.write(to: instructionsDir.appending(path: "CLAUDE.md"), atomically: true, encoding: .utf8)
            plan.args += ["--add-dir", instructionsDir.path]
            plan.env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] = "1"
        }
        if !settings.isEmpty {
            let url = dir.appending(path: "settings.json")
            try writeJSON(settings, to: url)
            plan.args = ["--settings", url.path] + plan.args
        }
        return plan
    }

    // MARK: - Codex

    func codexPlan(_ preset: Preset, cwd: URL, dir: URL) throws -> LaunchPlan {
        var plan = LaunchPlan(harness: .codex, env: [:], args: [], notes: [])
        if preset.id == Preset.onDisk.id { return plan }
        let real = env.codexHome

        if preset.base == .cleanInstall {
            let home = dir.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for name in ["auth.json", "sessions", "archived_sessions"] { try link(real.appending(path: name), into: home) }
            try cleanInstallConfig(from: real.appending(path: "config.toml")).write(to: home.appending(path: "config.toml"), atomically: true, encoding: .utf8)
            plan.env["CODEX_HOME"] = home.path
            plan.args = ["-c", "skills.include_instructions=false", "-c", "project_doc_max_bytes=0", "-c", "features.memories=false"]
            plan.notes.append("Codex runs from a separate home that links your login and session history; MCP servers and plugins are not configured there.")
            return plan
        }

        let snap = CodexResolver(env: env).resolve(cwd: cwd)
        let globalPath = PresetKeys.userInstructionsPath(.codex, env: env)
        let globalOff = preset.disabledKeys(.codex).contains(PresetKeys.file(globalPath))
        if globalOff || (preset.addsInstructions && preset.instructionsMode == .replace) {
            // The global AGENTS.md is read from CODEX_HOME and has no config switch, so use a home
            // that links everything except it. SQLite state stays separate to avoid sharing WAL files.
            let home = dir.appending(path: "home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            for name in ["auth.json", "config.toml", "sessions", "archived_sessions", "skills", "rules", "plugins", "prompts", "docs", "TOOLS.md", "session_index.jsonl"] {
                try link(real.appending(path: name), into: home)
            }
            let memories = home.appending(path: "memories")
            try FileManager.default.createDirectory(at: memories, withIntermediateDirectories: true)
            for name in ["memory_summary.md", "MEMORY.md"] {
                let src = real.appending(path: "memories/\(name)")
                if FileUtil.isFile(src) { try FileManager.default.copyItem(at: src, to: memories.appending(path: name)) }
            }
            if preset.addsInstructions && preset.instructionsMode == .replace {
                try preset.instructions.write(to: home.appending(path: "AGENTS.md"), atomically: true, encoding: .utf8)
            }
            plan.env["CODEX_HOME"] = home.path
            plan.notes.append("Codex runs from a home that links your login, config, skills and history but not ~/.codex/AGENTS.md.")
        }
        if preset.addsInstructions && preset.instructionsMode == .append {
            plan.args += ["-c", "developer_instructions=" + TOML.string(preset.instructions)]
        }
        if preset.disabledKeys(.codex).contains(PresetKeys.codexProjectDocs) {
            plan.args += ["-c", "project_doc_max_bytes=0"]
        }
        if preset.isGroupOff(.skills) {
            plan.args += ["-c", "skills.include_instructions=false"]
        } else {
            let off = snap.items.filter { $0.kind == .skill && preset.offReason($0, harness: .codex, env: env) != nil }.compactMap(\.path)
            if !off.isEmpty {
                let existing = CodexConfig(text: FileUtil.read(real.appending(path: "config.toml")) ?? "").skillEntries
                plan.args += ["-c", "skills.config=" + Self.mergedSkillConfig(existing: existing, disabledPaths: off)]
            }
        }
        if preset.isGroupOff(.memory) || preset.disabledKeys(.codex).contains(PresetKeys.memory) {
            plan.args += ["-c", "features.memories=false"]
        }
        for item in snap.items where item.kind == .mcp && preset.offReason(item, harness: .codex, env: env) != nil {
            plan.args += ["-c", "mcp_servers.\(TOML.key(item.title)).enabled=false"]
        }
        return plan
    }

    /// The override replaces the whole `skills.config` array, so it carries the user's own
    /// entries, with the preset's switched-off skills forced to `enabled=false`.
    static func mergedSkillConfig(existing: [CodexConfig.SkillEntry], disabledPaths: [String]) -> String {
        var entries = existing
        var covered = Set<String>()
        for i in entries.indices {
            if let path = entries[i].path, disabledPaths.contains(path) {
                entries[i].enabled = false
                covered.insert(path)
            }
        }
        for path in disabledPaths where !covered.contains(path) {
            entries.append(CodexConfig.SkillEntry(path: path, name: nil, enabled: false))
        }
        let inline = entries.map { e -> String in
            var fields: [String] = []
            if let path = e.path { fields.append("path=" + TOML.string(path)) }
            if let name = e.name { fields.append("name=" + TOML.string(name)) }
            fields.append("enabled=\(e.enabled)")
            return "{" + fields.joined(separator: ",") + "}"
        }
        return "[" + inline.joined(separator: ",") + "]"
    }

    /// Settings Clean install keeps from the user's config: model and login choices, and project trust.
    static let cleanInstallKeys: [String] = [
        "model", "model_provider", "model_reasoning_effort", "model_reasoning_summary", "model_verbosity",
        "approval_policy", "sandbox_mode", "service_tier", "preferred_auth_method", "cli_auth_credentials_store",
        "forced_login_method", "forced_chatgpt_workspace_id", "chatgpt_base_url",
    ]

    /// An allowlist copy of the user's config, built from a real TOML parse so nothing inside a
    /// string (such as example settings in custom instructions) can become a setting.
    func cleanInstallConfig(from url: URL) -> String {
        let out = TOMLTable()
        guard let user = try? TOMLTable(string: FileUtil.read(url) ?? "") else {
            return "# Generated by Context Lens for the Clean install preset.\n"
        }
        for key in Self.cleanInstallKeys {
            guard let value = user[key] else { continue }
            switch value.type {
            case .string, .int, .bool, .double: out[key] = value
            default: continue
            }
        }
        if let provider = user["model_provider"]?.string, let def = user["model_providers"]?.table?[provider]?.table {
            let providers = TOMLTable()
            providers[provider] = def
            out["model_providers"] = providers
        }
        if let projects = user["projects"]?.table {
            let trusted = TOMLTable()
            for path in projects.keys {
                if let trust = projects[path]?.table?["trust_level"]?.string {
                    trusted[path] = TOMLTable(["trust_level": trust])
                }
            }
            if !trusted.isEmpty { out["projects"] = trusted }
        }
        return "# Generated by Context Lens for the Clean install preset.\n" + out.convert() + "\n"
    }

    /// Removes old launch directories, except ones whose process is still running.
    func collectGarbage(in parent: URL) {
        let cutoff = Date().addingTimeInterval(-Self.generatedLifetime)
        for child in FileUtil.children(parent) where (FileUtil.modified(child) ?? .distantPast) < cutoff {
            if let text = FileUtil.read(child.appending(path: "pid")),
               let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
               kill(pid, 0) == 0 || errno == EPERM {
                continue
            }
            try? FileManager.default.removeItem(at: child)
        }
    }

    func link(_ src: URL, into home: URL) throws {
        guard FileUtil.exists(src) else { return }
        try FileManager.default.createSymbolicLink(at: home.appending(path: src.lastPathComponent), withDestinationURL: src)
    }

    func writeJSON(_ obj: [String: Any], to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }
}

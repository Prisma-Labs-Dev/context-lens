import Foundation
import TOMLKit

/// Predicts what Codex loads for a working directory, from the files on disk.
///
/// Rules verified against codex-cli 0.159.3 rollouts (see docs/harness-rules.md):
/// - Global: `$CODEX_HOME/AGENTS.override.md`, else `$CODEX_HOME/AGENTS.md`.
/// - Project: from the git root down to the cwd, the first of `AGENTS.override.md`, `AGENTS.md`,
///   then `project_doc_fallback_filenames` in each directory, concatenated up to
///   `project_doc_max_bytes` (32 KiB by default). `CLAUDE.md` is not read.
/// - Skills: `$CODEX_HOME/skills` (with `.system`), `~/.agents/skills`, and `.agents/skills`
///   in each directory from the cwd up to the git root. Only name and description are listed.
/// - Memory: with `[features] memories = true`, `memories/memory_summary.md` is injected.
public struct CodexResolver: Sendable {
    public var env: HarnessEnvironment

    public init(env: HarnessEnvironment = .current) {
        self.env = env
    }

    public func resolve(cwd: URL) -> ContextSnapshot {
        // Harnesses record real paths (/private/tmp, not /tmp).
        let cwd = FileUtil.realPath(cwd)
        let config = CodexConfig(text: FileUtil.read(env.codexHome.appending(path: "config.toml")) ?? "")
        var items: [ContextItem] = []

        // Global instructions.
        let override = env.codexHome.appending(path: "AGENTS.override.md")
        let global = env.codexHome.appending(path: "AGENTS.md")
        if let item = fileItem(override, kind: .instructions, scope: "Global", load: .always) {
            items.append(item)
            if var shadowed = fileItem(global, kind: .inactive, scope: "Global", load: .inactive) {
                shadowed.note = "AGENTS.override.md in the same directory takes precedence."
                items.append(shadowed)
            }
        } else if let item = fileItem(global, kind: .instructions, scope: "Global", load: .always) {
            items.append(item)
        }

        // Project docs.
        items += projectDocs(cwd: cwd, config: config)

        // Memory.
        let summary = env.codexHome.appending(path: "memories/memory_summary.md")
        if var item = fileItem(summary, kind: .memory, scope: "Memories", load: config.memoriesEnabled ? .always : .inactive) {
            item.note = config.memoriesEnabled
                ? "Injected as MEMORY_SUMMARY in the developer message."
                : "[features] memories is off, so Codex does not inject it."
            items.append(item)
        }
        for name in ["MEMORY.md", "raw_memories.md"] {
            if let item = fileItem(env.codexHome.appending(path: "memories/\(name)"), kind: .memory, scope: "Memories", load: .onDemand) {
                items.append(item)
            }
        }

        items += skills(cwd: cwd)
        items += config.mcpServers.map { name in
            ContextItem(
                id: "mcp|codex|\(name)",
                kind: .mcp, title: name, scope: "Global",
                path: env.codexHome.appending(path: "config.toml").path,
                content: config.section(named: "mcp_servers.\(name)"),
                load: .onDemand,
                note: "Tools from this server are added to the tool list."
            )
        }

        let notes = [
            "Base instructions, permissions and environment context are not on disk. Open a recorded session to see them.",
        ]
        return ContextSnapshot(harness: .codex, cwd: cwd.path, items: items, notes: notes)
    }

    func projectDirs(cwd: URL) -> [URL] {
        guard let root = Git.roots(for: cwd)?.worktree else { return [cwd] }
        return FileUtil.ancestorsTopDown(cwd).filter { $0.path == root.path || $0.path.hasPrefix(root.path + "/") }
    }

    /// The project doc files Codex would concatenate, in order.
    public func projectDocFiles(cwd: URL) -> [URL] {
        let config = CodexConfig(text: FileUtil.read(env.codexHome.appending(path: "config.toml")) ?? "")
        return projectDocs(cwd: cwd.standardizedFileURL, config: config).filter { $0.load == .always }.compactMap { $0.path.map { URL(filePath: $0) } }
    }

    func projectDocs(cwd: URL, config: CodexConfig) -> [ContextItem] {
        let names = ["AGENTS.override.md", "AGENTS.md"] + config.fallbackFilenames
        var budget = config.projectDocMaxBytes
        var out: [ContextItem] = []
        for dir in projectDirs(cwd: cwd) {
            let present = names.map { dir.appending(path: $0) }.filter(FileUtil.isFile)
            guard let chosen = present.first, var item = fileItem(chosen, kind: .instructions, scope: "Project", load: .always) else { continue }
            let size = item.content.utf8.count
            if budget <= 0 {
                item.load = .inactive
                item.kind = .inactive
                item.issues.append(Issue(kind: .truncated, message: "Dropped: project_doc_max_bytes (\(config.projectDocMaxBytes)) already used up"))
            } else if size > budget {
                item.issues.append(Issue(kind: .truncated, message: "Truncated to \(budget) of \(size) bytes by project_doc_max_bytes"))
                item.content = String(decoding: Array(item.content.utf8.prefix(budget)), as: UTF8.self)
            }
            budget -= size
            out.append(item)
            for other in present.dropFirst() {
                if var shadowed = fileItem(other, kind: .inactive, scope: "Project", load: .inactive) {
                    shadowed.note = "\(chosen.lastPathComponent) in the same directory takes precedence."
                    out.append(shadowed)
                }
            }
        }
        return out
    }

    func skills(cwd: URL) -> [ContextItem] {
        var roots: [(URL, String)] = [
            (env.codexHome.appending(path: "skills"), "User"),
            (env.home.appending(path: ".agents/skills"), "User"),
        ]
        for dir in projectDirs(cwd: cwd).reversed() where dir.path != env.home.path {
            roots.append((dir.appending(path: ".agents/skills"), "Project"))
        }
        let disabled = Set(FileUtil.children(env.codexHome.appending(path: "disabled-skills")).map(\.lastPathComponent))
        var out: [ContextItem] = []
        var names = Set<String>()
        for (root, scope) in roots {
            for file in FileUtil.skillFiles(under: root, maxDepth: 3) {
                guard let text = FileUtil.read(file) else { continue }
                let fm = Frontmatter(text)
                let name = fm.fields["name"] ?? file.deletingLastPathComponent().lastPathComponent
                let isSystem = file.path.contains("/skills/.system/")
                let shadowed = !names.insert(name).inserted
                var item = ContextItem(
                    kind: .skill, title: name, scope: isSystem ? "System" : scope, path: file.path,
                    content: "- \(name): \(fm.fields["description"] ?? "") (file: \(file.path))",
                    load: shadowed || disabled.contains(name) ? .inactive : .listing,
                    modified: FileUtil.modified(file),
                    issues: ReferenceChecker.issues(for: text, home: env.home)
                )
                if shadowed { item.note = "Another skill named \(name) is listed first." }
                if disabled.contains(name) { item.note = "Disabled in \(FileUtil.abbreviate(env.codexHome.path, home: env.home))/disabled-skills." }
                out.append(item)
            }
        }
        out += pluginSkills(names: &names, disabledPlugins: CodexConfig(text: FileUtil.read(env.codexHome.appending(path: "config.toml")) ?? "").disabledPlugins)
        return out
    }

    /// Plugin skills live in `plugins/cache/<marketplace>/<plugin>/<version>/skills/<skill>/SKILL.md`
    /// and are listed as `plugin:skill`. Only the newest cached version of each plugin counts.
    func pluginSkills(names: inout Set<String>, disabledPlugins: Set<String>) -> [ContextItem] {
        var out: [ContextItem] = []
        for market in FileUtil.children(env.codexHome.appending(path: "plugins/cache")) where FileUtil.isDirectory(market) {
            for plugin in FileUtil.children(market) where FileUtil.isDirectory(plugin) {
                let pluginName = plugin.lastPathComponent
                let versions = FileUtil.children(plugin).filter { FileUtil.isDirectory($0.appending(path: "skills")) }
                guard let latest = versions.max(by: { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedAscending }) else { continue }
                let disabled = disabledPlugins.contains("\(pluginName)@\(market.lastPathComponent)")
                for file in FileUtil.skillFiles(under: latest.appending(path: "skills"), maxDepth: 2) {
                    guard let text = FileUtil.read(file) else { continue }
                    let fm = Frontmatter(text)
                    let skill = fm.fields["name"] ?? file.deletingLastPathComponent().lastPathComponent
                    let name = "\(pluginName):\(skill)"
                    let shadowed = !names.insert(name).inserted
                    var item = ContextItem(
                        kind: .skill, title: name, scope: "Plugin \(pluginName)", path: file.path,
                        content: "- \(name): \(fm.fields["description"] ?? "") (file: \(file.path))",
                        load: disabled || shadowed ? .inactive : .listing,
                        modified: FileUtil.modified(file),
                        issues: ReferenceChecker.issues(for: text, home: env.home)
                    )
                    if disabled { item.note = "The plugin is disabled in config.toml." }
                    out.append(item)
                }
            }
        }
        return out
    }

    func fileItem(_ url: URL, kind: ContextKind, scope: String, load: LoadMode) -> ContextItem? {
        guard let text = FileUtil.read(url) else { return nil }
        return ContextItem(
            kind: kind,
            title: FileUtil.abbreviate(url.path, home: env.home),
            scope: scope,
            path: url.path,
            content: text,
            load: load,
            modified: FileUtil.modified(url),
            issues: ReferenceChecker.issues(for: text, home: env.home)
        )
    }
}

/// The parts of Codex's config.toml that change what it injects, read with a real TOML parser.
struct CodexConfig {
    struct SkillEntry: Equatable {
        var path: String?
        var name: String?
        var enabled: Bool
    }

    var projectDocMaxBytes = 32 * 1024
    var fallbackFilenames: [String] = []
    var memoriesEnabled = false
    var mcpServers: [String] = []
    /// `[plugins."name@marketplace"]` tables with `enabled = false`.
    var disabledPlugins: Set<String> = []
    /// The user's own `skills.config` entries, however the TOML spells them.
    var skillEntries: [SkillEntry] = []
    let table: TOMLTable?

    init(text: String) {
        table = try? TOMLTable(string: text)
        guard let t = table else { return }
        if let n = t["project_doc_max_bytes"]?.int { projectDocMaxBytes = n }
        if let list = t["project_doc_fallback_filenames"]?.array { fallbackFilenames = list.compactMap { $0.string } }
        memoriesEnabled = t["features"]?.table?["memories"]?.bool ?? false
        if let servers = t["mcp_servers"]?.table { mcpServers = servers.keys.sorted() }
        if let plugins = t["plugins"]?.table {
            for key in plugins.keys where plugins[key]?.table?["enabled"]?.bool == false { disabledPlugins.insert(key) }
        }
        for entry in t["skills"]?.table?["config"]?.array ?? TOMLArray() {
            guard let e = entry.table else { continue }
            skillEntries.append(SkillEntry(path: e["path"]?.string, name: e["name"]?.string, enabled: e["enabled"]?.bool ?? true))
        }
    }

    /// One MCP server's table, as TOML text for display.
    func section(named name: String) -> String {
        let server = name.hasPrefix("mcp_servers.") ? String(name.dropFirst("mcp_servers.".count)) : name
        guard let sub = table?["mcp_servers"]?.table?[server]?.table else { return "" }
        let wrapper = TOMLTable()
        let servers = TOMLTable()
        servers[server] = sub
        wrapper["mcp_servers"] = servers
        return wrapper.convert().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

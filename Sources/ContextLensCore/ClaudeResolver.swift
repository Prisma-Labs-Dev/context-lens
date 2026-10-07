import Foundation

/// Predicts what Claude Code loads for a working directory, from the files on disk.
///
/// Rules verified against Claude Code 2.1.283 transcripts (see docs/harness-rules.md):
/// - `~/.claude/CLAUDE.md` and `~/.claude/rules/*.md` are user scope.
/// - Every ancestor of the cwd (except `/`) contributes `CLAUDE.md`, `.claude/CLAUDE.md`,
///   `.claude/rules/**/*.md` and `CLAUDE.local.md`.
/// - Rules with `paths:` frontmatter load only when matching files are touched.
/// - `AGENTS.md` files are loaded only when no project or local CLAUDE file exists at all.
/// - In a linked git worktree nested inside its main repo, directories between the main repo
///   root and the worktree root are skipped.
/// - `CLAUDE.md` files below the cwd load on demand.
/// - Auto memory lives in `~/.claude/projects/<slug of main repo root>/memory/`.
public struct ClaudeResolver: Sendable {
    public var env: HarnessEnvironment

    public init(env: HarnessEnvironment = .current) {
        self.env = env
    }

    public func resolve(cwd: URL) -> ContextSnapshot {
        // Harnesses record real paths (/private/tmp, not /tmp).
        let cwd = FileUtil.realPath(cwd)
        var items: [ContextItem] = []
        var seen = Set<String>()

        func add(_ item: ContextItem) {
            if let p = item.path, !seen.insert(p).inserted { return }
            items.append(item)
        }

        // Managed policy file.
        if let item = fileItem(env.managedClaudeMd, kind: .instructions, scope: "Managed", load: .always) {
            add(item)
        }

        // User scope.
        let userClaudeMd = env.claudeHome.appending(path: "CLAUDE.md")
        if let item = fileItem(userClaudeMd, kind: .instructions, scope: "User", load: .always) { add(item) }
        for rule in FileUtil.markdownFiles(under: env.claudeHome.appending(path: "rules")) {
            if let item = ruleItem(rule, scope: "User") { add(item) }
        }
        // Mark user-scope paths as seen so the ancestor walk through ~ does not repeat them.
        seen.insert(userClaudeMd.path)

        // Project scope: ancestors top-down.
        let git = Git.roots(for: cwd)
        let dirs = projectDirs(cwd: cwd, git: git)
        var projectItems: [ContextItem] = []
        var agentsFiles: [URL] = []
        for dir in dirs {
            let candidates: [(URL, String)] = [
                (dir.appending(path: "CLAUDE.md"), "Project"),
                (dir.appending(path: ".claude/CLAUDE.md"), "Project"),
            ]
            for (url, scope) in candidates where !seen.contains(url.path) {
                if let item = fileItem(url, kind: .instructions, scope: scope, load: .always) { projectItems.append(item) }
            }
            let rulesDir = dir.appending(path: ".claude/rules")
            if rulesDir.path != env.claudeHome.appending(path: "rules").path {
                for rule in FileUtil.markdownFiles(under: rulesDir) {
                    if let item = ruleItem(rule, scope: "Project") { projectItems.append(item) }
                }
            }
            if let item = fileItem(dir.appending(path: "CLAUDE.local.md"), kind: .instructions, scope: "Local", load: .always) {
                projectItems.append(item)
            }
            let agents = dir.appending(path: "AGENTS.md")
            if FileUtil.isFile(agents) { agentsFiles.append(agents) }
        }
        // Any CLAUDE file or rule, even a path-scoped one, turns the AGENTS.md fallback off.
        let hasClaudeFiles = !projectItems.isEmpty
        projectItems.forEach(add)
        for url in agentsFiles {
            if hasClaudeFiles {
                if var item = fileItem(url, kind: .inactive, scope: "Project", load: .inactive) {
                    item.note = "Claude Code reads AGENTS.md only when the project has no CLAUDE.md, CLAUDE.local.md or rules. Import it with @AGENTS.md from a CLAUDE.md to load it."
                    add(item)
                }
            } else if let item = fileItem(url, kind: .instructions, scope: "Project", load: .always) {
                add(item)
            }
        }

        // Imports referenced with @path from any loaded instruction file. A shadowed AGENTS.md
        // that a CLAUDE.md imports with @AGENTS.md is loaded after all, so it may be imported.
        let shadowed = Set(items.filter { $0.load == .inactive }.compactMap(\.path))
        seen.subtract(shadowed)
        var importedPaths = Set<String>()
        for item in items where item.load == .always && (item.kind == .instructions || item.kind == .rule) {
            for imported in imports(of: item, depth: 1, seen: &seen) {
                if let p = imported.path { importedPaths.insert(p) }
                items.append(imported)
            }
        }
        items.removeAll { $0.load == .inactive && $0.path.map(importedPaths.contains) == true }
        seen.formUnion(shadowed)

        // Auto memory.
        let memoryRoot = git?.main ?? cwd
        let memoryDir = env.claudeHome.appending(path: "projects/\(ClaudePaths.slug(memoryRoot.path))/memory")
        let memoryIndex = memoryDir.appending(path: "MEMORY.md")
        if var item = fileItem(memoryIndex, kind: .memory, scope: "Auto memory", load: .always) {
            item.title = "MEMORY.md"
            item.note = "Index of auto memory for \(FileUtil.abbreviate(memoryRoot.path, home: env.home)). Claude Code loads the first 200 lines; the files it links load when read."
            add(item)
        }
        for url in FileUtil.markdownFiles(under: memoryDir) where url.lastPathComponent != "MEMORY.md" {
            if var item = fileItem(url, kind: .memory, scope: "Auto memory", load: .onDemand) {
                item.title = url.lastPathComponent
                add(item)
            }
        }

        // Nested CLAUDE.md files below the cwd.
        for url in nestedInstructionFiles(below: cwd) {
            if let item = fileItem(url, kind: .onDemand, scope: "Project", load: .onDemand) {
                var item = item
                item.note = "Loaded when Claude Code reads files in \(FileUtil.abbreviate(url.deletingLastPathComponent().path, home: env.home))."
                add(item)
            }
        }

        items += skills(cwd: cwd, git: git)
        items += agents(cwd: cwd, git: git)
        items += mcpServers(cwd: cwd, git: git)
        items += hooks(cwd: cwd, git: git)

        var notes: [String] = []
        if git?.main != git?.worktree, let git {
            notes.append("Linked worktree of \(FileUtil.abbreviate(git.main.path, home: env.home)). Auto memory is shared with the main repo.")
        }
        notes.append("System prompt, tool definitions and MCP server instructions are not on disk. Open a recorded session to see them.")
        return ContextSnapshot(harness: .claude, cwd: cwd.path, items: items, notes: notes)
    }

    // MARK: - Directory walk

    func projectDirs(cwd: URL, git: Git.Roots?) -> [URL] {
        var dirs = FileUtil.ancestorsTopDown(cwd)
        if let git, git.main != git.worktree, git.worktree.path.hasPrefix(git.main.path + "/") {
            let main = git.main.path
            let wt = git.worktree.path
            dirs.removeAll { d in
                (d.path == main || d.path.hasPrefix(main + "/")) && wt.hasPrefix(d.path + "/")
            }
        }
        return dirs
    }

    func nestedInstructionFiles(below cwd: URL, maxDepth: Int = 4, limit: Int = 60) -> [URL] {
        let skip: Set<String> = ["node_modules", ".git", ".build", "build", "DerivedData", "Pods", "dist", ".next", "vendor", "worktrees", ".venv", "venv", "target"]
        var out: [URL] = []
        func walk(_ dir: URL, _ depth: Int) {
            guard out.count < limit, depth <= maxDepth else { return }
            for child in FileUtil.children(dir) where FileUtil.isDirectory(child) {
                let name = child.lastPathComponent
                if skip.contains(name) || (name.hasPrefix(".") && name != ".claude") { continue }
                // A session run in ~ would otherwise walk into Photos, Mail and Documents and
                // set off a privacy prompt for each.
                if PrivacyGuard.skip(child, home: env.home.path) { continue }
                if name == ".claude" { continue }
                for file in ["CLAUDE.md", ".claude/CLAUDE.md"] {
                    let url = child.appending(path: file)
                    if FileUtil.isFile(url) { out.append(url) }
                }
                walk(child, depth + 1)
            }
        }
        walk(cwd, 1)
        return out
    }

    // MARK: - Items

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

    func ruleItem(_ url: URL, scope: String) -> ContextItem? {
        guard var item = fileItem(url, kind: .rule, scope: scope, load: .always) else { return nil }
        let fm = Frontmatter(item.content)
        if let globs = fm.lists["paths"] ?? fm.fields["paths"].map({ [$0] }), !globs.isEmpty {
            item.load = .onDemand
            item.note = "Loads when Claude Code touches files matching \(globs.joined(separator: ", "))."
        }
        return item
    }

    nonisolated(unsafe) static let importPattern = try! NSRegularExpression(pattern: #"(?:^|\s)@((?:~/|/|\./|\.\./|[A-Za-z0-9_])[^\s`'")\]]*)"#, options: [.anchorsMatchLines])

    func imports(of item: ContextItem, depth: Int, seen: inout Set<String>) -> [ContextItem] {
        guard depth <= 5, let path = item.path else { return [] }
        let base = URL(filePath: path).deletingLastPathComponent()
        let text = Self.stripCode(item.content)
        let ns = text as NSString
        var out: [ContextItem] = []
        for m in Self.importPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var ref = ns.substring(with: m.range(at: 1))
            while let last = ref.last, ".,:;".contains(last) { ref.removeLast() }
            // Mentions like @username or @scope/package are not file imports.
            guard ref.contains(".") || ref.contains("/") else { continue }
            let expanded = FileUtil.expandTilde(ref, home: env.home)
            let url = FileUtil.realPath(expanded.hasPrefix("/") ? URL(filePath: expanded) : base.appending(path: expanded))
            guard !seen.contains(url.path) else { continue }
            if var child = fileItem(url, kind: .imported, scope: item.scope, load: .always) {
                seen.insert(url.path)
                child.note = "Imported by \(item.title) with @\(ref)."
                out.append(child)
                out += imports(of: child, depth: depth + 1, seen: &seen)
            } else if ref.hasSuffix(".md") || ref.contains("/") {
                out.append(ContextItem(
                    kind: .imported, title: "@\(ref)", scope: item.scope, path: nil,
                    content: "", load: .inactive, note: "Referenced by \(item.title).",
                    issues: [Issue(kind: .missingImport, message: "Import @\(ref) does not resolve to a file")]
                ))
            }
        }
        return out
    }

    /// Imports are not evaluated inside code spans or fenced code blocks.
    static func stripCode(_ text: String) -> String {
        var out: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inFence.toggle()
                continue
            }
            if inFence { continue }
            out.append(line.replacingOccurrences(of: #"`[^`]*`"#, with: "", options: .regularExpression))
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Skills, agents, MCP, hooks

    func skillDirs(cwd: URL, git: Git.Roots?) -> [(URL, String)] {
        var roots: [(URL, String)] = [(env.claudeHome.appending(path: "skills"), "User")]
        for dir in projectDirs(cwd: cwd, git: git).reversed() where dir.path != env.home.path {
            roots.append((dir.appending(path: ".claude/skills"), "Project"))
        }
        for plugin in enabledPlugins() {
            roots.append((plugin.path.appending(path: "skills"), "Plugin \(plugin.name)"))
        }
        return roots
    }

    func skills(cwd: URL, git: Git.Roots?) -> [ContextItem] {
        var out: [ContextItem] = []
        var names = Set<String>()
        for (root, scope) in skillDirs(cwd: cwd, git: git) {
            for file in FileUtil.skillFiles(under: root) {
                guard let text = FileUtil.read(file) else { continue }
                let fm = Frontmatter(text)
                let name = fm.fields["name"] ?? file.deletingLastPathComponent().lastPathComponent
                let description = fm.fields["description"] ?? ""
                let hidden = fm.fields["disable-model-invocation"] == "true"
                let shadowed = !names.insert(name).inserted
                var item = ContextItem(
                    kind: .skill,
                    title: name,
                    scope: scope,
                    path: file.path,
                    content: "- \(name): \(description)",
                    load: hidden || shadowed ? .inactive : .listing,
                    modified: FileUtil.modified(file),
                    issues: ReferenceChecker.issues(for: text, home: env.home)
                )
                if hidden { item.note = "disable-model-invocation: only the user can run it." }
                if shadowed { item.note = "Another skill named \(name) takes precedence." }
                out.append(item)
            }
        }
        return out
    }

    func agents(cwd: URL, git: Git.Roots?) -> [ContextItem] {
        var roots: [(URL, String)] = [(env.claudeHome.appending(path: "agents"), "User")]
        for dir in projectDirs(cwd: cwd, git: git).reversed() where dir.path != env.home.path {
            roots.append((dir.appending(path: ".claude/agents"), "Project"))
        }
        var out: [ContextItem] = []
        for (root, scope) in roots {
            for file in FileUtil.markdownFiles(under: root) {
                guard let text = FileUtil.read(file) else { continue }
                let fm = Frontmatter(text)
                let name = fm.fields["name"] ?? file.deletingPathExtension().lastPathComponent
                out.append(ContextItem(
                    kind: .agent, title: name, scope: scope, path: file.path,
                    content: "- \(name): \(fm.fields["description"] ?? "")",
                    load: .listing, modified: FileUtil.modified(file),
                    issues: ReferenceChecker.issues(for: text, home: env.home)
                ))
            }
        }
        return out
    }

    struct Plugin { var name: String; var path: URL }

    func enabledPlugins() -> [Plugin] {
        let settings = readJSON(env.claudeHome.appending(path: "settings.json"))
        let enabled = (settings?["enabledPlugins"] as? [String: Bool] ?? [:]).filter(\.value).map(\.key)
        let installed = readJSON(env.claudeHome.appending(path: "plugins/installed_plugins.json"))?["plugins"] as? [String: [[String: Any]]] ?? [:]
        return enabled.sorted().compactMap { key in
            guard let entry = installed[key]?.last, let path = entry["installPath"] as? String else { return nil }
            return Plugin(name: key, path: URL(filePath: path))
        }
    }

    func mcpServers(cwd: URL, git: Git.Roots?) -> [ContextItem] {
        var out: [ContextItem] = []
        let claudeJsonURL = env.home.appending(path: ".claude.json")
        let claudeJson = readJSON(claudeJsonURL)
        func addServers(_ servers: [String: Any]?, scope: String, source: URL) {
            for (name, config) in (servers ?? [:]).sorted(by: { $0.key < $1.key }) {
                let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                out.append(ContextItem(
                    id: "mcp|\(scope)|\(name)",
                    kind: .mcp, title: name, scope: scope, path: source.path,
                    content: String(decoding: data, as: UTF8.self), load: .onDemand,
                    note: "Server instructions join the context when it connects; its tools load on demand."
                ))
            }
        }
        addServers(claudeJson?["mcpServers"] as? [String: Any], scope: "User", source: claudeJsonURL)
        let projects = claudeJson?["projects"] as? [String: Any]
        let projectKey = (git?.worktree ?? cwd).path
        addServers((projects?[projectKey] as? [String: Any])?["mcpServers"] as? [String: Any], scope: "Local", source: claudeJsonURL)
        let mcpJson = (git?.worktree ?? cwd).appending(path: ".mcp.json")
        addServers(readJSON(mcpJson)?["mcpServers"] as? [String: Any], scope: "Project", source: mcpJson)
        return out
    }

    func hooks(cwd: URL, git: Git.Roots?) -> [ContextItem] {
        let root = git?.worktree ?? cwd
        let files: [(URL, String)] = [
            (env.claudeHome.appending(path: "settings.json"), "User"),
            (root.appending(path: ".claude/settings.json"), "Project"),
            (root.appending(path: ".claude/settings.local.json"), "Local"),
        ]
        var out: [ContextItem] = []
        for (url, scope) in files {
            guard let hooks = readJSON(url)?["hooks"] as? [String: Any] else { continue }
            for (event, config) in hooks.sorted(by: { $0.key < $1.key }) {
                let data = (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys])) ?? Data()
                let injects = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse"].contains(event)
                out.append(ContextItem(
                    id: "hook|\(scope)|\(event)",
                    kind: .hook, title: event, scope: scope, path: url.path,
                    content: String(decoding: data, as: UTF8.self), load: .onDemand,
                    note: injects ? "\(event) hooks can add text to the context when they fire." : nil
                ))
            }
        }
        return out
    }

    func readJSON(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

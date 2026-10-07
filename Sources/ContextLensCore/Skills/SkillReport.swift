import Foundation

/// A skill on disk that a harness lists to its sessions.
public struct InstalledSkill: Codable, Hashable, Sendable, Identifiable {
    public var id: String { "\(harness)|\(path)" }
    /// The name a session uses: `skill`, or `plugin:skill` for plugin skills.
    public var name: String
    public var harness: String
    /// `User`, `Project`, `System` or `Plugin <name>`.
    public var scope: String
    public var path: String
    public var modified: Date?
}

/// A session that used a skill, for jumping to it.
public struct SkillSession: Codable, Hashable, Sendable, Identifiable {
    /// `claude:<id>`, `codex:<id>` or `copilot:<id>`; the same ids Past sessions uses.
    public var id: String
    public var harness: String
    public var file: String
    public var cwd: String
    public var time: Date?
    public var trigger: SkillEvent.Trigger
    public var uses: Int
}

public struct SkillCount: Codable, Hashable, Sendable {
    public var name: String
    public var count: Int
}

public struct SkillStat: Codable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    /// Successful uses. Reads count once per session, and not at all in a session that loaded
    /// the skill another way.
    public var uses: Int
    public var sessions: Int
    public var lastUsed: Date?
    /// Skill tool calls that errored, such as `Unknown skill`. Not counted in `uses`.
    public var failures: Int
    public var triggers: [String: Int]
    public var harnesses: [String: Int]
    /// The top folders by uses, with worktrees folded into their main checkout.
    public var folders: [SkillCount]
    public var installed: [InstalledSkill]
    /// The newest sessions that used the skill.
    public var examples: [SkillSession]
}

/// One skill as a single session used it.
public struct SessionSkill: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var uses: Int
    /// Skill tool calls that errored. Not counted in `uses`.
    public var failures: Int
    public var triggers: [String: Int]
    public var firstUsed: Date?
    /// Whether a skill of this name is installed today.
    public var installed: Bool
}

/// A session and the skills it used, in order of first use.
public struct SessionSkills: Codable, Hashable, Sendable, Identifiable {
    /// The same id Past sessions uses.
    public var id: String
    public var harness: String
    public var file: String
    public var cwd: String
    /// The first prompt for Copilot CLI; the Past sessions title from `SkillUsageScanner.session`.
    public var title: String?
    public var started: Date?
    public var modified: Date
    public var skills: [SessionSkill]
}

public struct SkillReport: Codable, Sendable {
    public var generated: Date
    public var since: Date?
    public var folder: String?
    /// Sessions in the window (after the folder filter).
    public var sessions: Int
    public var skills: [SkillStat]
    /// Installed skills with no use in the window.
    public var unused: [InstalledSkill]
}

/// The skills each harness would list in the given folders: user, plugin and system skills, plus
/// project skills of each folder.
public struct SkillInventory: Sendable {
    public var env: HarnessEnvironment

    public init(env: HarnessEnvironment = .current) {
        self.env = env
    }

    public func installed(folders: [String]) -> [InstalledSkill] {
        var out: [InstalledSkill] = []
        var seen = Set<String>()
        func add(_ items: [ContextItem], harness: String, projectOnly: Bool) {
            for item in items where !projectOnly || item.scope == "Project" {
                guard let path = item.path, seen.insert("\(harness)|\(path)").inserted else { continue }
                var name = item.title
                if harness == "claude", item.scope.hasPrefix("Plugin "), !name.contains(":") {
                    let key = item.scope.dropFirst("Plugin ".count)
                    name = "\(key.split(separator: "@").first ?? key):\(name)"
                }
                out.append(InstalledSkill(name: name, harness: harness, scope: item.scope, path: path, modified: item.modified))
            }
        }
        let claude = ClaudeResolver(env: env)
        let codex = CodexResolver(env: env)
        add(claude.skills(cwd: env.home, git: nil), harness: "claude", projectOnly: false)
        add(codex.skills(cwd: env.home), harness: "codex", projectOnly: false)
        for folder in Set(folders) where !folder.isEmpty && folder != env.home.path && !PrivacyGuard.blocked(folder, home: env.home.path) {
            let dir = URL(filePath: folder)
            guard FileUtil.isDirectory(dir) else { continue }
            add(claude.skills(cwd: dir, git: Git.roots(for: dir)), harness: "claude", projectOnly: true)
            add(codex.skills(cwd: dir), harness: "codex", projectOnly: true)
        }
        for file in FileUtil.skillFiles(under: env.home.appending(path: ".copilot/skills"), maxDepth: 2) {
            guard seen.insert("copilot|\(file.path)").inserted else { continue }
            let text = FileUtil.read(file) ?? ""
            let name = Frontmatter(text).fields["name"] ?? file.deletingLastPathComponent().lastPathComponent
            out.append(InstalledSkill(name: name, harness: "copilot", scope: "User", path: file.path, modified: FileUtil.modified(file)))
        }
        return out
    }
}

public enum SkillReportBuilder {
    /// Folds `repo/.claude/worktrees/x` and similar into the main checkout.
    public static func folder(_ cwd: String) -> String {
        var p = HealthText.mainCheckout(cwd.hasSuffix("/") ? cwd : cwd + "/")
        while p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    public static func inFolder(_ cwd: String, _ folder: String?) -> Bool {
        guard let folder else { return true }
        let f = self.folder(folder)
        let c = self.folder(cwd)
        return c == f || c.hasPrefix(f == "/" ? f : f + "/")
    }

    /// Folders of the sessions in the window, for finding project skills.
    public static func folders(_ files: [SkillFileScan], since: Date?, folder: String?) -> [String] {
        var out = Set<String>()
        for f in files where !f.cwd.isEmpty && (since.map { f.modified >= $0 } ?? true) && inFolder(f.cwd, folder) {
            out.insert(f.cwd)
        }
        if let folder { out.insert(folder) }
        return out.sorted()
    }

    struct Use { var skill: String; var event: SkillEvent; var file: SkillFileScan }

    /// Every counted use, under the installed skill's name, and the sessions in the window.
    static func uses(files: [SkillFileScan], installed: [InstalledSkill], since: Date?, folder: String?) -> (uses: [Use], sessions: Set<String>) {
        // A slash command is a skill only when the name is known to be one; `/model`, `/clear` and
        // custom commands are not.
        var known = Set(installed.map(\.name))
        for f in files {
            known.formUnion(f.invoked)
            for e in f.events where e.trigger != .user && !e.failed { known.insert(e.skill) }
        }
        var byPath: [String: String] = [:]
        // Claude Code invokes a skill by its folder name even when the frontmatter `name` differs.
        var byFolder: [String: Set<String>] = [:]
        let names = Set(installed.map(\.name))
        for s in installed {
            byPath[s.path] = s.name
            byPath[FileUtil.realPath(URL(filePath: s.path)).path] = s.name
            let dir = URL(filePath: s.path).deletingLastPathComponent().lastPathComponent
            let plugin = s.name.split(separator: ":").first.map(String.init)
            for alias in [dir, plugin.map { "\($0):\(dir)" } ?? dir] where !names.contains(alias) {
                byFolder[alias, default: []].insert(s.name)
            }
        }
        func canonical(_ e: SkillEvent) -> String {
            if let path = e.path, let name = byPath[path] ?? byPath[FileUtil.realPath(URL(filePath: path)).path] { return name }
            if let match = byFolder[e.skill], match.count == 1 { return match.first! }
            return e.skill
        }

        var uses: [Use] = []
        var sessions = Set<String>()
        for f in files where inFolder(f.cwd, folder) {
            var inWindow = false
            var loaded = Set<String>()
            var read = Set<String>()
            var fileUses: [Use] = []
            for var e in f.events {
                if let since, (e.time ?? f.modified) < since { continue }
                inWindow = true
                if e.trigger == .user, f.harness == "claude", !known.contains(e.skill), byFolder[e.skill] == nil { continue }
                e.skill = canonical(e)
                if e.trigger == .read {
                    if !read.insert(e.skill).inserted { continue }
                } else if !e.failed {
                    loaded.insert(e.skill)
                }
                fileUses.append(Use(skill: e.skill, event: e, file: f))
            }
            // A session that loaded the skill and then read its SKILL.md used it once, not twice.
            uses += fileUses.filter { $0.event.trigger != .read || !loaded.contains($0.skill) }
            if inWindow || since.map({ f.modified >= $0 }) ?? true { sessions.insert(f.session) }
        }
        // Reads are once per session across a parent and its subagent files too.
        var seenReads = Set<String>()
        uses = uses.filter { $0.event.trigger != .read || seenReads.insert("\($0.file.session)|\($0.skill)").inserted }
        return (uses, sessions)
    }

    public static func build(files: [SkillFileScan], installed: [InstalledSkill], since: Date?, folder: String?,
                             now: Date = Date(), examples: Int = 8) -> SkillReport {
        let (uses, sessions) = self.uses(files: files, installed: installed, since: since, folder: folder)
        let installedByName = Dictionary(grouping: installed, by: \.name)
        var stats: [SkillStat] = []
        for (name, group) in Dictionary(grouping: uses, by: \.skill) {
            let ok = group.filter { !$0.event.failed }
            var triggers: [String: Int] = [:]
            var harnesses: [String: Int] = [:]
            var folders: [String: Int] = [:]
            for u in ok {
                triggers[u.event.trigger.rawValue, default: 0] += 1
                harnesses[u.event.harness, default: 0] += 1
                if !u.file.cwd.isEmpty { folders[self.folder(u.file.cwd), default: 0] += 1 }
            }
            var bySession: [String: SkillSession] = [:]
            for u in ok {
                let t = u.event.time ?? u.file.modified
                if var s = bySession[u.file.session] {
                    s.uses += 1
                    if t >= (s.time ?? .distantPast) { s.time = t; s.trigger = u.event.trigger }
                    bySession[u.file.session] = s
                } else {
                    bySession[u.file.session] = SkillSession(id: u.file.session, harness: u.file.harness, file: u.file.file,
                                                             cwd: u.file.cwd, time: t, trigger: u.event.trigger, uses: 1)
                }
            }
            stats.append(SkillStat(
                name: name, uses: ok.count, sessions: bySession.count,
                lastUsed: ok.compactMap { $0.event.time ?? $0.file.modified }.max(),
                failures: group.count - ok.count, triggers: triggers, harnesses: harnesses,
                folders: folders.map { SkillCount(name: $0.key, count: $0.value) }
                    .sorted { ($0.count, $1.name) > ($1.count, $0.name) }.prefix(5).map { $0 },
                installed: installedByName[name] ?? [],
                examples: bySession.values.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }.prefix(examples).map { $0 }
            ))
        }
        stats.sort { ($0.uses, $1.name) > ($1.uses, $0.name) }
        let used = Set(stats.filter { $0.uses > 0 }.map(\.name))
        let unused = installed.filter { !used.contains($0.name) }
            .sorted { ($0.name, $0.harness, $0.path) < ($1.name, $1.harness, $1.path) }
        return SkillReport(generated: now, since: since, folder: folder, sessions: sessions.count, skills: stats, unused: unused)
    }

    /// Sessions active in the window, newest first, each with every skill it used. A session that
    /// started before the window keeps its earlier uses.
    public static func sessions(files: [SkillFileScan], installed: [InstalledSkill], since: Date?, folder: String?) -> [SessionSkills] {
        let active = Set(files.filter { f in inFolder(f.cwd, folder) && (since.map { f.modified >= $0 } ?? true) }.map(\.session))
        let mine = files.filter { active.contains($0.session) }
        let names = Set(installed.map(\.name))
        let usesBySession = Dictionary(grouping: uses(files: mine, installed: installed, since: nil, folder: nil).uses, by: \.file.session)
        var out: [SessionSkills] = []
        for (id, group) in Dictionary(grouping: mine, by: \.session) {
            var skills: [SessionSkill] = []
            for (name, u) in Dictionary(grouping: usesBySession[id] ?? [], by: \.skill) {
                let ok = u.filter { !$0.event.failed }
                var triggers: [String: Int] = [:]
                for x in ok { triggers[x.event.trigger.rawValue, default: 0] += 1 }
                skills.append(SessionSkill(
                    name: name, uses: ok.count, failures: u.count - ok.count, triggers: triggers,
                    firstUsed: u.compactMap(\.event.time).min(), installed: names.contains(name)
                ))
            }
            skills.sort { ($0.firstUsed ?? .distantFuture, $0.name) < ($1.firstUsed ?? .distantFuture, $1.name) }
            out.append(SessionSkills(
                id: id, harness: group[0].harness, file: group[0].file, cwd: group.first { !$0.cwd.isEmpty }?.cwd ?? "",
                title: group.compactMap(\.title).first, started: group.compactMap(\.started).min(),
                modified: group.map(\.modified).max() ?? group[0].modified, skills: skills
            ))
        }
        return out.sorted { ($0.modified, $0.id) > ($1.modified, $1.id) }
    }
}

extension SkillUsageScanner {
    /// One session's skills. `query` is a transcript path, a session id such as `claude:<id>`, or
    /// a bare id or unique prefix of one.
    public func session(_ query: String) -> SessionSkills? {
        let files = scan().files
        var ids = Set<String>()
        if query.contains("/") {
            let path = FileUtil.realPath(URL(filePath: NSString(string: query).expandingTildeInPath)).path
            ids = Set(files.filter { $0.file == path || $0.file.hasPrefix(path + "/") }.map(\.session))
        }
        if ids.isEmpty { ids = Set(files.filter { $0.session == query }.map(\.session)) }
        if ids.isEmpty { ids = Set(files.filter { ($0.session.split(separator: ":").last ?? "").hasPrefix(query) }.map(\.session)) }
        guard ids.count == 1 else { return nil }
        guard var out = session(files: files.filter { ids.contains($0.session) }) else { return nil }
        if out.title == nil {
            let index = SessionIndex(env: env)
            let file = URL(filePath: out.file)
            out.title = out.harness == "claude" ? index.claudeSummary(file)?.title
                : out.harness == "codex" ? index.codexSummary(file, names: index.codexThreadNames())?.title : nil
        }
        return out
    }

    /// The skills of the session in these files, with installed skills looked up for its folder.
    public func session(files: [SkillFileScan]) -> SessionSkills? {
        let installed = SkillInventory(env: env).installed(folders: Array(Set(files.map(\.cwd).filter { !$0.isEmpty })))
        return SkillReportBuilder.sessions(files: files, installed: installed, since: nil, folder: nil).first
    }

    /// Scans transcripts (from the cache where unchanged) and builds the report.
    public func report(since: Date?, folder: String?) -> SkillReport {
        let files = scan(since: since).files
        let installed = SkillInventory(env: env).installed(folders: SkillReportBuilder.folders(files, since: since, folder: folder))
        return SkillReportBuilder.build(files: files, installed: installed, since: since, folder: folder)
    }
}

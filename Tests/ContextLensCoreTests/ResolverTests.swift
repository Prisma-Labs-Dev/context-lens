import Foundation
import Testing
@testable import ContextLensCore

/// A throwaway home and project tree that mirrors the experiment in docs/harness-rules.md.
struct Fixture {
    let root: URL
    let home: URL
    let project: URL

    init() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "context-lens-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base.appending(path: "home/code/app/.git"), withIntermediateDirectories: true)
        root = FileUtil.realPath(base)
        home = root.appending(path: "home")
        project = root.appending(path: "home/code/app")
    }

    func write(_ relative: String, _ text: String, base: URL? = nil) throws {
        let url = (base ?? root).appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var env: HarnessEnvironment {
        HarnessEnvironment(home: home, managedClaudeMd: root.appending(path: "managed/CLAUDE.md"))
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Suite struct ClaudeResolverTests {
    @Test func loadsClaudeFilesAndShadowsAgentsMd() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".claude/CLAUDE.md", "user rules", base: f.home)
        try f.write("CLAUDE.md", "root claude. See @docs/imported.md", base: f.project)
        try f.write("docs/imported.md", "imported text", base: f.project)
        try f.write("AGENTS.md", "root agents", base: f.project)
        try f.write("CLAUDE.local.md", "local", base: f.project)
        try f.write(".claude/rules/always.md", "always rule", base: f.project)
        try f.write(".claude/rules/swift.md", "---\npaths:\n  - \"**/*.swift\"\n---\nswift rule", base: f.project)
        try f.write("sub/AGENTS.md", "sub agents", base: f.project)
        try f.write("sub/deeper/CLAUDE.md", "deeper", base: f.project)

        let snap = ClaudeResolver(env: f.env).resolve(cwd: f.project.appending(path: "sub"))
        func item(_ suffix: String) -> ContextItem? { snap.items.first { $0.path?.hasSuffix(suffix) == true } }

        #expect(item("home/.claude/CLAUDE.md")?.load == .always)
        #expect(item("app/CLAUDE.md")?.load == .always)
        #expect(item("app/CLAUDE.local.md")?.scope == "Local")
        #expect(item("rules/always.md")?.load == .always)
        #expect(item("rules/swift.md")?.load == .onDemand)
        #expect(item("docs/imported.md")?.kind == .imported)
        #expect(item("app/AGENTS.md")?.load == .inactive)
        #expect(item("sub/AGENTS.md")?.load == .inactive)
        #expect(item("deeper/CLAUDE.md")?.load == .onDemand)
    }

    @Test func fallsBackToAgentsMdWithoutClaudeFiles() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("AGENTS.md", "root agents", base: f.project)
        try f.write("sub/AGENTS.md", "sub agents", base: f.project)

        let snap = ClaudeResolver(env: f.env).resolve(cwd: f.project.appending(path: "sub"))
        let agents = snap.items.filter { $0.path?.hasSuffix("AGENTS.md") == true }
        #expect(agents.count == 2)
        #expect(agents.allSatisfy { $0.load == .always })
    }

    @Test func importedAgentsMdIsLoaded() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("CLAUDE.md", "@AGENTS.md", base: f.project)
        try f.write("AGENTS.md", "shared rules", base: f.project)

        let snap = ClaudeResolver(env: f.env).resolve(cwd: f.project)
        let agents = snap.items.filter { $0.path?.hasSuffix("app/AGENTS.md") == true }
        #expect(agents.map(\.kind) == [.imported])
        #expect(agents.first?.load == .always)
    }

    @Test func pathScopedRuleAloneDisablesAgentsFallback() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".claude/rules/swift.md", "---\npaths:\n  - \"**/*.swift\"\n---\nswift rule", base: f.project)
        try f.write("AGENTS.md", "root agents", base: f.project)

        let snap = ClaudeResolver(env: f.env).resolve(cwd: f.project)
        #expect(snap.items.first { $0.path?.hasSuffix("AGENTS.md") == true }?.load == .inactive)
    }

    @Test func skipsMainRepoDirsForNestedWorktree() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let worktree = f.project.appending(path: ".claude/worktrees/wt")
        try f.write("CLAUDE.md", "main repo copy", base: f.project)
        try f.write("CLAUDE.md", "worktree copy", base: worktree)
        try f.write(".git", "gitdir: \(f.project.path)/.git/worktrees/wt\n", base: worktree)

        let snap = ClaudeResolver(env: f.env).resolve(cwd: worktree)
        let claudeMds = snap.items.filter { $0.path?.hasSuffix("/CLAUDE.md") == true && $0.scope == "Project" }
        #expect(claudeMds.map(\.content) == ["worktree copy"])
    }

    @Test func autoMemoryUsesMainRepoSlug() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let slug = ClaudePaths.slug(f.project.path)
        try f.write(".claude/projects/\(slug)/memory/MEMORY.md", "- [Note](note.md)", base: f.home)
        try f.write(".claude/projects/\(slug)/memory/note.md", "a note", base: f.home)

        let snap = ClaudeResolver(env: f.env).resolve(cwd: f.project)
        let memory = snap.items.filter { $0.kind == .memory }
        #expect(memory.first { $0.path?.hasSuffix("MEMORY.md") == true }?.load == .always)
        #expect(memory.first { $0.path?.hasSuffix("note.md") == true }?.load == .onDemand)
    }

    @Test func listsSkillsByDescription() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".claude/skills/demo/SKILL.md", "---\nname: demo\ndescription: Does demo things\n---\nbody", base: f.home)
        try f.write(".claude/skills/demo/SKILL.md", "---\nname: demo\ndescription: Project copy\n---\nbody", base: f.project)

        let skills = ClaudeResolver(env: f.env).resolve(cwd: f.project).items.filter { $0.kind == .skill }
        #expect(skills.count == 2)
        #expect(skills.filter { $0.load == .listing }.map(\.content) == ["- demo: Does demo things"])
    }

    @Test func slugMatchesClaudeCode() {
        #expect(ClaudePaths.slug("/Users/me/repos/.claude/worktrees/x-1") == "-Users-me-repos--claude-worktrees-x-1")
    }
}

@Suite struct CodexResolverTests {
    @Test func concatenatesFromGitRootAndIgnoresClaudeMd() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".codex/AGENTS.md", "global", base: f.home)
        try f.write("AGENTS.md", "root agents", base: f.project)
        try f.write("CLAUDE.md", "root claude", base: f.project)
        try f.write("sub/AGENTS.override.md", "sub override", base: f.project)
        try f.write("sub/AGENTS.md", "sub agents", base: f.project)
        try f.write(".agents/skills/demo/SKILL.md", "---\nname: demo\ndescription: Codex demo\n---\n", base: f.project)

        let snap = CodexResolver(env: f.env).resolve(cwd: f.project.appending(path: "sub"))
        let loaded = snap.items.filter { $0.kind == .instructions }.map(\.content)
        #expect(loaded == ["global", "root agents", "sub override"])
        #expect(snap.items.contains { $0.path?.hasSuffix("sub/AGENTS.md") == true && $0.load == .inactive })
        #expect(!snap.items.contains { $0.path?.hasSuffix("CLAUDE.md") == true })
        #expect(snap.items.contains { $0.kind == .skill && $0.title == "demo" && $0.load == .listing })
    }

    @Test func honorsByteBudget() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".codex/config.toml", "project_doc_max_bytes = 10 # small\nproject_doc_fallback_filenames = [\n  \"TEAM.md\",\n]\n[features]\nmemories = true # on\n[mcp_servers.docs]\nurl = \"x\"\n[mcp_servers.docs.env]\nA = \"b\"\n", base: f.home)
        try f.write("AGENTS.md", "0123456789ABCDEF", base: f.project)
        try f.write("sub/AGENTS.md", "dropped", base: f.project)
        try f.write(".codex/memories/memory_summary.md", "summary", base: f.home)

        let snap = CodexResolver(env: f.env).resolve(cwd: f.project.appending(path: "sub"))
        let root = snap.items.first { $0.path?.hasSuffix("app/AGENTS.md") == true }
        #expect(root?.content == "0123456789")
        #expect(root?.issues.first?.kind == .truncated)
        #expect(snap.items.first { $0.path?.hasSuffix("sub/AGENTS.md") == true }?.load == .inactive)
        #expect(snap.items.first { $0.kind == .memory }?.load == .always)
        #expect(snap.items.filter { $0.kind == .mcp }.map(\.title) == ["docs"])
    }
}

@Suite struct CodexConfigTests {
    @Test func handlesCommentsAndMultilineArrays() {
        let config = CodexConfig(text: """
        project_doc_max_bytes = 2048 # tighter
        project_doc_fallback_filenames = [
          "TEAM.md", # shared
          "README-agents.md",
        ]
        [features]
        memories = true # on
        [plugins."docs@market"]
        enabled = false
        """)
        #expect(config.projectDocMaxBytes == 2048)
        #expect(config.fallbackFilenames == ["TEAM.md", "README-agents.md"])
        #expect(config.memoriesEnabled)
        #expect(config.disabledPlugins == ["docs@market"])
    }
}

@Suite struct ReferenceCheckerTests {
    @Test func flagsMissingPathsOnly() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("repos/real/README.md", "x", base: f.home)
        let text = """
        Use `~/repos/real` and \(f.home.path)/repos/real/README.md.
        The old template at ~/repos/macos-template is gone.
        Ignore /Users/someone-else/thing and ~/path/to/example.
        Also ~/Pictures/shots/YYYY-MM-DD/, ~/Library/Build/WebDriverAgent-, /tmp/scratch-1 and ~/.config/some-service-token.
        """
        #expect(ReferenceChecker.missingPaths(in: text, home: f.home) == ["~/repos/macos-template"])
    }

    @Test func keepsApplicationSupportTogether() {
        let paths = ReferenceChecker.referencedPaths(in: "See /Library/Application Support/ClaudeCode/CLAUDE.md now", home: URL(filePath: "/Users/me"))
        #expect(paths == ["/Library/Application Support/ClaudeCode/CLAUDE.md"])
    }
}

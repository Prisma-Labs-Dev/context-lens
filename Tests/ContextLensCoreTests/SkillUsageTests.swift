import Foundation
import Testing
@testable import ContextLensCore

@Suite struct SkillPathTests {
    @Test func namesSkillsFromPaths() {
        #expect(SkillPaths.name("/Users/me/.claude/skills/brew-tea/SKILL.md") == "brew-tea")
        #expect(SkillPaths.name("/Users/me/.codex/skills/.system/pick-font/SKILL.md") == "pick-font")
        #expect(SkillPaths.name("/Users/me/.claude/plugins/cache/acme-market/garden/1.2.0/skills/prune/SKILL.md") == "garden:prune")
        #expect(SkillPaths.name("/Users/me/.claude/plugins/marketplaces/acme-market/plugins/garden/skills/prune/SKILL.md") == "garden:prune")
        #expect(SkillPaths.name("/Users/me/.claude/scheduled-tasks/nightly/SKILL.md") == nil)
        #expect(SkillPaths.name("/Users/me/notes/SKILL.md.bak") == nil)
    }

    @Test func countsOnlyReaders() {
        #expect(SkillPaths.reads(inCommand: "cat ~/.claude/skills/brew-tea/SKILL.md") == ["~/.claude/skills/brew-tea/SKILL.md"])
        #expect(SkillPaths.reads(inCommand: "cd /x && sed -n 1,80p /Users/me/.agents/skills/brew-tea/SKILL.md | head") == ["/Users/me/.agents/skills/brew-tea/SKILL.md"])
        #expect(SkillPaths.reads(inCommand: "cat \"$HOME/.codex/skills/brew-tea/SKILL.md\" 2>/dev/null") == ["$HOME/.codex/skills/brew-tea/SKILL.md"])
        // Writes, edits, searches, remote files and repo-relative paths are not uses.
        #expect(SkillPaths.reads(inCommand: "cat >> ~/.claude/skills/brew-tea/SKILL.md").isEmpty)
        #expect(SkillPaths.reads(inCommand: "sed -i '' s/a/b/ ~/.claude/skills/brew-tea/SKILL.md").isEmpty)
        #expect(SkillPaths.reads(inCommand: "rg -g 'SKILL.md' tea ~/.claude/skills").isEmpty)
        #expect(SkillPaths.reads(inCommand: "gh api repos/acme/x/contents/skills/brew-tea/SKILL.md").isEmpty)
        #expect(SkillPaths.reads(inCommand: "head -5 packages/kit/skills/brew-tea/SKILL.md").isEmpty)
        #expect(SkillPaths.reads(inCommand: "cat ~/.claude/skills/*/SKILL.md").isEmpty)
    }
}

/// A throwaway home with Claude Code, Codex and Copilot CLI transcripts.
struct SkillFixture {
    let f: Fixture
    var home: URL { f.home }
    var cache: URL { f.root.appending(path: "cache/scan.json") }
    let now = Date()

    init() throws {
        f = try Fixture()
        // Installed: two user skills, one plugin skill, one Codex skill, one project skill.
        try skill(".claude/skills/brew-tea", name: "brew-tea")
        try skill(".claude/skills/water-plants", name: "water-plants")
        try skill(".claude/skills/fold-towels", name: "Fold Towels")
        try skill(".codex/skills/pick-font", name: "pick-font")
        try f.write(".claude/skills/sort-mail/SKILL.md", "---\nname: sort-mail\n---\n", base: f.project)
        try f.write(".claude/settings.json", #"{"enabledPlugins":{"garden@acme-market":true}}"#, base: home)
        let pluginPath = home.appending(path: ".claude/plugins/cache/acme-market/garden/1.2.0")
        try f.write(".claude/plugins/installed_plugins.json",
                    #"{"plugins":{"garden@acme-market":[{"installPath":"\#(pluginPath.path)"}]}}"#, base: home)
        try skill(".claude/plugins/cache/acme-market/garden/1.2.0/skills/prune", name: "prune")
    }

    func skill(_ dir: String, name: String) throws {
        try f.write("\(dir)/SKILL.md", "---\nname: \(name)\ndescription: test\n---\nbody", base: home)
    }

    func ts(_ daysAgo: Double) -> String {
        ISO8601DateFormatter().string(from: now.addingTimeInterval(-daysAgo * 86400))
    }

    func json(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func assistant(_ tools: [[String: Any]], daysAgo: Double = 1) -> String {
        json(["type": "assistant", "timestamp": ts(daysAgo), "cwd": f.project.path,
              "message": ["role": "assistant", "content": tools.map { ["type": "tool_use"].merging($0) { $1 } }]])
    }

    func user(_ content: Any, daysAgo: Double = 1) -> String {
        json(["type": "user", "timestamp": ts(daysAgo), "cwd": f.project.path, "message": ["role": "user", "content": content]])
    }

    func writeClaude() throws {
        let project = ".claude/projects/-Users-me-code-app"
        let lines = [
            // The listing in the system prompt is not a use.
            user("The following skills are available: brew-tea, water-plants, prune, sort-mail"),
            assistant([["id": "t1", "name": "Skill", "input": ["skill": "brew-tea"]]]),
            user([["type": "tool_result", "tool_use_id": "t1", "content": "Launching skill: brew-tea"]]),
            assistant([["id": "t2", "name": "Skill", "input": ["skill": "garden:prune"]]]),
            assistant([["id": "t3", "name": "Skill", "input": ["skill": "garden:missing"]]]),
            user([["type": "tool_result", "tool_use_id": "t3", "is_error": true,
                   "content": "<tool_use_error>Unknown skill: garden:missing</tool_use_error>"]]),
            // A slash command for a skill counts; built-ins and pasted text do not.
            user("<command-message>sort-mail</command-message>\n<command-name>/sort-mail</command-name>"),
            user("<command-message>model</command-message>\n<command-name>/model</command-name>"),
            user("look at this: <command-name>/water-plants</command-name>"),
            // Read twice in one session: one use. Writing the file is not a use.
            assistant([["id": "t4", "name": "Read", "input": ["file_path": home.path + "/.claude/skills/water-plants/SKILL.md"]]]),
            assistant([["id": "t5", "name": "Bash", "input": ["command": "cat ~/.claude/skills/water-plants/SKILL.md"]]]),
            assistant([["id": "t6", "name": "Write", "input": ["file_path": home.path + "/.claude/skills/pick-font/SKILL.md", "content": "x"]]]),
            // Invoked by folder name although the frontmatter name differs.
            assistant([["id": "t7", "name": "Skill", "input": ["skill": "fold-towels"]]]),
            // Outside a 7-day window.
            assistant([["id": "t8", "name": "Skill", "input": ["skill": "brew-tea"]]], daysAgo: 20),
        ]
        try f.write("\(project)/s1.jsonl", lines.joined(separator: "\n") + "\n", base: home)
        let sub = [assistant([["id": "a1", "name": "Skill", "input": ["skill": "brew-tea"]]])]
        try f.write("\(project)/s1/subagents/agent-1.jsonl", sub.joined(separator: "\n") + "\n", base: home)
    }

    func writeCodex() throws {
        let skillPath = home.path + "/.codex/skills/pick-font/SKILL.md"
        let lines = [
            json(["type": "session_meta", "timestamp": ts(2), "payload": ["id": "x", "cwd": f.project.path]]),
            // The instructions list skill paths; that is not a use.
            json(["type": "response_item", "timestamp": ts(2), "payload": ["type": "message", "role": "developer",
                  "content": [["type": "input_text", "text": "- pick-font: fonts (file: \(skillPath))"]]]]),
            json(["type": "response_item", "timestamp": ts(2), "payload": ["type": "custom_tool_call", "name": "exec",
                  "input": "const r = await tools.exec_command({cmd:\"sed -n '1,200p' \(skillPath)\", yield_time_ms: 1000});"]]),
            json(["type": "response_item", "timestamp": ts(2), "payload": ["type": "custom_tool_call", "name": "apply_patch",
                  "input": "*** Begin Patch\n*** Update File: \(skillPath)\n"]]),
        ]
        try f.write(".codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-01a0e1e8-87be-7593-a572-c77c2bd250c5.jsonl",
                    lines.joined(separator: "\n") + "\n", base: home)
    }

    func writeCopilot() throws {
        let lines = [
            json(["type": "session.start", "timestamp": ts(3), "data": ["context": ["cwd": f.project.path]]]),
            json(["type": "user.message", "timestamp": ts(3), "data": ["content": "Brew some tea\nthen rest"]]),
            json(["type": "skill.invoked", "timestamp": ts(3), "data": ["name": "brew-tea", "trigger": "user-invoked",
                  "path": home.path + "/.copilot/skills/brew-tea/SKILL.md"]]),
        ]
        try f.write(".copilot/session-state/cp-1/events.jsonl", lines.joined(separator: "\n") + "\n", base: home)
    }
}

@Suite struct SkillUsageTests {
    @Test func countsUsesAcrossHarnesses() throws {
        let s = try SkillFixture()
        defer { s.f.cleanup() }
        try s.writeClaude()
        try s.writeCodex()
        try s.writeCopilot()
        let scanner = SkillUsageScanner(env: s.f.env, cacheFile: s.cache)
        let report = scanner.report(since: s.now.addingTimeInterval(-7 * 86400), folder: nil)
        let stats = Dictionary(uniqueKeysWithValues: report.skills.map { ($0.name, $0) })

        let tea = try #require(stats["brew-tea"])
        #expect(tea.uses == 3)
        #expect(tea.triggers == ["model": 1, "subagent": 1, "user": 1])
        #expect(tea.harnesses == ["claude": 2, "copilot": 1])
        #expect(tea.sessions == 2)
        // The subagent belongs to its parent session and opens the parent transcript.
        let claudeSession = try #require(tea.examples.first { $0.harness == "claude" })
        #expect(claudeSession.id == "claude:s1")
        #expect(claudeSession.file.hasSuffix("-Users-me-code-app/s1.jsonl"))
        #expect(claudeSession.uses == 2)
        #expect(tea.folders.first?.name == s.f.project.path)

        #expect(stats["garden:prune"]?.uses == 1)
        #expect(stats["garden:missing"]?.uses == 0)
        #expect(stats["garden:missing"]?.failures == 1)
        #expect(stats["sort-mail"]?.triggers == ["user": 1])
        #expect(stats["model"] == nil)
        #expect(stats["water-plants"]?.uses == 1)
        #expect(stats["water-plants"]?.triggers == ["read": 1])
        #expect(stats["Fold Towels"]?.uses == 1)
        #expect(stats["pick-font"]?.triggers == ["read": 1])
        #expect(stats["pick-font"]?.harnesses == ["codex": 1])

        // Installed and used by nobody in the window: nothing here, since every skill had a use.
        #expect(report.unused.isEmpty)
        #expect(report.sessions == 3)
    }

    @Test func listsUnusedAndAppliesWindow() throws {
        let s = try SkillFixture()
        defer { s.f.cleanup() }
        try s.writeClaude()
        let scanner = SkillUsageScanner(env: s.f.env, cacheFile: s.cache)
        let report = scanner.report(since: s.now.addingTimeInterval(-7 * 86400), folder: nil)
        let unused = Set(report.unused.map(\.name))
        #expect(unused == ["pick-font"])
        let tea = report.skills.first { $0.name == "brew-tea" }
        #expect(tea?.uses == 2)

        let all = scanner.report(since: nil, folder: nil)
        #expect(all.skills.first { $0.name == "brew-tea" }?.uses == 3)

        let elsewhere = scanner.report(since: nil, folder: s.home.appending(path: "other").path)
        #expect(elsewhere.skills.isEmpty)
        #expect(Set(elsewhere.unused.map(\.name)).isSuperset(of: ["brew-tea", "garden:prune"]))
        #expect(!elsewhere.unused.contains { $0.name == "sort-mail" })
    }

    @Test func reusesCacheUntilFileChanges() throws {
        let s = try SkillFixture()
        defer { s.f.cleanup() }
        try s.writeClaude()
        let scanner = SkillUsageScanner(env: s.f.env, cacheFile: s.cache)
        let first = scanner.scan()
        #expect(first.parsed == 2 && first.cached == 0)
        let second = scanner.scan()
        #expect(second.parsed == 0 && second.cached == 2)
        #expect(second.files.flatMap(\.events).count == first.files.flatMap(\.events).count)

        let file = s.home.appending(path: ".claude/projects/-Users-me-code-app/s1.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data((s.assistant([["id": "t9", "name": "Skill", "input": ["skill": "water-plants"]]]) + "\n").utf8))
        try handle.close()
        let third = scanner.scan()
        #expect(third.parsed == 1 && third.cached == 1)
    }

    @Test func listsSkillsPerSession() throws {
        let s = try SkillFixture()
        defer { s.f.cleanup() }
        try s.writeClaude()
        try s.writeCodex()
        try s.writeCopilot()
        let scanner = SkillUsageScanner(env: s.f.env, cacheFile: s.cache)
        let files = scanner.scan().files
        let installed = SkillInventory(env: s.f.env).installed(folders: [s.f.project.path])
        let sessions = SkillReportBuilder.sessions(files: files, installed: installed,
                                                   since: s.now.addingTimeInterval(-7 * 86400), folder: nil)
        #expect(Set(sessions.map(\.id)) == ["claude:s1", "codex:01a0e1e8-87be-7593-a572-c77c2bd250c5", "copilot:cp-1"])

        // The whole session counts, including the use from before the window, and its subagent.
        let claude = try #require(sessions.first { $0.id == "claude:s1" })
        let skills = Dictionary(uniqueKeysWithValues: claude.skills.map { ($0.name, $0) })
        #expect(claude.skills.first?.name == "brew-tea")
        #expect(skills["brew-tea"]?.uses == 3)
        #expect(skills["brew-tea"]?.triggers == ["model": 2, "subagent": 1])
        #expect(skills["sort-mail"]?.triggers == ["user": 1])
        #expect(skills["sort-mail"]?.installed == true)
        #expect(skills["garden:missing"]?.failures == 1)
        #expect(skills["garden:missing"]?.installed == false)
        #expect(skills["water-plants"]?.uses == 1)
        #expect(skills["model"] == nil)
        #expect(claude.cwd == s.f.project.path)
        #expect(claude.started != nil)

        let copilot = try #require(sessions.first { $0.id == "copilot:cp-1" })
        #expect(copilot.title == "Brew some tea")
        #expect(copilot.skills.map(\.name) == ["brew-tea"])

        // Only sessions in the folder.
        let elsewhere = SkillReportBuilder.sessions(files: files, installed: installed, since: nil,
                                                    folder: s.home.appending(path: "other").path)
        #expect(elsewhere.isEmpty)
    }

    @Test func findsOneSessionByIdOrPath() throws {
        let s = try SkillFixture()
        defer { s.f.cleanup() }
        try s.writeClaude()
        try s.writeCodex()
        try s.writeCopilot()
        let scanner = SkillUsageScanner(env: s.f.env, cacheFile: s.cache)
        #expect(scanner.session("claude:s1")?.skills.count == 6)
        #expect(scanner.session("claude:s1")?.title != nil)
        #expect(scanner.session("01a0e1e8")?.skills.map(\.name) == ["pick-font"])
        #expect(scanner.session("cp-1")?.id == "copilot:cp-1")
        let path = s.home.appending(path: ".claude/projects/-Users-me-code-app/s1.jsonl").path
        #expect(scanner.session(path)?.id == "claude:s1")
        // Read directly, as the session view does: the subagent is included.
        let direct = scanner.session(files: scanner.scan(transcript: URL(filePath: path), harness: "claude"))
        #expect(direct?.skills.first { $0.name == "brew-tea" }?.triggers == ["model": 2, "subagent": 1])
        #expect(scanner.session("nothing-like-this") == nil)
    }

    @Test func followsSymlinkedSkillsFolder() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("dotfiles/skills/brew-tea/SKILL.md", "---\nname: brew-tea\n---\n")
        try FileManager.default.createDirectory(at: f.home.appending(path: ".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.home.appending(path: ".claude/skills"),
                                                   withDestinationURL: f.root.appending(path: "dotfiles/skills"))
        let installed = SkillInventory(env: f.env).installed(folders: [])
        #expect(installed.map(\.name) == ["brew-tea"])
    }
}

import Foundation
import Testing
@testable import ContextLensCore

@Suite struct PresetTests {
    func fixture() throws -> (Fixture, PresetStore) {
        let f = try Fixture()
        try f.write(".claude/CLAUDE.md", "user rules", base: f.home)
        try f.write(".claude/skills/alpha/SKILL.md", "---\nname: alpha\ndescription: A\n---\n", base: f.home)
        try f.write(".claude/skills/beta/SKILL.md", "---\nname: beta\ndescription: B\n---\n", base: f.home)
        try f.write("CLAUDE.md", "project rules", base: f.project)
        try f.write(".codex/AGENTS.md", "global agents", base: f.home)
        try f.write(".codex/auth.json", "{}", base: f.home)
        try f.write(".codex/config.toml", "model = \"m\"\n[mcp_servers.docs]\nurl = \"x\"\n[projects.\"/a\"]\ntrust_level = \"trusted\"\n", base: f.home)
        try f.write("AGENTS.md", "project agents", base: f.project)
        try f.write(".agents/skills/gamma/SKILL.md", "---\nname: gamma\ndescription: G\n---\n", base: f.project)
        return (f, PresetStore(root: f.root.appending(path: "store")))
    }

    @Test func seedsExamplesOnce() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let ids = store.all().map(\.id)
        #expect(ids.prefix(2) == ["clean-install", "on-disk"])
        #expect(Set(ids).isSuperset(of: ["autonomous", "careful", "lean"]))
        store.delete(store.preset(id: "careful")!)
        #expect(store.preset(id: "careful") == nil)
    }

    @Test func appliesTogglesAndReplacement() throws {
        let (f, _) = try fixture()
        defer { f.cleanup() }
        var preset = Preset(id: "p", name: "P", instructionsMode: .replace, instructions: "be quick")
        preset.set(PresetKeys.skill("beta"), enabled: false, harness: .claude)
        let snap = ClaudeResolver(env: f.env).resolve(cwd: f.project)
        let applied = PresetApplier.apply(preset, to: snap, env: f.env)
        let user = applied.items.first { $0.path == f.home.appending(path: ".claude/CLAUDE.md").path }
        #expect(user?.load == .inactive)
        #expect(user?.presetOff?.contains("Replaced") == true)
        #expect(applied.items.first { $0.title == "beta" }?.load == .inactive)
        #expect(applied.items.first { $0.title == "alpha" }?.load == .listing)
        #expect(applied.items.contains { $0.scope == "Preset" && $0.content == "be quick" })
        #expect(applied.startingTokens < snap.startingTokens + TokenEstimate.tokens("be quick") + 1)
    }

    @Test func claudePlanWritesSettings() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        var preset = Preset(id: "p", name: "P", instructionsMode: .replace, instructions: "be quick", offGroups: [.memory, .hooks])
        preset.set(PresetKeys.skill("beta"), enabled: false, harness: .claude)
        preset.set(PresetKeys.file(f.project.appending(path: "CLAUDE.md").path), enabled: false, harness: .claude)
        let plan = try PresetLauncher(env: f.env, store: store).plan(preset, harness: .claude, cwd: f.project)
        let settingsPath = try #require(plan.args.firstIndex(of: "--settings").map { plan.args[$0 + 1] })
        let settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: settingsPath))) as? [String: Any])
        let excludes = settings["claudeMdExcludes"] as? [String] ?? []
        #expect(excludes.contains(f.home.appending(path: ".claude/CLAUDE.md").path))
        #expect(excludes.contains(f.project.appending(path: "CLAUDE.md").path))
        #expect((settings["skillOverrides"] as? [String: String]) == ["beta": "off"])
        #expect(settings["autoMemoryEnabled"] as? Bool == false)
        #expect(settings["disableAllHooks"] as? Bool == true)
        #expect(plan.args.contains("--add-dir"))
        #expect(plan.env["CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD"] == "1")
        let dir = try #require(plan.args.firstIndex(of: "--add-dir").map { plan.args[$0 + 1] })
        #expect(try String(contentsOf: URL(filePath: dir).appending(path: "CLAUDE.md"), encoding: .utf8) == "be quick")
    }

    @Test func cleanInstallPlans() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let launcher = PresetLauncher(env: f.env, store: store)
        #expect(try launcher.plan(.cleanInstall, harness: .claude, cwd: f.project).args.first == "--safe-mode")
        let codex = try launcher.plan(.cleanInstall, harness: .codex, cwd: f.project)
        let home = try #require(codex.env["CODEX_HOME"])
        #expect(FileManager.default.fileExists(atPath: home + "/auth.json"))
        #expect(!FileManager.default.fileExists(atPath: home + "/AGENTS.md"))
        let config = try String(contentsOf: URL(filePath: home + "/config.toml"), encoding: .utf8).replacingOccurrences(of: "'", with: "\"")
        #expect(config.contains("model = \"m\""))
        #expect(config.contains("trust_level"))
        #expect(!config.contains("mcp_servers"))
        #expect(codex.args.contains("project_doc_max_bytes=0"))
        #expect(try launcher.plan(.onDisk, harness: .codex, cwd: f.project).args.isEmpty)
    }

    @Test func regeneratingAHomeNeverTouchesLinkedTargets() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        try f.write(".codex/sessions/2026/10/03/rollout-x.jsonl", "{}", base: f.home)
        let launcher = PresetLauncher(env: f.env, store: store)
        _ = try launcher.plan(.cleanInstall, harness: .codex, cwd: f.project)
        _ = try launcher.plan(.cleanInstall, harness: .codex, cwd: f.project)
        let replace = Preset(id: "r", name: "R", instructionsMode: .replace, instructions: "x")
        _ = try launcher.plan(replace, harness: .codex, cwd: f.project)
        _ = try launcher.plan(replace, harness: .codex, cwd: f.project)
        #expect(FileManager.default.fileExists(atPath: f.home.appending(path: ".codex/sessions/2026/10/03/rollout-x.jsonl").path))
        #expect(FileManager.default.fileExists(atPath: f.home.appending(path: ".codex/auth.json").path))
        #expect(try String(contentsOf: f.home.appending(path: ".codex/AGENTS.md"), encoding: .utf8) == "global agents")
    }

    @Test func codexPlanReplacesGlobalAndPlacesFlagsAfterSubcommand() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        var preset = Preset(id: "p", name: "P", instructionsMode: .replace, instructions: "be \"quick\"\nnow")
        preset.set(PresetKeys.skill("gamma"), enabled: false, harness: .codex)
        preset.set(PresetKeys.mcp("docs"), enabled: false, harness: .codex)
        let plan = try PresetLauncher(env: f.env, store: store).plan(preset, harness: .codex, cwd: f.project)
        let home = try #require(plan.env["CODEX_HOME"])
        #expect(try String(contentsOf: URL(filePath: home + "/AGENTS.md"), encoding: .utf8) == "be \"quick\"\nnow")
        #expect(plan.args.contains { $0.hasPrefix("skills.config=[{path=") && $0.contains("gamma/SKILL.md") })
        #expect(plan.args.contains("mcp_servers.docs.enabled=false"))
        let full = plan.arguments(extra: ["exec", "--json", "hi"])
        #expect(full.first == "exec")
        #expect(full.last == "hi")
        #expect(plan.arguments(extra: ["fix the bug"]).last == "fix the bug")
        #expect(plan.arguments(extra: ["fix the bug"]).first == "-c")

        var append = Preset(id: "a", name: "A", instructionsMode: .append, instructions: "line \"one\"")
        append.set(PresetKeys.codexProjectDocs, enabled: false, harness: .codex)
        let plan2 = try PresetLauncher(env: f.env, store: store).plan(append, harness: .codex, cwd: f.project)
        #expect(plan2.env["CODEX_HOME"] == nil)
        #expect(plan2.args.contains("developer_instructions=\"line \\\"one\\\"\""))
        #expect(plan2.args.contains("project_doc_max_bytes=0"))
    }

    @Test func launchLogMatchesSessionsByFolderAndStart() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let log = LaunchLog(store: store)
        log.record(Preset(id: "lean", name: "Lean"), harness: .claude, cwd: f.project)
        let entry = try #require(log.entries().first)
        func session(_ harness: Harness, startedAfter seconds: TimeInterval, cwd: URL) -> SessionSummary {
            SessionSummary(id: "s", harness: harness, file: f.root, title: "t", cwd: cwd.path, date: Date(), sizeBytes: 1,
                           started: entry.date.addingTimeInterval(seconds))
        }
        #expect(LaunchLog.match(session(.claude, startedAfter: 3, cwd: f.project), in: log.entries())?.preset == "lean")
        #expect(LaunchLog.match(session(.codex, startedAfter: 3, cwd: f.project), in: log.entries()) == nil)
        #expect(LaunchLog.match(session(.claude, startedAfter: 3600, cwd: f.project), in: log.entries()) == nil)
        #expect(LaunchLog.match(session(.claude, startedAfter: 3, cwd: f.home), in: log.entries()) == nil)
    }

    @Test func unsafeIDsAreIgnoredAndRefused() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        _ = store.all()
        let evil = #"{"id":"../../.codex","name":"Evil"}"#
        try f.write("store/presets/evil.json", evil)
        #expect(!store.all().contains { $0.name == "Evil" })
        #expect(throws: PresetError.self) { try store.save(Preset(id: "../x", name: "X")) }
        #expect(throws: PresetError.self) { try PresetLauncher(env: f.env, store: store).plan(Preset(id: "a/b", name: "X"), harness: .claude, cwd: f.project) }
        #expect(Preset.isSafeID("lean-2") && !Preset.isSafeID("Lean") && !Preset.isSafeID("..") && !Preset.isSafeID(""))
    }

    @Test func eachLaunchGetsItsOwnDirectory() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let launcher = PresetLauncher(env: f.env, store: store)
        let a = try #require(try launcher.plan(.cleanInstall, harness: .codex, cwd: f.project).env["CODEX_HOME"])
        let b = try #require(try launcher.plan(.cleanInstall, harness: .codex, cwd: f.project).env["CODEX_HOME"])
        #expect(a != b)
        #expect(FileManager.default.fileExists(atPath: a + "/config.toml"))
    }

    @Test func cleanInstallConfigKeepsOnlyAllowlistedSingleLineKeys() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let tripleQuote = String(repeating: "\"", count: 3)
        let config0 = [
            "model = \"m\"",
            "developer_instructions = " + tripleQuote,
            "Be terse.",
            "[Context]",
            tripleQuote,
            "project_doc_max_bytes = 10",
            "[features]",
            "memories = true",
            "[projects.\"/a\"]",
            "trust_level = \"trusted\"",
        ].joined(separator: "\n")
        try f.write(".codex/config.toml", config0, base: f.home)
        let home = try #require(try PresetLauncher(env: f.env, store: store).plan(.cleanInstall, harness: .codex, cwd: f.project).env["CODEX_HOME"])
        let config = try String(contentsOf: URL(filePath: home + "/config.toml"), encoding: .utf8).replacingOccurrences(of: "'", with: "\"")
        #expect(config.contains("model = \"m\""))
        #expect(config.contains("trust_level = \"trusted\""))
        #expect(!config.contains("Be terse"))
        #expect(!config.contains("[Context]"))
        #expect(!config.contains("developer_instructions"))
        #expect(!config.contains("memories"))
    }

    @Test func codexFlagsGoAfterSubcommandEvenWithLeadingOptions() {
        let plan = LaunchPlan(harness: .codex, env: [:], args: ["-c", "x=1"], notes: [])
        #expect(plan.arguments(extra: ["--model", "m", "exec", "task"]) == ["--model", "m", "exec", "-c", "x=1", "task"])
        #expect(plan.arguments(extra: ["--cd", "review", "exec", "task"]) == ["--cd", "review", "exec", "-c", "x=1", "task"])
        #expect(plan.arguments(extra: ["--model=m", "exec"]) == ["--model=m", "exec", "-c", "x=1"])
        #expect(plan.arguments(extra: ["--", "review"]) == ["-c", "x=1", "--", "review"])
        #expect(plan.arguments(extra: ["fix exec bug"]) == ["-c", "x=1", "fix exec bug"])
    }

    @Test func cleanInstallIgnoresSettingsWrittenInsideStrings() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let q3 = String(repeating: "\"", count: 3)
        let a3 = String(repeating: "'", count: 3)
        let text = [
            "model = \"m\"",
            "developer_instructions = " + q3,
            "Example with " + a3 + " quotes:",
            "approval_policy = \"never\"",
            "sandbox_mode = \"danger-full-access\"",
            q3,
        ].joined(separator: "\n")
        try f.write(".codex/config.toml", text, base: f.home)
        let home = try #require(try PresetLauncher(env: f.env, store: store).plan(.cleanInstall, harness: .codex, cwd: f.project).env["CODEX_HOME"])
        let config = try String(contentsOf: URL(filePath: home + "/config.toml"), encoding: .utf8).replacingOccurrences(of: "'", with: "\"")
        #expect(config.contains("model = 'm'") || config.contains("model = \"m\""))
        #expect(!config.contains("approval_policy"))
        #expect(!config.contains("sandbox_mode"))
    }

    @Test func skillMergeReadsAnySyntaxAndForcesOff() throws {
        let alt = CodexConfig(text: "[skills]\nconfig = [{path=\"/a/SKILL.md\",enabled=false},{path=\"/b/SKILL.md\",enabled=true}]\n")
        #expect(alt.skillEntries.count == 2)
        let merged = PresetLauncher.mergedSkillConfig(existing: alt.skillEntries, disabledPaths: ["/b/SKILL.md", "/c/SKILL.md"])
        #expect(merged == "[{path=\"/a/SKILL.md\",enabled=false},{path=\"/b/SKILL.md\",enabled=false},{path=\"/c/SKILL.md\",enabled=false}]")
    }

    @Test func cleanupKeepsDirectoriesOfRunningLaunches() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let launcher = PresetLauncher(env: f.env, store: store)
        let live = try launcher.plan(.cleanInstall, harness: .claude, cwd: f.project)
        live.markInUse(pid: getpid())
        let dead = try launcher.plan(.cleanInstall, harness: .claude, cwd: f.project)
        let old = Date().addingTimeInterval(-30 * 86_400)
        for dir in [live.directory!, dead.directory!] {
            try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.path)
        }
        _ = try launcher.plan(.cleanInstall, harness: .claude, cwd: f.project)
        #expect(FileManager.default.fileExists(atPath: live.directory!.path))
        #expect(!FileManager.default.fileExists(atPath: dead.directory!.path))
    }

    @Test func mcpGroupOffIsStrictEvenWithoutLocalServers() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        let plan = try PresetLauncher(env: f.env, store: store).plan(Preset(id: "m", name: "M", offGroups: [.mcp]), harness: .claude, cwd: f.project)
        #expect(plan.args.contains("--strict-mcp-config"))
    }

    @Test func codexSkillOverrideKeepsUserEntries() throws {
        let (f, store) = try fixture()
        defer { f.cleanup() }
        try f.write(".codex/config.toml", "model = \"m\"\n[[skills.config]]\nname = \"old\"\nenabled = false # mine\n", base: f.home)
        var preset = Preset(id: "s", name: "S")
        preset.set(PresetKeys.skill("gamma"), enabled: false, harness: .codex)
        let plan = try PresetLauncher(env: f.env, store: store).plan(preset, harness: .codex, cwd: f.project)
        let arg = try #require(plan.args.first { $0.hasPrefix("skills.config=") })
        #expect(arg.contains("{name=\"old\",enabled=false}"))
        #expect(arg.contains("gamma/SKILL.md"))
    }

    @Test func commandLineQuotes() {
        let plan = LaunchPlan(harness: .claude, env: ["A": "x y"], args: ["--settings", "/p/s.json", "it's"], notes: [])
        #expect(plan.commandLine(cwd: "/a b") == "cd '/a b' && A='x y' claude --settings /p/s.json 'it'\\''s'")
    }
}

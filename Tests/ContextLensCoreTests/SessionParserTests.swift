import Foundation
import Testing
@testable import ContextLensCore

@Suite struct SessionParserTests {
    func jsonLine(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    @Test func claudeTranscriptSnapshotAndDiskStatus() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("CLAUDE.md", "current text", base: f.project)
        let deleted = f.project.appending(path: "gone.md").path
        let lines = [
            jsonLine(["type": "user", "cwd": f.project.path, "message": ["role": "user", "content": "hello there"]]),
            jsonLine(["type": "attachment", "cwd": f.project.path, "attachment": [
                "type": "instructions",
                "files": [
                    ["path": f.project.appending(path: "CLAUDE.md").path, "type": "Project", "content": "old text"],
                    ["path": deleted, "type": "Project", "content": "was here"],
                ],
            ]]),
            jsonLine(["type": "attachment", "attachment": ["type": "skill_listing", "content": "- alpha: First skill\n- beta: Second skill\n- plug:gamma: Namespaced: with colons"]]),
            jsonLine(["type": "attachment", "attachment": ["type": "prompt_snapshot", "systemPrompt": ["\nYou are an agent.", "# Harness\nRules"]]]),
            jsonLine(["type": "custom-title", "customTitle": "My session"]),
        ]
        let file = f.root.appending(path: "home/.claude/projects/x/s1.jsonl")
        try f.write("home/.claude/projects/x/s1.jsonl", lines.joined(separator: "\n") + "\n")

        let index = SessionIndex(env: f.env)
        let summary = try #require(index.claudeSummary(file))
        #expect(summary.title == "My session")
        #expect(summary.cwd == f.project.path)

        let snap = ClaudeSessionParser(env: f.env).parse(summary)
        let claudeMd = snap.items.first { $0.path?.hasSuffix("CLAUDE.md") == true }
        #expect(claudeMd?.diskStatus == .changed)
        #expect(claudeMd?.currentContent == "current text")
        #expect(snap.items.first { $0.path == deleted }?.diskStatus == .deleted)
        #expect(snap.items.filter { $0.kind == .skill }.map(\.title) == ["alpha", "beta", "plug:gamma"])
        #expect(snap.items.filter { $0.kind == .systemPrompt }.map(\.title) == ["You are an agent.", "Harness"])
    }

    @Test func reversedInstructionTagsDoNotCrash() {
        let parser = CodexSessionParser(env: HarnessEnvironment(home: URL(filePath: "/nonexistent")))
        _ = parser.agentsItems("# AGENTS.md instructions for /x\n</INSTRUCTIONS> then <INSTRUCTIONS>", cwd: "/nonexistent")
    }

    @Test func codexRolloutSplitsGlobalAndProjectDocs() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("AGENTS.md", "root agents", base: f.project)
        let global = f.home.appending(path: ".codex/AGENTS.md").path
        try f.write(".codex/AGENTS.md", "global now", base: f.home)
        let agentsText = """
        # AGENTS.md instructions for \(f.project.path)

        <INSTRUCTIONS>
        <!-- BEGIN GLOBAL AGENTS.md: \(global) -->
        global then
        <!-- END GLOBAL AGENTS.md: \(global) -->

        --- project-doc ---

        root agents

        removed paragraph
        </INSTRUCTIONS>
        """
        let lines = [
            jsonLine(["type": "session_meta", "payload": ["cwd": f.project.path, "cli_version": "0.159.3", "base_instructions": ["text": "You are Codex."]]]),
            jsonLine(["type": "response_item", "payload": ["type": "message", "role": "developer", "content": [
                ["type": "input_text", "text": "<skills_instructions>\n## Skills\n- `r0` = `/x/skills`\n- demo: Demo skill (file: r0/demo/SKILL.md)\n</skills_instructions>"],
            ]]]),
            jsonLine(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [
                ["type": "input_text", "text": agentsText],
                ["type": "input_text", "text": "<environment_context>\n  <cwd>\(f.project.path)</cwd>\n</environment_context>"],
            ]]]),
            jsonLine(["type": "response_item", "payload": ["type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the bug"]]]]),
        ]
        let id = "01a0f659-0ad8-7340-8e9a-e5171dbdc84d"
        try f.write("home/.codex/sessions/2026/10/01/rollout-2026-10-01T09-23-46-\(id).jsonl", lines.joined(separator: "\n") + "\n")
        let file = f.home.appending(path: ".codex/sessions/2026/10/01/rollout-2026-10-01T09-23-46-\(id).jsonl")

        let summary = try #require(SessionIndex(env: f.env).codexSummary(file, names: [:]))
        #expect(summary.title == "Fix the bug")

        let snap = CodexSessionParser(env: f.env).parse(summary)
        let instructions = snap.items.filter { $0.kind == .instructions }
        #expect(instructions.first?.scope == "Global")
        #expect(instructions.first?.diskStatus == .changed)
        #expect(instructions.contains { $0.path?.hasSuffix("app/AGENTS.md") == true && $0.diskStatus == .same })
        #expect(instructions.contains { $0.content == "removed paragraph" && $0.diskStatus == .changed })
        #expect(snap.items.contains { $0.kind == .skill && $0.path == "/x/skills/demo/SKILL.md" })
        #expect(snap.items.contains { $0.kind == .systemPrompt && $0.content == "You are Codex." })
    }
}

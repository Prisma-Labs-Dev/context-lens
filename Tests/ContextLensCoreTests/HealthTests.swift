import Foundation
import Testing
@testable import ContextLensCore

@Suite struct RedactorTests {
    @Test func removesSecrets() {
        let cases = [
            "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx1234",
            "token ghp_abcdefghijklmnopqrstuvwxyz0123456789",
            "Authorization: Bearer abcdefghijklmnop.qrstuvwx-123456",
            #"{"password": "hunter2hunter2"}"#,
            "https://user:s3cretpass@example.com/x",
            "https://api.example.com/v1?token=abcdef123456&x=1",
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBg\n-----END PRIVATE KEY-----",
            "key a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0",
        ]
        let secrets = ["abcdefghijklmnopqrstuvwx1234", "ghp_abcdefghij", "qrstuvwx-123456", "hunter2", "s3cretpass", "abcdef123456",
                       "dozjgNryP4J3", "MIIEvQIBADANBg", "a1b2c3d4e5f6"]
        for (text, secret) in zip(cases, secrets) {
            let out = Redactor.redact(text)
            #expect(!out.contains(secret), "\(text) -> \(out)")
        }
    }

    @Test func keepsOrdinaryText() {
        let text = "cat /Users/me/repos/orchard/.claude/worktrees/offline-sync/Packages/Core/Sources/Core/ShelfStore.swift"
        #expect(Redactor.redact(text) == text)
        #expect(Redactor.redact("Agent: author claude-opus-5-5 high") == "Agent: author claude-opus-5-5 high")
        #expect(Redactor.redact("session 01a0e1e8-87be-7593-a572-c77c2bd250c5") == "session 01a0e1e8-87be-7593-a572-c77c2bd250c5")
    }

    @Test func clipKeepsHeadAndTail() {
        let text = "start " + String(repeating: "x", count: 5000) + " the error"
        let out = Redactor.clip(text, 100)
        #expect(out.count <= 100)
        #expect(out.hasPrefix("start"))
        #expect(out.hasSuffix("the error"))
    }
}

@Suite struct HealthTextTests {
    @Test func commandHeadSkipsSetup() {
        let home = "/Users/me"
        #expect(HealthText.commandHead("cd /tmp && git status", home: home) == "git")
        #expect(HealthText.commandHead("FOO=1 BAR=2 xcodebuild -scheme X", home: home) == "xcodebuild")
        #expect(HealthText.commandHead("source ~/.zshenv && rg -n x", home: home) == "rg")
        #expect(HealthText.commandHead("/Users/me/bin/sim-lease acquire", home: home) == "~/bin/sim-lease")
        #expect(HealthText.commandHead("./scripts/run.sh -x", home: home) == "scripts/run.sh")
        #expect(HealthText.commandHead("/opt/homebrew/bin/gh pr list", home: home) == "gh")
        #expect(HealthText.commandHead("xcrun simctl list", home: home) == "xcrun simctl")
    }

    @Test func mainCheckoutFoldsWorktrees() {
        #expect(HealthText.mainCheckout("/r/orchard/.claude/worktrees/foo-1/CLAUDE.md") == "/r/orchard/CLAUDE.md")
        #expect(HealthText.mainCheckout("/h/.codex/worktrees/b48e/orchard-codex/AGENTS.md") == "/h/.codex/worktrees/*/orchard-codex/AGENTS.md")
    }

    @Test func parsesTimestamps() {
        let d = HealthText.date("2026-10-04T10:00:36.250Z")
        #expect(d == SessionIndex.parseISO("2026-10-04T10:00:36.250Z"))
    }
}

@Suite struct HealthGroupingTests {
    func event(_ text: String, source: String = "Bash: cat") -> HealthEvent {
        HealthEvent(id: UUID().uuidString, session: "s", harness: "claude", kind: .toolError, time: nil, tool: "Bash",
                    source: source, input: nil, text: text)
    }

    func label(_ l: String) -> HealthLabel {
        HealthLabel(id: "", label: l, p: 1, severity: 2, friction: true, escalate: false)
    }

    @Test func sameMistakeGroupsAcrossPrograms() {
        let a = event("Exit code 1\nfile contents\n(eval):1: ===== not found", source: "Bash: cat")
        let b = event("Exit code 1\nother output\n(eval):1: === not found", source: "Bash: sed")
        #expect(HealthAggregator.groupKey(a, label("misuse")) == HealthAggregator.groupKey(b, label("misuse")))
    }

    @Test func guardVariantsShareAGroup() {
        let a = event("This session is isolated in the worktree /r/a, but this command is too complex to verify. Refusing to run it")
        let b = event("This agent is isolated in the worktree /r/b, but this command names git in a form too complex")
        #expect(HealthAggregator.groupKey(a, label("guard")) == HealthAggregator.groupKey(b, label("guard")))
        #expect(HealthAggregator.groupKey(a, label("guard")) == "guard: This session is isolated in the worktree …")
    }

    @Test func apiErrorsGroupByMessageAcrossModels() {
        var a = event(#"429 {"type":"error","error":{"type":"rate_limit_error","message":"No account can serve this request for claude-opus-5-5: all 2 accounts are busy"}}"#)
        var b = event(#"429 {"type":"error","error":{"type":"rate_limit_error","message":"No account can serve this request for claude-haiku-4-5-20251001: accounts \"x\""}}"#)
        a.kind = .apiError
        b.kind = .apiError
        let key = HealthAggregator.groupKey(a, label("api_error"))
        #expect(key == "api_error: No account can serve this request for claude-*")
        #expect(HealthAggregator.groupKey(b, label("api_error")) == key)
    }

    @Test func proposalsRoundTripAndRecordBaseline() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let store = HealthStore(root: f.root.appending(path: "health"))
        let p = HealthProposal(id: HealthStore.proposalID("Quote echo separators in zsh!", date: Date(timeIntervalSince1970: 0)),
                               created: Date(), title: "Quote echo separators", target: "~/.claude/CLAUDE.md", kind: "rule",
                               status: .open, summary: "s", edit: "e", group: "misuse: x", events: 9, sessions: 3,
                               quotes: [.init(session: "claude:a", text: "q")], author: "test")
        #expect(p.id == "1970-01-01-quote-echo-separators-in-zsh")
        try store.save(p)
        #expect(store.proposals().map(\.id) == [p.id])
        let applied = try store.setStatus(p.id, .applied, note: "done")
        #expect(applied.status == .applied && applied.note == "done" && applied.decided != nil)
        #expect(store.proposals().first?.status == .applied)
        #expect(throws: (any Error).self) { try store.setStatus("missing", .open, note: nil) }
    }

    @Test func errorLinePicksTheFailure() {
        let text = "Exit code 1\nline one\nTraceback (most recent call last):\n  File \"x.py\", line 2\nValueError: bad value\n"
        #expect(HealthAggregator.errorLine(text) == "ValueError: bad value")
    }
}

@Suite struct HealthExtractorTests {
    func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]), as: UTF8.self)
    }

    @Test func claudeTranscriptEvents() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let cwd = f.project.path
        let lines = [
            line(["type": "user", "cwd": cwd, "timestamp": "2026-10-04T10:00:00.000Z",
                  "message": ["role": "user", "content": "Build the thing"]]),
            line(["type": "attachment", "timestamp": "2026-10-04T10:00:01.000Z",
                  "attachment": ["type": "instructions", "files": [["path": "\(cwd)/CLAUDE.md", "type": "Project", "content": "x"]]]]),
            line(["type": "assistant", "cwd": cwd, "timestamp": "2026-10-04T10:00:02.000Z", "message": [
                "id": "m1", "model": "claude-opus-5-5",
                "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 100, "cache_creation_input_tokens": 20],
                "content": [["type": "tool_use", "id": "t1", "name": "Bash", "input": ["command": "cd x && git push --token=abcdef1234567890"]]],
            ]]),
            line(["type": "user", "timestamp": "2026-10-04T10:00:03.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t1", "is_error": true, "content": "fatal: auth failed"],
            ]]]),
            line(["type": "assistant", "timestamp": "2026-10-04T10:00:04.000Z", "message": [
                "id": "m2", "model": "claude-opus-5-5",
                "content": [["type": "tool_use", "id": "t2", "name": "Bash", "input": ["command": "cd x && git push --token=abcdef1234567890"]]],
            ]]),
            line(["type": "user", "timestamp": "2026-10-04T10:00:05.000Z", "message": ["role": "user", "content": [
                ["type": "tool_result", "tool_use_id": "t2", "is_error": true, "content": "fatal: auth failed"],
            ]]]),
            line(["type": "assistant", "timestamp": "2026-10-04T10:00:06.000Z", "message": [
                "id": "m3", "content": [["type": "text", "text": "I pushed it."]],
            ]]),
            line(["type": "user", "timestamp": "2026-10-04T10:00:07.000Z", "message": ["role": "user", "content": "no, that's wrong"]]),
            line(["type": "user", "timestamp": "2026-10-04T10:00:08.000Z", "message": ["role": "user", "content": [
                ["type": "text", "text": "[Request interrupted by user]"],
            ]]]),
            line(["type": "system", "subtype": "api_error", "timestamp": "2026-10-04T10:00:09.000Z", "error": ["message": "Overloaded"]]),
        ]
        try f.write("home/.claude/projects/p/abc.jsonl", lines.joined(separator: "\n") + "\n")
        let x = HealthExtractor(env: f.env).extract(since: .distantPast)
        let s = try #require(x.sessions.first)
        #expect(s.id == "claude:abc")
        #expect(s.toolCalls == 2 && s.toolErrors == 2 && s.interrupts == 1 && s.apiErrors == 1)
        #expect(s.inputTokens == 10 && s.cacheReadTokens == 100 && s.cacheWriteTokens == 20)
        #expect(s.model == "claude-opus-5-5")
        #expect(s.ruleFiles.count == 1)
        #expect(s.title == "Build the thing")
        let errors = x.events.filter { $0.kind == .toolError }
        #expect(errors.map(\.source) == ["Bash: git", "Bash: git"])
        #expect(errors.map(\.repeats) == [0, 1])
        #expect(errors.allSatisfy { !($0.input ?? "").contains("abcdef1234567890") })
        let corrections = x.events.filter { $0.kind == .userMessage }
        #expect(corrections.map(\.text) == ["no, that's wrong"])
        #expect(corrections.first?.context == "I pushed it.")
    }

    /// A rollout line in Codex's key order: timestamp, type, then payload with its own type first.
    /// The parser relies on that order (JSONSerialization alone would shuffle the keys).
    func rollout(_ time: String, _ type: String, _ payload: [String: Any]) -> String {
        var rest = payload
        let inner = rest.removeValue(forKey: "type").map { #""type":"\#($0)""# }
        var body = line(rest)
        if let inner { body = "{" + inner + (rest.isEmpty ? "" : ",") + body.dropFirst() }
        return #"{"timestamp":"\#(time)","type":"\#(type)","payload":\#(body)}"#
    }

    @Test func codexRolloutEvents() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let id = "01a0e1e8-87be-7593-a572-c77c2bd250c5"
        let output = #"{"chunk_id":"a","exit_code":127,"output":"zsh: command not found: nope\n"}"#
        let lines = [
            rollout("2026-10-04T10:00:00.000Z", "session_meta", ["id": id, "cwd": "/w"]),
            rollout("2026-10-04T10:00:00.500Z", "world_state", [
                "state": ["agents_md": ["text": "<!-- BEGIN GLOBAL AGENTS.md: /h/.codex/AGENTS.md -->\nrules"]],
                "items": [["type": "reasoning"], ["type": "response_item"]],
            ]),
            rollout("2026-10-04T10:00:01.000Z", "response_item", [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": "Fix the build"]],
            ]),
            rollout("2026-10-04T10:00:02.000Z", "response_item", [
                "type": "custom_tool_call", "name": "exec", "call_id": "c1",
                "input": #"const r = await tools.exec_command({ cmd: "cd /w && nope --x", workdir: "/w" });"#,
            ]),
            rollout("2026-10-04T10:00:03.000Z", "response_item", [
                "type": "custom_tool_call_output", "call_id": "c1",
                "output": [["type": "input_text", "text": "Script completed\nWall time 0.1 seconds\nOutput:\n"], ["type": "input_text", "text": output]],
            ]),
            rollout("2026-10-04T10:00:04.000Z", "response_item", [
                "type": "message", "role": "user", "content": [["type": "input_text", "text": "you still haven't run the tests"]],
            ]),
            rollout("2026-10-04T10:00:05.000Z", "event_msg", ["type": "turn_aborted", "reason": "interrupted"]),
            rollout("2026-10-04T10:00:06.000Z", "event_msg", [
                "type": "token_count", "info": ["total_token_usage": ["input_tokens": 1000, "cached_input_tokens": 900, "output_tokens": 50]],
            ]),
        ]
        try f.write("home/.codex/sessions/2026/10/04/rollout-2026-10-04T10-00-00-\(id).jsonl", lines.joined(separator: "\n") + "\n")
        let x = HealthExtractor(env: f.env).extract(since: .distantPast)
        let s = try #require(x.sessions.first)
        #expect(s.id == "codex:\(id)")
        #expect(s.link == "codex://threads/\(id)")
        #expect(s.ruleFiles == ["/h/.codex/AGENTS.md"])
        #expect(s.toolErrors == 1 && s.interrupts == 1 && s.userMessages == 2)
        #expect(s.inputTokens == 100 && s.cacheReadTokens == 900)
        let err = try #require(x.events.first { $0.kind == .toolError })
        #expect(err.source == "exec: nope")
        #expect(err.text.hasPrefix("Exit code 127"))
        #expect(x.events.filter { $0.kind == .userMessage }.map(\.text) == ["you still haven't run the tests"])
    }
}

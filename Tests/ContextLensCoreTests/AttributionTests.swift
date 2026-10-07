import Foundation
import Testing
@testable import ContextLensCore

@Suite struct AttributionTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    func line(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func measurement(folder: String, at: Date, mcp: [(String, String, Int)], tools: Int = 16000) -> MeasuredContext {
        let mcpTotal = mcp.reduce(0) { $0 + $1.2 }
        return MeasuredContext(folder: folder, measuredAt: at, model: "claude-test", used: 2000 + tools + mcpTotal + 900 + 400, window: 200_000,
                               categories: [.init(name: "System prompt", tokens: 2000), .init(name: "System tools", tokens: tools),
                                            .init(name: "MCP tools", tokens: mcpTotal), .init(name: "Memory files", tokens: 900),
                                            .init(name: "Skills", tokens: 400)],
                               mcpTools: mcp.map { .init(name: $0.0, detail: $0.1, tokens: $0.2) },
                               skills: [.init(name: "brew-tea", detail: "User", tokens: 400)],
                               memoryFiles: [.init(name: "/Users/me/.claude/CLAUDE.md", detail: "User", tokens: 900)], source: "measure")
    }

    var snapshot: ContextSnapshot {
        ContextSnapshot(harness: .claude, cwd: "/Users/me/code/garden", items: [
            ContextItem(kind: .systemPrompt, title: "You are an agent.", scope: "Harness", content: String(repeating: "p", count: 6000), load: .always),
            ContextItem(kind: .instructions, title: "~/.claude/CLAUDE.md", scope: "User", path: "/Users/me/.claude/CLAUDE.md",
                        content: String(repeating: "c", count: 2400), load: .always),
            ContextItem(kind: .skill, title: "brew-tea", scope: "Listed", content: String(repeating: "s", count: 1200), load: .listing),
            ContextItem(kind: .agent, title: "Subagent listing", scope: "Harness", content: String(repeating: "a", count: 400), load: .listing),
            ContextItem(id: "mcp|plugin:garden:garden", kind: .mcp, title: "plugin:garden:garden", scope: "Server instructions",
                        content: String(repeating: "g", count: 800), load: .always),
            ContextItem(id: "mcp|kettle", kind: .mcp, title: "kettle", scope: "Server instructions", content: String(repeating: "k", count: 400), load: .always),
            ContextItem(kind: .environment, title: "gitStatus", scope: "Session", content: String(repeating: "e", count: 200), load: .always),
        ])
    }

    func growth(first: Int) -> ContextGrowth {
        ContextGrowth(entrypoint: "cli", model: "claude-test",
                      calls: [.init(index: 1, tokens: first, output: 10, time: start, delta: 0, added: [])],
                      compactions: [], firstMessageTokens: 20,
                      firstTurnReminders: [.init(label: "Model identity", tokens: 30)],
                      firstCallCacheRead: first - 4000, firstCallCacheWritten: 4000)
    }

    @Test func sessionSegmentsAddUpWithMeasuredSchemas() throws {
        // The folder's measurement lacks plugin:garden:garden (it didn't connect); another folder's has it.
        let own = measurement(folder: "/Users/me/code/garden", at: start.addingTimeInterval(3600), mcp: [("mcp__kettle__boil", "kettle", 2000)])
        let other = measurement(folder: "/Users/me/code", at: start.addingTimeInterval(3700),
                                mcp: [("mcp__plugin_garden_garden__water", "plugin_garden_garden", 30000), ("mcp__kettle__boil", "kettle", 2000)])
        let a = try #require(ContextAttribution.session(snapshot: snapshot, growth: growth(first: 60000), measurement: own, others: [own, other]))

        // /context counts CLAUDE.md and brew-tea at 900 + 400; the transcript estimate is 600 + 300.
        #expect(a.calibration == 1300.0 / 900)
        #expect(a.segments.reduce(0) { $0 + $1.tokens } == 60000)
        #expect(a.segments.reduce(0) { $0 + $1.shown } == a.shownTotal)
        #expect(a.shownTotal == 60000)
        let garden = try #require(a.mcp("plugin:garden:garden"))
        #expect(garden.schemas == 30000)
        #expect(garden.instructions == 289)
        #expect(garden.tokens == 30289)
        #expect(garden.schemasFrom?.folder == "/Users/me/code")
        #expect(garden.detail == "schemas 30.0k + instructions 0.3k")
        #expect(a.mcp("kettle")?.schemas == 2000)
        #expect(a.mcp("kettle")?.schemasFrom == nil)
        #expect(a.segments.first?.id == "harness-prompt")
        #expect(a.segments.first?.tokens == 2000)
        #expect(a.segments.first { $0.id == "built-in-tools" }?.tokens == 16000)
        #expect(a.segments.last?.id == "unattributed")
        #expect(a.measurement?.folder == "/Users/me/code/garden")
        #expect(a.causes.contains { $0.hasPrefix("Measurement drift: measured 1.0 h after") })
        #expect(a.causes.contains { $0.hasPrefix("Hooks: no hook output") })
    }

    @Test func withoutMeasurementSchemasAreUnknown() throws {
        let a = try #require(ContextAttribution.session(snapshot: snapshot, growth: growth(first: 50000), measurement: nil))
        #expect(a.calibration == nil)
        let garden = try #require(a.mcp("plugin:garden:garden"))
        #expect(garden.schemas == nil)
        #expect(garden.tokens == 200)
        #expect(garden.detail == "instructions 0.2k + schemas unknown")
        #expect(a.segments.contains { $0.id == "built-in-tools" } == false)
        #expect(a.unattributed?.title == "Not in transcript")
        #expect(a.segments.reduce(0) { $0 + $1.tokens } == 50000)
        #expect(a.segments.reduce(0) { $0 + $1.shown } == 50000)
    }

    @Test func measuredSegmentsAddUp() {
        let m = measurement(folder: "/Users/me/code", at: start, mcp: [("mcp__kettle__boil", "kettle", 2049), ("mcp__garden__water", "garden", 1234)])
        let a = ContextAttribution.measured(m)
        #expect(a.segments.map(\.id) == ["harness-prompt", "built-in-tools", "mcp|kettle", "mcp|garden", "instructions", "skills"])
        #expect(a.segments.reduce(0) { $0 + $1.tokens } == m.used)
        #expect(a.segments.reduce(0) { $0 + $1.shown } == a.shownTotal)
        #expect(a.unattributed == nil)
    }

    @Test func roundingSpreadsToTheTotal() {
        #expect(ContextAttribution.spread([1978, 16383, 32280, 43, 17062], to: 67700) .reduce(0, +) == 67700)
        #expect(ContextAttribution.spread([60, 60, 60], to: 200) == [100, 100, 0])
        #expect(ContextAttribution.spread([5000, -420], to: 4600) == [5000, -400])
    }

    @Test func readsReminderAndCacheSplitOfTheFirstCall() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let lines = [
            line(["type": "user", "message": ["role": "user", "content": "Water the plants"]]),
            line(["type": "attachment", "attachment": ["type": "model", "text": String(repeating: "m", count: 400)]]),
            line(["type": "attachment", "attachment": ["type": "hook_additional_context", "hookName": "SessionStart", "content": [String(repeating: "h", count: 800)]]]),
            line(["type": "attachment", "attachment": ["type": "skill_listing", "content": "- brew-tea: Brews tea"]]),
            line(["type": "assistant", "message": ["id": "m1", "role": "assistant", "content": [["type": "text", "text": "OK"]],
                                                  "usage": ["input_tokens": 2, "cache_read_input_tokens": 50000, "cache_creation_input_tokens": 3000, "output_tokens": 5]]]),
            line(["type": "attachment", "attachment": ["type": "date", "date": "2026-10-02"]]),
        ]
        try f.write("s.jsonl", lines.joined(separator: "\n") + "\n")
        let g = try #require(ContextGrowthReader().read(f.root.appending(path: "s.jsonl")))
        #expect(g.firstCallCacheRead == 50000)
        #expect(g.firstCallCacheWritten == 3002)
        #expect(g.firstTurnReminders.map(\.label) == ["Hook output", "Model identity"])
        #expect(g.firstTurnReminders.map(\.tokens) == [203, 100])
    }
}

@Suite struct MeasurementHistoryTests {
    let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    func m(_ folder: String, _ at: Date, used: Int) -> MeasuredContext {
        MeasuredContext(folder: folder, measuredAt: at, used: used, categories: [.init(name: "System tools", tokens: used)], mcpTools: [], skills: [])
    }

    @Test func keepsEveryMeasurementAndFindsTheNearest() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let store = MeasuredContextStore(root: f.root.appending(path: "context"), claudeHome: f.home.appending(path: ".claude"))
        store.save(m("/Users/me/code/garden", t0, used: 1000))
        store.save(m("/Users/me/code/garden", t0.addingTimeInterval(7200), used: 2000))
        store.save(m("/Users/me/code/garden", t0.addingTimeInterval(7200), used: 9999)) // same time: not overwritten
        store.save(m("/Users/me/code/kettle", t0, used: 3000))
        #expect(store.history("/Users/me/code/garden").map(\.used) == [1000, 2000])
        #expect(store.cached("/Users/me/code/garden")?.used == 2000)
        #expect(store.nearest("/Users/me/code/garden", to: t0.addingTimeInterval(3000))?.used == 1000)
        #expect(store.nearest("/Users/me/code/garden", to: t0.addingTimeInterval(5000))?.used == 2000)
        #expect(store.all().count == 3)
    }

    @Test func harvestsContextRunsFromTranscripts() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let claude = f.home.appending(path: ".claude")
        let store = MeasuredContextStore(root: f.root.appending(path: "context"), claudeHome: claude)
        let usage: [String: Any] = [
            "model": "claude-test[1m]", "total_tokens": 21000, "raw_max_tokens": 1_000_000,
            "categories": [["name": "System prompt", "tokens": 2000, "kind": "used"], ["name": "System tools", "tokens": 16000, "kind": "used"],
                           ["name": "MCP tools", "tokens": 3000, "kind": "used"], ["name": "Free space", "tokens": 900_000, "kind": "free"]],
            "mcp_tools": [["name": "mcp__plugin_garden_garden__water", "server_name": "plugin_garden_garden", "tokens": 3000]],
            "memory_files": [["path": "/Users/me/.claude/CLAUDE.md", "type": "User", "tokens": 900]],
            "skills": [["name": "brew-tea", "source": "userSettings", "tokens": 58]],
        ]
        let entry: [String: Any] = ["type": "system", "subtype": "local_command", "content": "<local-command-stdout>…</local-command-stdout>",
                                    "contextUsage": usage, "cwd": "/Users/me/code", "sessionId": "abc", "timestamp": "2026-10-01T13:00:33.013Z"]
        let text = String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
        try f.write("projects/-Users-me-code/abc.jsonl", text + "\n", base: claude)
        store.harvest(around: "/Users/me/code/garden")
        let found = try #require(store.cached("/Users/me/code"))
        #expect(found.used == 21000)
        #expect(found.model == "claude-test")
        #expect(found.window == 1_000_000)
        #expect(found.categories.map(\.name) == ["System prompt", "System tools", "MCP tools"])
        #expect(found.mcpSchemas("plugin:garden:garden") == 3000)
        #expect(found.memoryFiles?.first?.tokens == 900)
        #expect(found.source == "transcript abc")
        // Unchanged transcripts aren't read again, and nothing is duplicated.
        store.harvest(around: "/Users/me/code/garden")
        #expect(store.history("/Users/me/code").count == 1)
    }
}

@Suite struct MeasuredRoundingTests {
    @Test func printedTableRoundingIsItsOwnSegment() throws {
        let text = """
        **Tokens:** 24.6k / 200k (12%)

        ### Estimated usage by category

        | Category | Tokens | Percentage |
        |----------|--------|------------|
        | System prompt | 2k | 1.0% |
        | System tools | 10k | 5.0% |
        | MCP tools | 2.2k | 1.1% |
        | Skills | 10.5k | 5.0% |

        ### MCP Tools

        | Tool | Server | Tokens |
        |------|--------|--------|
        | mcp__kettle__boil | kettle | 2180 |
        """
        let m = try #require(MeasuredContext.parse(text, folder: "/Users/me/code"))
        let a = ContextAttribution.measured(m)
        #expect(a.segments.map(\.id) == ["harness-prompt", "built-in-tools", "mcp|kettle", "skills", "rounding"])
        #expect(a.segments.last?.tokens == -80)
        #expect(a.segments.reduce(0) { $0 + $1.tokens } == 24600)
    }
}

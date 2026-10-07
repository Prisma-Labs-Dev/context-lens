import Foundation
import Testing
@testable import ContextLensCore

@Suite struct ContextGrowthTests {
    func jsonLine(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    func assistant(_ id: String, cached: Int, created: Int = 0, _ content: [[String: Any]], sidechain: Bool = false) -> String {
        jsonLine(["type": "assistant", "entrypoint": "cli", "isSidechain": sidechain, "timestamp": "2026-10-01T09:00:00.000Z", "message": [
            "id": id, "model": "claude-test", "role": "assistant", "content": content,
            "usage": ["input_tokens": 10, "cache_read_input_tokens": cached, "cache_creation_input_tokens": created, "output_tokens": 50],
        ]])
    }

    @Test func readsCallsJumpsAndCompactions() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let lines = [
            jsonLine(["type": "user", "message": ["role": "user", "content": "Explain the build"]]),
            jsonLine(["type": "attachment", "attachment": ["type": "skill_listing", "content": "- brew-tea: Brews tea"]]),
            assistant("m1", cached: 0, created: 30000, [["type": "tool_use", "id": "t1", "name": "Read", "input": ["file_path": "/Users/me/code/garden/NOTES.md"]]]),
            // A second content block of the same call: counted once.
            assistant("m1", cached: 0, created: 30000, [["type": "text", "text": "Reading it."]]),
            jsonLine(["type": "user", "message": ["role": "user", "content": [["type": "tool_result", "tool_use_id": "t1", "content": String(repeating: "n", count: 8000)]]]]),
            // A subagent runs in its own context.
            assistant("s1", cached: 90000, [["type": "text", "text": "side work"]], sidechain: true),
            assistant("m2", cached: 32090, [["type": "tool_use", "id": "t2", "name": "Skill", "input": ["skill": "brew-tea"]]]),
            jsonLine(["type": "user", "isMeta": true, "sourceToolUseID": "t2", "message": ["role": "user", "content": [["type": "text", "text": String(repeating: "s", count: 4000)]]]]),
            assistant("m3", cached: 33190, [["type": "text", "text": "Done."]]),
            jsonLine(["type": "system", "subtype": "compact_boundary", "compactMetadata": ["trigger": "manual", "preTokens": 33200, "postTokens": 5000]]),
            jsonLine(["type": "user", "message": ["role": "user", "content": "<command-name>/tidy</command-name>"]]),
            jsonLine(["type": "user", "isMeta": true, "message": ["role": "user", "content": String(repeating: "t", count: 400)]]),
            assistant("m4", cached: 5990, [["type": "text", "text": "Tidied."]]),
        ]
        try f.write("s.jsonl", lines.joined(separator: "\n") + "\n")
        let g = try #require(ContextGrowthReader().read(f.root.appending(path: "s.jsonl")))

        #expect(g.entrypoint == "cli")
        #expect(g.model == "claude-test")
        #expect(g.calls.map(\.tokens) == [30010, 32100, 33200, 6000])
        #expect(g.calls.map(\.delta) == [0, 2090, 1100, -27200])
        #expect(g.calls[1].cause?.label == "Read NOTES.md")
        #expect(g.calls[1].cause?.tokens == 2000)
        #expect(g.calls[2].cause?.label == "Skill brew-tea")
        #expect(g.calls[3].cause?.label == "/tidy")
        #expect(g.compactions.count == 1)
        #expect(g.compactions[0].afterCall == 3)
        #expect(g.compactions[0].preTokens == 33200)
        #expect(g.compactions[0].postTokens == 5000)
        #expect(g.topJumps().map(\.index) == [2, 3])
        #expect(g.peak == 33200)
        #expect(g.firstMessageTokens == 5)
        #expect(g.hiddenTokens(estimated: 1000) == 29005)
    }

    @Test func noUsageNoGrowth() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("s.jsonl", jsonLine(["type": "user", "message": ["role": "user", "content": "hi"]]) + "\n")
        #expect(ContextGrowthReader().read(f.root.appending(path: "s.jsonl")) == nil)
    }

    @Test func labelsTools() {
        #expect(ContextGrowthReader.label(tool: "Bash", input: ["command": "cd \"/Users/me/my app\" && make test"]) == "Bash: make test")
        #expect(ContextGrowthReader.label(tool: "Bash", input: ["command": "cd /x; cd y && ls -la"]) == "Bash: ls -la")
        #expect(ContextGrowthReader.label(tool: "Bash", input: ["command": "ls", "description": "List files"]) == "Bash: List files")
        #expect(ContextGrowthReader.label(tool: "mcp__garden__water_plants", input: [:]) == "garden water_plants")
        #expect(ContextGrowthReader.label(tool: "WebFetch", input: ["url": "https://example.com/a"]) == "WebFetch example.com")
        #expect(ContextGrowthReader.label(tool: "Agent", input: ["description": "Find callers"]) == "Agent: Find callers")
    }
}

@Suite struct MeasuredContextTests {
    let sample = """
    ## Context Usage

    **Model:** claude-test
    **Tokens:** 24.6k / 200k (12%)

    ### Estimated usage by category

    | Category | Tokens | Percentage |
    |----------|--------|------------|
    | System prompt | 2k | 1.0% |
    | System tools | 16.1k | 8.1% |
    | MCP tools | 3.4k | 1.7% |
    | Custom agents | 73 | 0.0% |
    | Memory files | 2.2k | 1.1% |
    | Skills | 2k | 1.0% |
    | Free space | 142.4k | 71.2% |
    | Autocompact buffer | 33k | 16.5% |

    ### MCP Tools

    | Tool | Server | Tokens |
    |------|--------|--------|
    | mcp__garden__water | garden | 613 |
    | mcp__garden__prune | garden | 487 |
    | mcp__kettle__boil | kettle | 2.3k |

    ### Skills

    | Skill | Source | Tokens |
    |-------|--------|--------|
    | brew-tea | User | < 20 |
    | pick-font | Built-in | ~480 |
    """

    @Test func parsesContextOutput() throws {
        let m = try #require(MeasuredContext.parse(sample, folder: "/Users/me/code/garden"))
        #expect(m.model == "claude-test")
        #expect(m.used == 24600)
        #expect(m.window == 200_000)
        #expect(m.categories.map(\.name) == ["System prompt", "System tools", "MCP tools", "Custom agents", "Memory files", "Skills"])
        #expect(m.category("System tools") == 16100)
        #expect(m.notInFiles == 2000 + 16100 + 3400)
        #expect(m.mcpServers.map(\.name) == ["kettle", "garden"])
        #expect(m.mcpServers.map(\.tokens) == [2300, 1100])
        #expect(m.skills.map(\.tokens) == [0, 480])
        #expect(MeasuredContext.parse("Error: not logged in", folder: "/x") == nil)
    }

    @Test func cachesPerFolder() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let store = MeasuredContextStore(root: f.root.appending(path: "context"))
        let m = try #require(MeasuredContext.parse(sample, folder: "/Users/me/code/garden", at: Date(timeIntervalSince1970: 1_790_000_000)))
        store.save(m)
        #expect(store.cached("/Users/me/code/garden") == m)
        #expect(store.cached("/Users/me/code/kettle") == nil)
    }
}

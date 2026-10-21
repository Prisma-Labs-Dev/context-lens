import Foundation
import Testing
@testable import ContextLensCore

@Suite struct TreeEntriesTests {
    func jsonLine(_ obj: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: obj), as: UTF8.self)
    }

    /// A session as big as a long migration run: hundreds of instruction files, some gone from
    /// disk, and a skill listing of thousands of entries with repeated names.
    func bigSession(_ f: Fixture, files: Int, skills: Int) throws -> SessionSummary {
        var instructions: [[String: Any]] = []
        for i in 0..<files {
            let name = "docs/rules-\(i).md"
            if i % 10 != 0 { try f.write(name, "rule \(i)", base: f.project) }
            instructions.append(["path": f.project.appending(path: name).path, "type": "Project", "content": "rule \(i)"])
        }
        let listing = (0..<skills).map { "- skill-\($0 % (skills / 2)): Does thing \($0)" }.joined(separator: "\n")
        var lines = [jsonLine(["type": "user", "cwd": f.project.path, "message": ["role": "user", "content": "migrate it"]])]
        lines.append(jsonLine(["type": "attachment", "cwd": f.project.path, "attachment": ["type": "instructions", "files": instructions]]))
        lines.append(jsonLine(["type": "attachment", "attachment": ["type": "skill_listing", "content": listing]]))
        for i in 0..<2000 {
            lines.append(jsonLine(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": "step \(i)"]]]]))
        }
        try f.write("home/.claude/projects/x/big.jsonl", lines.joined(separator: "\n") + "\n")
        return try #require(SessionIndex(env: f.env).claudeSummary(f.root.appending(path: "home/.claude/projects/x/big.jsonl")))
    }

    @Test func bigSessionGivesOneRowPerItemWithUniqueIds() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        let summary = try bigSession(f, files: 600, skills: 3000)
        let started = Date()
        let snap = ClaudeSessionParser(env: f.env).parse(summary)
        let entries = snap.treeEntries()
        #expect(Date().timeIntervalSince(started) < 10)

        // Every row has its own id, so the lazy list never confuses two rows.
        #expect(Set(entries.map(\.id)).count == entries.count)
        #expect(entries.compactMap(\.item).count == snap.items.count)
        #expect(snap.items.count >= 600 + 1500)
        let headers = entries.filter { $0.item == nil }
        #expect(headers.count == snap.sections.count)

        // A collapsed group keeps its header and drops its rows.
        let skills = snap.items.filter { $0.kind == .skill }.count
        let collapsed = snap.treeEntries(collapsed: [.skill])
        #expect(collapsed.count == entries.count - skills)
        #expect(collapsed.contains { $0.id == "group|\(ContextKind.skill.rawValue)" })

        // Problems only: the files gone from disk, under their own header.
        let problems = snap.treeEntries(onlyProblems: true)
        #expect(!problems.compactMap(\.item).contains { !$0.hasProblem })
        #expect(problems.compactMap(\.item).count == snap.items.filter(\.hasProblem).count)
        #expect(problems.compactMap(\.item).count >= 60)
    }

    @Test func headerCountsFollowTheFilter() {
        let items = [
            ContextItem(kind: .skill, title: "a", scope: "User", content: "x", load: .listing),
            ContextItem(kind: .skill, title: "b", scope: "User", content: "x", load: .listing, issues: [ContextLensCore.Issue(kind: .note, message: "w")]),
        ]
        let snap = ContextSnapshot(harness: .claude, cwd: "/Users/me/app", items: items)
        guard case .header(_, let all, _, true) = snap.treeEntries()[0] else { Issue.record("no header"); return }
        guard case .header(_, let some, _, true) = snap.treeEntries(onlyProblems: true)[0] else { Issue.record("no header"); return }
        #expect(all == 2)
        #expect(some == 1)
        #expect(ContextSnapshot(harness: .claude, cwd: "/", items: []).treeEntries().isEmpty)
    }
}

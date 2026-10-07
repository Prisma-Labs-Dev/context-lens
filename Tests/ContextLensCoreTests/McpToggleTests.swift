import Foundation
import Testing
@testable import ContextLensCore

/// Switching MCP servers and plugins writes files the harnesses own, so these tests check that an
/// edit changes only its key and that nothing else in the file is lost.
@Suite struct McpToggleTests {
    /// A home with a figma plugin (off everywhere, on in the project), a user server, a local
    /// server and a .mcp.json server.
    func fixture() throws -> Fixture {
        let f = try Fixture()
        let plugin = f.home.appending(path: ".claude/plugins/cache/market/figma/1.0.0")
        try f.write(".mcp.json", #"{"mcpServers":{"figma":{"type":"http","url":"https://example.com/mcp"}}}"#, base: plugin)
        try f.write(".claude/plugins/installed_plugins.json", """
        {"version":2,"plugins":{"figma@market":[{"scope":"user","installPath":"\(plugin.path)","version":"1.0.0"}],
         "skills-only@market":[{"scope":"user","installPath":"/nowhere"}]}}
        """, base: f.home)
        try f.write(".claude/settings.json", """
        {
          "model": "opus",
          "enabledPlugins": {
            "figma@market": false,
            "other@market": true
          },
          "unknownFutureKey": {
            "nested": [
              1,
              2.50,
              -3e2
            ]
          }
        }

        """, base: f.home)
        try f.write(".claude.json", """
        {
          "numStartups": 12,
          "mcpServers": {
            "computer": {
              "type": "stdio",
              "command": "ocu",
              "args": []
            }
          },
          "projects": {
            "/somewhere/else": {
              "allowedTools": [],
              "disabledMcpServers": [
                "computer"
              ]
            },
            "\(f.project.path)": {
              "allowedTools": [],
              "mcpServers": {
                "local-db": {
                  "command": "db"
                }
              },
              "hasTrustDialogAccepted": true
            }
          },
          "oauthAccount": {
            "emailAddress": "me@example.com"
          }
        }
        """, base: f.home)
        try f.write(".claude/settings.local.json", "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  },\n  \"enabledPlugins\": {\n    \"figma@market\": true\n  }\n}\n", base: f.project)
        try f.write(".mcp.json", #"{"mcpServers":{"docs":{"command":"docs"}}}"#, base: f.project)
        return f
    }

    func engine(_ f: Fixture) -> McpToggleEngine { McpToggleEngine(env: f.env) }
    func writer(_ f: Fixture) -> ConfigWriter { ConfigWriter(backupRoot: f.root.appending(path: "backups")) }
    func read(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "" }
    func toggle(_ f: Fixture, _ id: String, harness: Harness = .claude) -> McpToggle {
        engine(f).list(folder: f.project, harness: harness).toggles.first { $0.id == id }!
    }

    // MARK: JSON

    @Test func jsonRoundTripsByteForByte() throws {
        let text = """
        {
          "a": "é \\" \\\\ \\n \\t \\u0001 / 😀",
          "n": [1, 2.50, -3e2, 0],
          "empty": {},
          "list": [],
          "dup": 1,
          "dup": 2,
          "nested": {
            "x": [
              {
                "y": null,
                "z": true
              }
            ]
          }
        }
        """.replacingOccurrences(of: "[1, 2.50, -3e2, 0]", with: "[\n    1,\n    2.50,\n    -3e2,\n    0\n  ]")
        let doc = try JSONDocument(text)
        #expect(doc.text == text)
        #expect(doc.value["dup"] == .number("2"))
    }

    @Test func refusesInvalidJSON() {
        #expect(throws: ConfigEditError.self) { try JSONDocument("{\"a\": 1,}") }
        #expect(throws: ConfigEditError.self) { try JSONDocument("// comment\n{}") }
    }

    @Test func editChangesOnlyItsKey() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let settings = f.home.appending(path: ".claude/settings.json")
        let before = read(settings)
        try writer(f).apply([.jsonValue(file: settings.path, path: ["enabledPlugins", "figma@market"], value: .bool(true))], description: "t")
        let after = read(settings)
        #expect(after == before.replacingOccurrences(of: "\"figma@market\": false", with: "\"figma@market\": true"))
    }

    /// A file not in Claude Code's layout is rewritten in it; every value stays.
    @Test func handFormattedFileKeepsItsValues() throws {
        var doc = try JSONDocument("{\"a\": [1, 2.50], \"b\": {\"c\": \"x\"}}")
        try doc.value.set(.bool(true), at: ["d"])
        #expect(doc.text == "{\n  \"a\": [\n    1,\n    2.50\n  ],\n  \"b\": {\n    \"c\": \"x\"\n  },\n  \"d\": true\n}")
    }

    // MARK: Listing

    @Test func listsEffectiveStateAndSource() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let list = engine(f).list(folder: f.project, harness: .claude)
        let figma = list.toggles.first { $0.pluginKey == "figma@market" }!
        #expect(figma.on)
        #expect(figma.state == "off everywhere, on here")
        #expect(figma.servers == ["plugin_figma_figma"])
        #expect(figma.isOn(at: .folder) && !figma.isOn(at: .user))
        #expect(!list.toggles.contains { $0.pluginKey == "skills-only@market" })
        let computer = list.toggles.first { $0.id == "claude|user|computer" }!
        #expect(computer.on && computer.state == "on everywhere")
        #expect(list.toggles.first { $0.id == "claude|local|local-db" }?.scopes == [.folder])
        let docs = list.toggles.first { $0.id == "claude|project|docs" }!
        #expect(!docs.on && docs.state == "waiting for approval")

        // From a subfolder, the project's settings still apply.
        let sub = f.project.appending(path: "src")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        #expect(engine(f).list(folder: sub, harness: .claude).toggles.first { $0.pluginKey == "figma@market" }?.state == "off everywhere, on here")
    }

    @Test func costsComeFromMeasurements() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let store = MeasuredContextStore(root: f.root.appending(path: "measured"), claudeHome: f.home.appending(path: ".claude"))
        store.save(MeasuredContext(folder: "/elsewhere", measuredAt: Date(), used: 50_000, categories: [],
                                   mcpTools: [.init(name: "a", detail: "plugin_figma_figma", tokens: 30_000), .init(name: "b", detail: "plugin_figma_figma", tokens: 1_600),
                                              .init(name: "c", detail: "claude.ai Gmail", tokens: 900)], skills: []))
        store.save(MeasuredContext(folder: f.project.path, measuredAt: Date(), used: 20_000, categories: [],
                                   mcpTools: [.init(name: "c", detail: "claude.ai Gmail", tokens: 900)], skills: []))
        let list = McpToggleEngine(env: f.env, measurements: store).list(folder: f.project, harness: .claude)
        #expect(list.toggles.first { $0.pluginKey == "figma@market" }?.tokens == 31_600)
        let fixed = list.toggles.first { $0.kind == .fixed }
        #expect(fixed?.name == "claude.ai Gmail" && fixed?.scopes == [])
    }

    // MARK: Plugins

    @Test func pluginFolderAndUserScopes() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let e = engine(f), w = writer(f)
        let local = f.project.appending(path: ".claude/settings.local.json")

        // Off here: the folder value equals the inherited one, so the key goes.
        try w.apply(try e.plan(toggle(f, "claude|plugin|figma@market"), on: false, scope: .folder, folder: f.project).edits, description: "t")
        #expect(read(local) == "{\n  \"permissions\": {\n    \"allow\": [\n      \"Bash(ls)\"\n    ]\n  },\n  \"enabledPlugins\": {}\n}\n")
        #expect(toggle(f, "claude|plugin|figma@market").state == "off everywhere")

        // On everywhere: user settings, other keys kept.
        try w.apply(try e.plan(toggle(f, "claude|plugin|figma@market"), on: true, scope: .user, folder: f.project).edits, description: "t")
        let settings = read(f.home.appending(path: ".claude/settings.json"))
        #expect(settings.contains("\"figma@market\": true") && settings.contains("\"other@market\": true") && settings.contains("-3e2"))
        #expect(toggle(f, "claude|plugin|figma@market").state == "on everywhere")

        // Off here again: now an explicit false.
        try w.apply(try e.plan(toggle(f, "claude|plugin|figma@market"), on: false, scope: .folder, folder: f.project).edits, description: "t")
        #expect(toggle(f, "claude|plugin|figma@market").state == "on everywhere, off here")
    }

    // MARK: Servers

    @Test func userServerFolderScopeUsesTheMcpDisableList() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let other = f.home.appending(path: "code/other")
        try FileManager.default.createDirectory(at: other.appending(path: ".git"), withIntermediateDirectories: true)
        let claudeJSON = f.home.appending(path: ".claude.json")
        try writer(f).apply(try engine(f).plan(toggle(f, "claude|user|computer"), on: false, scope: .folder, folder: other).edits, description: "t")
        let config = try JSONValue.parse(read(claudeJSON))
        let entry = config["projects"]?[FileUtil.realPath(other).path]
        #expect(entry?["disabledMcpServers"] == .array([.string("computer")]))
        #expect(entry?["hasTrustDialogAccepted"] == .bool(false))
        #expect(config["oauthAccount"]?["emailAddress"] == .string("me@example.com"))
        #expect(config["projects"]?["/somewhere/else"]?["disabledMcpServers"] == .array([.string("computer")]))
        #expect(engine(f).list(folder: other, harness: .claude).toggles.first { $0.name == "computer" }?.state == "off here")
        #expect(toggle(f, "claude|user|computer").on)
    }

    @Test func userServerEverywhereIsADenyAFolderCantOverride() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let e = engine(f)
        try writer(f).apply(try e.plan(toggle(f, "claude|user|computer"), on: false, scope: .user, folder: f.project).edits, description: "t")
        let settings = try JSONValue.parse(read(f.home.appending(path: ".claude/settings.json")))
        #expect(settings["deniedMcpServers"] == .array([.object([.init("serverName", .string("computer"))])]))
        let t = toggle(f, "claude|user|computer")
        #expect(!t.on && t.state == "off everywhere")
        #expect(throws: ConfigEditError.self) { try e.plan(t, on: true, scope: .folder, folder: f.project) }
        try writer(f).apply(try e.plan(t, on: true, scope: .user, folder: f.project).edits, description: "t")
        #expect(toggle(f, "claude|user|computer").on)
    }

    @Test func projectServerUsesTheMcpjsonLists() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let e = engine(f)
        try writer(f).apply(try e.plan(toggle(f, "claude|project|docs"), on: true, scope: .folder, folder: f.project).edits, description: "t")
        #expect(toggle(f, "claude|project|docs").state == "on here")
        try writer(f).apply(try e.plan(toggle(f, "claude|project|docs"), on: false, scope: .folder, folder: f.project).edits, description: "t")
        let local = try JSONValue.parse(read(f.project.appending(path: ".claude/settings.local.json")))
        #expect(local["disabledMcpjsonServers"] == .array([.string("docs")]))
        #expect(local["enabledMcpjsonServers"] == .array([]))
        #expect(local["permissions"] != nil)
        #expect(toggle(f, "claude|project|docs").state == "off here")
    }

    // MARK: Safety

    @Test func undoRestoresTheFile() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let claudeJSON = f.home.appending(path: ".claude.json")
        let before = read(claudeJSON)
        let w = writer(f)
        try w.apply(try engine(f).plan(toggle(f, "claude|local|local-db"), on: false, scope: .folder, folder: f.project).edits, description: "Turn local-db off")
        #expect(read(claudeJSON) != before)
        #expect(w.lastChange()?.description == "Turn local-db off")
        #expect(w.lastChange()?.backups.count == 1)
        try w.undoLast()
        // The edit added an empty list; undo removes the element and leaves the list.
        #expect(try JSONValue.parse(read(claudeJSON))["projects"]?[f.project.path]?["disabledMcpServers"] == .array([]))
        #expect(w.lastChange() == nil)
    }

    @Test func concurrentWritesSurvive() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let claudeJSON = f.home.appending(path: ".claude.json")
        let plan = try engine(f).plan(toggle(f, "claude|local|local-db"), on: false, scope: .folder, folder: f.project)
        _ = try writer(f).preview(plan.edits)
        // A Claude Code session writes between the preview and the apply.
        try read(claudeJSON).replacingOccurrences(of: "\"numStartups\": 12", with: "\"numStartups\": 13").write(to: claudeJSON, atomically: true, encoding: .utf8)
        try writer(f).apply(plan.edits, description: "t")
        let after = read(claudeJSON)
        #expect(after.contains("\"numStartups\": 13") && after.contains("\"local-db\""))
    }

    @Test func keepsPermissionsAndSymlinks() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let claudeJSON = f.home.appending(path: ".claude.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: claudeJSON.path)
        let dotfiles = f.root.appending(path: "dotfiles/settings.json")
        try FileManager.default.createDirectory(at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        let settings = f.home.appending(path: ".claude/settings.json")
        try FileManager.default.moveItem(at: settings, to: dotfiles)
        try FileManager.default.createSymbolicLink(at: settings, withDestinationURL: dotfiles)

        let e = engine(f)
        try writer(f).apply(try e.plan(toggle(f, "claude|local|local-db"), on: false, scope: .folder, folder: f.project).edits, description: "t")
        try writer(f).apply(try e.plan(toggle(f, "claude|plugin|figma@market"), on: true, scope: .user, folder: f.project).edits, description: "t")
        #expect((try FileManager.default.attributesOfItem(atPath: claudeJSON.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: settings.path)) != nil)
        #expect(read(dotfiles).contains("\"figma@market\": true"))
        let backups = try FileManager.default.contentsOfDirectory(atPath: f.root.appending(path: "backups").path).filter { $0 != "last-change.json" }
        #expect(backups.count == 2)
    }

    @Test func waitsForTheLock() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let claudeJSON = f.home.appending(path: ".claude.json")
        try FileManager.default.createDirectory(atPath: claudeJSON.path + ".lock", withIntermediateDirectories: false)
        var w = writer(f)
        w.lockAttempts = 2
        let plan = try engine(f).plan(toggle(f, "claude|local|local-db"), on: false, scope: .folder, folder: f.project)
        #expect(throws: ConfigEditError.locked(claudeJSON.path)) { try w.apply(plan.edits, description: "t") }
    }

    @Test func warnsWhenLocalSettingsAreNotIgnored() throws {
        let f = try fixture()
        defer { f.cleanup() }
        try FileManager.default.removeItem(at: f.project.appending(path: ".git"))
        let git = Process()
        git.executableURL = URL(filePath: "/usr/bin/git")
        git.arguments = ["-C", f.project.path, "init", "-q"]
        try git.run()
        git.waitUntilExit()
        // A global excludes file could ignore it; this repo's own config must decide.
        let config = Process()
        config.executableURL = URL(filePath: "/usr/bin/git")
        config.arguments = ["-C", f.project.path, "config", "core.excludesFile", "/dev/null"]
        try config.run()
        config.waitUntilExit()
        let plan = try engine(f).plan(toggle(f, "claude|plugin|figma@market"), on: false, scope: .folder, folder: f.project)
        #expect(plan.warnings.contains { $0.contains("not git-ignored") })
        try f.write(".gitignore", ".claude/settings.local.json\n", base: f.project)
        let ignored = try engine(f).plan(toggle(f, "claude|plugin|figma@market"), on: false, scope: .folder, folder: f.project)
        #expect(ignored.warnings.isEmpty)
    }

    // MARK: Codex

    @Test func codexKeepsCommentsAndSupportsTrustedProjects() throws {
        let f = try fixture()
        defer { f.cleanup() }
        let config = f.home.appending(path: ".codex/config.toml")
        let original = """
        # my config
        model = "m"

        [mcp_servers.docs] # docs server
        command = "docs"
        args = ["--x"] # flags

        [mcp_servers.docs.env]
        A = "b"

        [projects."\(f.project.path)"]
        trust_level = "trusted"

        """
        try f.write(".codex/config.toml", original, base: f.home)
        let e = engine(f), w = writer(f)
        try w.apply(try e.plan(toggle(f, "codex|server|docs", harness: .codex), on: false, scope: .user, folder: f.project).edits, description: "t")
        #expect(read(config) == original.replacingOccurrences(of: "[mcp_servers.docs] # docs server\n", with: "[mcp_servers.docs] # docs server\nenabled = false\n"))
        #expect(toggle(f, "codex|server|docs", harness: .codex).state == "off everywhere")

        // On here: the project's .codex/config.toml overrides the user value.
        try w.apply(try e.plan(toggle(f, "codex|server|docs", harness: .codex), on: true, scope: .folder, folder: f.project).edits, description: "t")
        #expect(read(f.project.appending(path: ".codex/config.toml")) == "[mcp_servers.docs]\nenabled = true\n")
        let t = toggle(f, "codex|server|docs", harness: .codex)
        #expect(t.on && t.state == "off everywhere, on here")

        // Undo removes the table it added; on everywhere removes the line it added.
        try w.undoLast()
        #expect(read(f.project.appending(path: ".codex/config.toml")) == "")
        try w.apply(try e.plan(toggle(f, "codex|server|docs", harness: .codex), on: true, scope: .user, folder: f.project).edits, description: "t")
        #expect(read(config) == original)
    }

    @Test func codexRefusesServersWithoutATable() throws {
        #expect(throws: ConfigEditError.self) {
            _ = try TOMLEdit.setEnabled("mcp_servers.docs.command = \"x\"\n", server: "docs", value: false, createTable: false, file: "c")
        }
        let quoted = try TOMLEdit.setEnabled("[mcp_servers.\"my.server\"]\ncommand = \"x\"\n", server: "my.server", value: false, createTable: false, file: "c")
        #expect(quoted.0 == "[mcp_servers.\"my.server\"]\nenabled = false\ncommand = \"x\"\n")
    }

    /// Lines that start with "[" inside arrays and strings, and `[[tables]]`, don't end the
    /// server's table: `enabled` lands in the right table and nowhere else.
    @Test func codexTableBoundaries() throws {
        let text = """
        [mcp_servers.docs]
        args = [
          ["nested", "array"],
        ]
        description = \"\"\"
        [not.a.table]
        \"\"\"
        enabled = true # mine

        [[profiles]]
        enabled = true
        """
        let (out, old) = try TOMLEdit.setEnabled(text, server: "docs", value: false, createTable: false, file: "c")
        #expect(old == true)
        #expect(out == text.replacingOccurrences(of: "enabled = true # mine", with: "enabled = false  # mine"))

        let other = "[mcp_servers.docs]\ncommand = \"x\"\n\n[[profiles]]\nenabled = true\n"
        let (inserted, _) = try TOMLEdit.setEnabled(other, server: "docs", value: false, createTable: false, file: "c")
        #expect(inserted == "[mcp_servers.docs]\nenabled = false\ncommand = \"x\"\n\n[[profiles]]\nenabled = true\n")
    }

    @Test func refusesInvalidTOML() {
        #expect(throws: ConfigEditError.self) {
            _ = try TOMLEdit.setEnabled("[mcp_servers.docs]\ncommand = \n", server: "docs", value: false, createTable: false, file: "c")
        }
    }

    @Test func codexUntrustedProjectHasNoFolderScope() throws {
        let f = try fixture()
        defer { f.cleanup() }
        try f.write(".codex/config.toml", "[mcp_servers.docs]\ncommand = \"docs\"\n", base: f.home)
        #expect(toggle(f, "codex|server|docs", harness: .codex).scopes == [.user])
    }
}

import Foundation
import TOMLKit

/// Where a switch writes. `folder` is the folder's project (its git root, or the folder itself),
/// which is also where `claude plugin --scope local` and `/mcp disable` write.
public enum ToggleScope: String, Codable, CaseIterable, Sendable {
    case folder
    case user

    public var label: String { self == .folder ? "This folder" : "Everywhere" }
}

/// One MCP server, or one plugin that brings MCP servers, that can be switched on or off.
public struct McpToggle: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A server in ~/.claude.json (user or local) or .mcp.json, or in Codex's config.toml.
        case server
        /// A Claude Code plugin; switching it switches all its MCP servers (and its skills).
        case plugin
        /// Not in any file Context Lens switches: claude.ai connectors, Claude Desktop's own tools.
        case fixed
    }

    public var id: String
    public var harness: Harness
    public var kind: Kind
    public var name: String
    /// User, Local, Project or Plugin (Claude Code); User or Project (Codex).
    public var definedIn: String
    /// The MCP servers this switches, as /context names them (`plugin_figma_figma`).
    public var servers: [String]
    public var on: Bool
    /// "off everywhere, on here"
    public var state: String
    /// What each scope says today: nil when that scope doesn't set it.
    public var userValue: Bool?
    public var folderValue: Bool?
    public var scopes: [ToggleScope]
    public var note: String?
    /// Measured cost of the tool schemas, from the folder's latest /context measurement, else the
    /// latest one anywhere that has these servers.
    public var tokens: Int?
    public var tokensFrom: String?
    /// The plugin key (`figma@claude-plugins-official`) for plugins.
    public var pluginKey: String?
}

public struct McpToggleList: Codable, Sendable {
    public var folder: String
    /// The folder whose settings the folder scope writes.
    public var projectRoot: String
    public var toggles: [McpToggle]
    public var notes: [String]
}

/// The change one switch makes, with what it writes, for the confirmation.
public struct TogglePlan: Sendable {
    public var toggle: McpToggle
    public var on: Bool
    public var scope: ToggleScope
    public var edits: [ConfigEdit]
    public var warnings: [String]
    /// "Turn figma off everywhere"
    public var description: String
}

/// Lists MCP servers and plugins with their on/off state for a folder, and plans the config edits
/// that switch them, using the keys the harnesses themselves write (docs/harness-rules.md,
/// "Switching MCP servers").
public struct McpToggleEngine: Sendable {
    public var env: HarnessEnvironment
    public var measurements: MeasuredContextStore?

    public init(env: HarnessEnvironment = .current, measurements: MeasuredContextStore? = nil) {
        self.env = env
        self.measurements = measurements
    }

    var claudeJSON: String { env.home.appending(path: ".claude.json").path }
    var userSettings: String { env.claudeHome.appending(path: "settings.json").path }
    var managedSettings: String { env.managedClaudeMd.deletingLastPathComponent().appending(path: "managed-settings.json").path }
    var codexConfig: String { env.codexHome.appending(path: "config.toml").path }

    func projectRoot(_ folder: URL) -> URL {
        let folder = FileUtil.realPath(folder)
        return Git.roots(for: folder)?.worktree ?? folder
    }

    func localSettings(_ root: URL) -> String { root.appending(path: ".claude/settings.local.json").path }

    static func readJSON(_ path: String) -> JSONValue? {
        (try? String(contentsOfFile: path, encoding: .utf8)).flatMap { try? JSONValue.parse($0) }
    }

    public func list(folder: URL, harness: Harness) -> McpToggleList {
        harness == .claude ? claude(folder: folder) : codex(folder: folder)
    }

    // MARK: - Claude Code

    struct Layer {
        var label: String
        var path: String
        var json: JSONValue?
    }

    /// Settings files in the order Claude Code merges them, later wins: user, project, local, then
    /// the same two in the folder itself when it is below the project root. Managed settings are
    /// read only for their deny list.
    func claudeLayers(folder: URL, root: URL) -> [Layer] {
        var layers = [Layer(label: "user", path: userSettings, json: nil)]
        var dirs = [root]
        let folder = FileUtil.realPath(folder)
        if folder != root { dirs.append(folder) }
        for dir in dirs {
            let rel = dir == root ? "" : " (\(folder.lastPathComponent))"
            layers.append(Layer(label: "project settings" + rel, path: dir.appending(path: ".claude/settings.json").path, json: nil))
            layers.append(Layer(label: "here" + rel, path: localSettings(dir), json: nil))
        }
        return layers.map { var l = $0; l.json = Self.readJSON(l.path); return l }
    }

    struct Plugin {
        var key: String
        var name: String
        var servers: [String]
    }

    /// Installed plugins that bring MCP servers: `.mcp.json` in the plugin, or `mcpServers` in its
    /// plugin.json (inline, or a path to a JSON file).
    func installedPlugins() -> [Plugin] {
        let installed = Self.readJSON(env.claudeHome.appending(path: "plugins/installed_plugins.json").path)?["plugins"]?.members ?? []
        return installed.compactMap { m in
            guard let path = m.value.array?.last?["installPath"]?.string else { return nil }
            let dir = URL(filePath: path)
            var servers: [String] = []
            func add(_ v: JSONValue?) {
                let map = v?["mcpServers"] ?? v
                for s in map?.members ?? [] where s.value.members != nil && !servers.contains(s.key) { servers.append(s.key) }
            }
            add(Self.readJSON(dir.appending(path: ".mcp.json").path))
            let manifest = Self.readJSON(dir.appending(path: ".claude-plugin/plugin.json").path)
            if let ref = manifest?["mcpServers"]?.string {
                add(Self.readJSON(dir.appending(path: ref).path))
            } else if let inline = manifest?["mcpServers"] {
                add(.object([.init("mcpServers", inline)]))
            }
            guard !servers.isEmpty else { return nil }
            let name = String(m.key.split(separator: "@").first ?? Substring(m.key))
            return Plugin(key: m.key, name: name, servers: servers)
        }.sorted { $0.key < $1.key }
    }

    static func describe(user: Bool?, project: Bool?, here: Bool?, defaultOn: Bool) -> String {
        var parts: [String] = []
        if let user { parts.append(user ? "on everywhere" : "off everywhere") }
        if let project { parts.append(project ? "on in project settings" : "off in project settings") }
        if let here { parts.append(here ? "on here" : "off here") }
        return parts.isEmpty ? (defaultOn ? "on everywhere" : "not enabled") : parts.joined(separator: ", ")
    }

    func claude(folder: URL) -> McpToggleList {
        let root = projectRoot(folder)
        let layers = claudeLayers(folder: folder, root: root)
        let managed = Self.readJSON(managedSettings)
        let config = Self.readJSON(claudeJSON)
        let project = config?["projects"]?[root.path]
        let disabledHere = Set((project?["disabledMcpServers"]?.array ?? []).compactMap(\.string))
        var toggles: [McpToggle] = []

        // Plugins: enabledPlugins, later layers win.
        for plugin in installedPlugins() {
            func value(_ l: Layer?) -> Bool? { l?.json?["enabledPlugins"]?[plugin.key]?.bool }
            let user = value(layers.first)
            let projectValue = layers.filter { $0.label.hasPrefix("project") }.compactMap(value).last
            let here = layers.filter { $0.label.hasPrefix("here") }.compactMap(value).last
            var on = here ?? projectValue ?? user ?? false
            var state = Self.describe(user: user, project: projectValue, here: here, defaultOn: false)
            let mcpNames = plugin.servers.map { "plugin:\(plugin.name):\($0)" }
            let offByMcp = mcpNames.filter(disabledHere.contains)
            if on, !offByMcp.isEmpty {
                state += offByMcp.count == mcpNames.count ? "; server off here (/mcp)" : "; \(offByMcp.count) of its servers off here (/mcp)"
                if offByMcp.count == mcpNames.count { on = false }
            }
            let servers = plugin.servers.map { "plugin_\(plugin.name)_\($0)" }
            toggles.append(McpToggle(
                id: "claude|plugin|\(plugin.key)", harness: .claude, kind: .plugin, name: plugin.name, definedIn: "Plugin",
                servers: servers, on: on, state: state, userValue: user, folderValue: here, scopes: [.folder, .user],
                note: "Switching a plugin also switches its skills\(plugin.servers.count > 1 ? " and all \(plugin.servers.count) of its MCP servers" : "").",
                pluginKey: plugin.key))
        }

        // Servers in ~/.claude.json and .mcp.json.
        func denied(_ name: String) -> [String] {
            var out: [String] = []
            if Self.denies(managed, name) { out.append("managed settings") }
            for l in layers where Self.denies(l.json, name) { out.append(l.label == "user" ? "user" : l.label) }
            return out
        }
        for m in config?["mcpServers"]?.members ?? [] {
            let deny = denied(m.key)
            let userOff = deny.contains("user")
            let here = disabledHere.contains(m.key) ? false : nil
            var state = Self.describe(user: userOff ? false : nil, project: nil, here: here, defaultOn: true)
            var note: String? = "Everywhere adds it to deniedMcpServers in ~/.claude/settings.json; a folder can't turn a denied server back on."
            if let other = deny.first(where: { $0 != "user" }) { state = "blocked by \(other)"; note = "deniedMcpServers in \(other) blocks it; Context Lens doesn't edit that file." }
            toggles.append(McpToggle(
                id: "claude|user|\(m.key)", harness: .claude, kind: .server, name: m.key, definedIn: "User",
                servers: [m.key], on: deny.isEmpty && here == nil, state: state, userValue: userOff ? false : nil, folderValue: here,
                scopes: deny.contains { $0 != "user" } ? [] : [.folder, .user], note: note))
        }
        for m in project?["mcpServers"]?.members ?? [] {
            let deny = denied(m.key)
            let here = disabledHere.contains(m.key) ? false : nil
            toggles.append(McpToggle(
                id: "claude|local|\(m.key)", harness: .claude, kind: .server, name: m.key, definedIn: "Local",
                servers: [m.key], on: deny.isEmpty && here == nil,
                state: deny.first.map { "blocked by \($0 == "user" ? "user settings" : $0)" } ?? (here == nil ? "on here" : "off here"),
                userValue: nil, folderValue: here, scopes: deny.isEmpty ? [.folder] : [],
                note: "Defined for this folder only, in ~/.claude.json."))
        }
        let mcpJSON = Self.readJSON(root.appending(path: ".mcp.json").path)
        for m in mcpJSON?["mcpServers"]?.members ?? [] {
            func list(_ key: String) -> [Layer] { layers.filter { l in l.json?[key]?.array?.contains(.string(m.key)) == true } }
            let disabledIn = list("disabledMcpjsonServers")
            let approved = !list("enabledMcpjsonServers").isEmpty || layers.contains { $0.json?["enableAllProjectMcpServers"]?.bool == true }
            let deny = denied(m.key)
            let on = deny.isEmpty && disabledIn.isEmpty && approved
            let state = deny.first.map { "blocked by \($0 == "user" ? "user settings" : $0)" }
                ?? (disabledIn.isEmpty ? (approved ? "on here" : "waiting for approval") : "off " + (disabledIn.last!.label.hasPrefix("here") ? "here" : "in \(disabledIn.last!.label)"))
            toggles.append(McpToggle(
                id: "claude|project|\(m.key)", harness: .claude, kind: .server, name: m.key, definedIn: "Project",
                servers: [m.key], on: on, state: state, userValue: nil,
                folderValue: disabledIn.contains { $0.label.hasPrefix("here") } ? false : (approved ? true : nil),
                scopes: deny.isEmpty ? [.folder] : [], note: "From .mcp.json; the switch writes enabledMcpjsonServers / disabledMcpjsonServers in .claude/settings.local.json."))
        }

        addCosts(&toggles, folder: folder)
        var notes = ["Claude Desktop's built-in MCP tools are set in the Desktop app and can't be switched here."]
        // Servers a measurement saw that no config file here defines: claude.ai connectors and the like.
        if let m = measurements?.cached(FileUtil.realPath(folder).path) {
            let known = Set(toggles.flatMap(\.servers).map(MeasuredContext.serverKey))
            for row in m.mcpServers where !known.contains(MeasuredContext.serverKey(row.name)) {
                toggles.append(McpToggle(
                    id: "claude|fixed|\(row.name)", harness: .claude, kind: .fixed, name: row.name, definedIn: "Other",
                    servers: [row.name], on: true, state: "not in a file Context Lens switches", scopes: [],
                    note: "Measured by /context but not defined in ~/.claude.json, .mcp.json or a plugin: likely a claude.ai connector (switch it in /mcp).",
                    tokens: row.tokens, tokensFrom: Self.from(m)))
            }
            notes.append("Costs from claude /context, \(Self.dateTime(m.measuredAt)).")
        }
        return McpToggleList(folder: FileUtil.realPath(folder).path, projectRoot: root.path, toggles: toggles, notes: notes)
    }

    static func denies(_ settings: JSONValue?, _ name: String) -> Bool {
        (settings?["deniedMcpServers"]?.array ?? []).contains { $0["serverName"]?.string == name }
    }

    static func from(_ m: MeasuredContext) -> String {
        "\(FileUtil.abbreviate(m.folder, home: HarnessEnvironment.userHome)), \(dateTime(m.measuredAt))"
    }

    /// "7 Oct 15:00"
    static func dateTime(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    func addCosts(_ toggles: inout [McpToggle], folder: URL) {
        guard let store = measurements else { return }
        let here = store.cached(FileUtil.realPath(folder).path)
        var everywhere: [MeasuredContext]?
        for i in toggles.indices {
            let servers = toggles[i].servers
            func cost(_ m: MeasuredContext) -> Int? {
                let found = servers.compactMap(m.mcpSchemas)
                return found.isEmpty ? nil : found.reduce(0, +)
            }
            if let here, let c = cost(here) {
                toggles[i].tokens = c
                toggles[i].tokensFrom = Self.from(here)
                continue
            }
            if everywhere == nil { everywhere = store.all() }
            if let m = everywhere?.last(where: { cost($0) != nil }) {
                toggles[i].tokens = cost(m)
                toggles[i].tokensFrom = Self.from(m)
            }
        }
    }

    // MARK: - Codex

    func codexTrusted(_ root: URL, config: TOMLTable?) -> Bool {
        config?["projects"]?.table?[root.path]?.table?["trust_level"]?.string == "trusted"
    }

    func codexProjectConfig(_ root: URL) -> String { root.appending(path: ".codex/config.toml").path }

    func codex(folder: URL) -> McpToggleList {
        let root = projectRoot(folder)
        let user = (try? String(contentsOfFile: codexConfig, encoding: .utf8)).flatMap { try? TOMLTable(string: $0) }
        let trusted = codexTrusted(root, config: user)
        let project = trusted ? (try? String(contentsOfFile: codexProjectConfig(root), encoding: .utf8)).flatMap { try? TOMLTable(string: $0) } : nil
        let userServers = user?["mcp_servers"]?.table
        let projectServers = project?["mcp_servers"]?.table
        var names = userServers?.keys.sorted() ?? []
        for k in projectServers?.keys.sorted() ?? [] where !names.contains(k) { names.append(k) }
        var toggles: [McpToggle] = []
        for name in names {
            let definedIn = userServers?[name] != nil ? "User" : "Project"
            let u = userServers?[name]?.table?["enabled"]?.bool
            let p = projectServers?[name]?.table?["enabled"]?.bool
            toggles.append(McpToggle(
                id: "codex|server|\(name)", harness: .codex, kind: .server, name: name, definedIn: definedIn,
                servers: [name], on: p ?? u ?? true, state: Self.describe(user: u, project: nil, here: p, defaultOn: true),
                userValue: u, folderValue: p, scopes: (trusted ? [.folder] : []) + (definedIn == "User" ? [.user] : []),
                note: trusted ? "This folder writes .codex/config.toml in the project, which Codex reads for trusted projects." : "This folder: Codex reads a project's .codex/config.toml only when the project is trusted."))
        }
        return McpToggleList(folder: FileUtil.realPath(folder).path, projectRoot: root.path, toggles: toggles,
                             notes: ["Codex: no /context measurement, so no costs.",
                                     "Servers that Codex plugins bring (codex mcp list shows them) are switched with the plugin in Codex, not here."])
    }

    // MARK: - Planning

    /// The edits that turn `toggle` on or off at `scope`.
    public func plan(_ toggle: McpToggle, on: Bool, scope: ToggleScope, folder: URL) throws -> TogglePlan {
        guard toggle.scopes.contains(scope) else {
            throw ConfigEditError.notAllowed(toggle.kind == .fixed
                ? "\(toggle.name) isn't defined in a file Context Lens switches."
                : "\(toggle.name) can't be switched \(scope == .user ? "everywhere" : "for this folder"). \(toggle.note ?? "")")
        }
        let root = projectRoot(folder)
        var edits: [ConfigEdit] = []
        var warnings: [String] = []
        let local = localSettings(root)
        switch (toggle.harness, toggle.kind) {
        case (.claude, .plugin):
            guard let key = toggle.pluginKey else { throw ConfigEditError.unknown(toggle.name) }
            if scope == .user {
                edits.append(.jsonValue(file: userSettings, path: ["enabledPlugins", key], value: .bool(on)))
                if let here = toggle.folderValue, here != on { warnings.append("It stays \(here ? "on" : "off") here: this folder's settings switch it \(here ? "on" : "off").") }
            } else {
                // A folder value equal to what applies without it is removed rather than repeated.
                let layers = claudeLayers(folder: folder, root: root)
                let inherited = layers.filter { !$0.label.hasPrefix("here") }.compactMap { $0.json?["enabledPlugins"]?[key]?.bool }.last ?? false
                edits.append(.jsonValue(file: local, path: ["enabledPlugins", key], value: on == inherited ? nil : .bool(on)))
                if on {
                    // A server switched off with /mcp would stay off.
                    for s in toggle.servers {
                        let name = "plugin:\(toggle.name):\(s.dropFirst("plugin_\(toggle.name)_".count))"
                        edits.append(.jsonMember(file: claudeJSON, path: ["projects", root.path, "disabledMcpServers"], element: .string(name), present: false, parent: nil))
                    }
                }
                warnings += gitIgnoreWarning(root, ".claude/settings.local.json")
            }
        case (.claude, .server):
            if scope == .user {
                edits.append(.jsonMember(file: userSettings, path: ["deniedMcpServers"], element: .object([.init("serverName", .string(toggle.name))]), present: !on, parent: nil))
                if on, toggle.folderValue == false { warnings.append("It stays off here: it is also switched off for this folder.") }
            } else if toggle.definedIn == "Project" {
                edits.append(.jsonMember(file: local, path: ["disabledMcpjsonServers"], element: .string(toggle.name), present: !on, parent: nil))
                edits.append(.jsonMember(file: local, path: ["enabledMcpjsonServers"], element: .string(toggle.name), present: on, parent: nil))
                warnings += gitIgnoreWarning(root, ".claude/settings.local.json")
            } else {
                if on, toggle.userValue == false {
                    throw ConfigEditError.notAllowed("\(toggle.name) is off everywhere (deniedMcpServers in ~/.claude/settings.json), and a folder can't override a deny. Turn it on everywhere first, then off in the folders that don't need it.")
                }
                edits.append(.jsonMember(file: claudeJSON, path: ["projects", root.path, "disabledMcpServers"], element: .string(toggle.name), present: !on, parent: Self.projectDefaults))
            }
        case (.codex, .server):
            if scope == .user {
                edits.append(.tomlEnabled(file: codexConfig, server: toggle.name, value: on ? nil : false, createTable: false))
                if on, toggle.folderValue == false { warnings.append("It stays off here: the project's .codex/config.toml switches it off.") }
            } else {
                let inherited = toggle.userValue ?? true
                edits.append(.tomlEnabled(file: codexProjectConfig(root), server: toggle.name, value: on == inherited ? nil : on, createTable: true))
                warnings += gitIgnoreWarning(root, ".codex/config.toml")
            }
        default:
            throw ConfigEditError.notAllowed("\(toggle.name) can't be switched.")
        }
        let description = "Turn \(toggle.name) \(on ? "on" : "off") \(scope == .user ? "everywhere" : "in \(root.lastPathComponent)")"
        return TogglePlan(toggle: toggle, on: on, scope: scope, edits: edits, warnings: warnings, description: description)
    }

    /// What Claude Code puts in a project entry it creates (read from the 2.1.281 binary).
    static let projectDefaults: JSONValue = .object([
        .init("allowedTools", .array([])), .init("mcpContextUris", .array([])), .init("mcpServers", .object([])),
        .init("enabledMcpjsonServers", .array([])), .init("disabledMcpjsonServers", .array([])),
        .init("hasTrustDialogAccepted", .bool(false)), .init("hasClaudeMdExternalIncludesApproved", .bool(false)),
        .init("hasClaudeMdExternalIncludesWarningShown", .bool(false)),
    ])

    /// A folder-scope file that git would commit is shared with everyone on the repo.
    func gitIgnoreWarning(_ root: URL, _ relative: String) -> [String] {
        guard FileUtil.exists(root.appending(path: ".git")) else { return [] }
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/git")
        p.arguments = ["-C", root.path, "check-ignore", "-q", relative]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        p.waitUntilExit()
        return p.terminationStatus == 1 ? ["\(relative) is not git-ignored in \(root.lastPathComponent): this change would show up in git status and could be committed."] : []
    }

    /// Finds a toggle by server name, plugin name or plugin key.
    public static func find(_ name: String, in list: McpToggleList) -> McpToggle? {
        let switchable = list.toggles.filter { $0.kind != .fixed }
        return switchable.first { $0.pluginKey == name } ?? switchable.first { $0.name == name }
            ?? switchable.first { $0.servers.contains(name) }
    }
}


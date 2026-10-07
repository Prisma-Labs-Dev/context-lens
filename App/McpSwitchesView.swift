import ContextLensCore
import SwiftUI

/// Switching MCP servers and plugins in the harnesses' own settings files. Unlike presets this
/// changes what every plain launch loads, so it lives behind its own Settings sheet, shows the
/// exact edit the first time (and whenever there is a warning), backs every file up and can undo.
extension AppModel {
    func openMcpSwitches() {
        showingMcpSwitches = true
        lastSwitch = configWriter.lastChange()
        loadMcpSwitches()
    }

    func loadMcpSwitches() {
        guard let dir = selectedDirectory else { mcpSwitches = nil; return }
        let harness = harness
        Task {
            let list = await Task.detached(priority: .userInitiated) {
                McpToggleEngine(measurements: MeasuredContextStore()).list(folder: URL(filePath: dir), harness: harness)
            }.value
            guard selectedDirectory == dir, self.harness == harness else { return }
            mcpSwitches = list
        }
    }

    /// The first switch, and any with a warning, waits for confirmation with the diff.
    func requestSwitch(_ toggle: McpToggle, on: Bool) {
        guard let dir = selectedDirectory else { return }
        switchError = nil
        do {
            let plan = try McpToggleEngine().plan(toggle, on: on, scope: mcpScope, folder: URL(filePath: dir))
            let previews = try configWriter.preview(plan.edits)
            guard !previews.isEmpty else { loadMcpSwitches(); return }
            if UserDefaults.standard.bool(forKey: "mcpSwitchConfirmed") && plan.warnings.isEmpty {
                apply(plan)
            } else {
                pendingSwitch = (plan, previews)
            }
        } catch {
            switchError = "\(error)"
        }
    }

    func confirmSwitch() {
        guard let pending = pendingSwitch else { return }
        pendingSwitch = nil
        UserDefaults.standard.set(true, forKey: "mcpSwitchConfirmed")
        apply(pending.plan)
    }

    private func apply(_ plan: TogglePlan) {
        do {
            let before = measured
            if let applied = try configWriter.apply(plan.edits, description: plan.description) {
                lastSwitch = applied
                measuredBeforeSwitch = before
                notice = "\(plan.description). Running sessions keep their tools until restarted."
            }
        } catch {
            switchError = "\(error)"
        }
        loadMcpSwitches()
        reloadSnapshot()
    }

    func undoSwitch() {
        do {
            if let undone = try configWriter.undoLast() { notice = undone.description + "." }
        } catch {
            switchError = "\(error)"
        }
        lastSwitch = configWriter.lastChange()
        loadMcpSwitches()
        reloadSnapshot()
    }
}

struct McpSwitchesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "switch.2").foregroundStyle(Theme.ink2)
                Text("MCP servers and plugins").font(.system(size: 14, weight: .semibold))
                Text("\(model.harness.displayName) · \(model.selectedDirectory.map { URL(filePath: $0).lastPathComponent } ?? "")")
                    .font(Theme.small).foregroundStyle(Theme.ink3)
                Spacer()
                Picker("Scope", selection: $model.mcpScope) {
                    ForEach(ToggleScope.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help(scopeHelp)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
            Text("Settings, not a preset: a switch edits \(model.harness.displayName)'s own config, so every new session \(model.mcpScope == .folder ? "in this project" : "everywhere") loads it this way. Each file is backed up to ~/.context-lens/backups first.")
                .font(Theme.small).foregroundStyle(Theme.ink2).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            if let pending = model.pendingSwitch {
                SwitchConfirmation(plan: pending.plan, previews: pending.previews)
            } else {
                switchList
            }
            Rectangle().fill(Theme.hairline).frame(height: 1)
            footer
        }
        .frame(width: 680, height: 520)
        .background(Theme.window)
    }

    private var scopeHelp: String {
        model.harness == .claude
            ? "This folder: the project's .claude/settings.local.json (plugins, .mcp.json servers) or its entry in ~/.claude.json (other servers, like /mcp disable). Everywhere: ~/.claude/settings.json."
            : "This folder: the project's .codex/config.toml (trusted projects only). Everywhere: ~/.codex/config.toml."
    }

    private var switchList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let list = model.mcpSwitches {
                    if list.toggles.isEmpty {
                        Text("No MCP servers or plugins with MCP tools here.").font(Theme.body).foregroundStyle(Theme.ink3).padding(16)
                    }
                    ForEach(list.toggles) { SwitchRow(toggle: $0) }
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(list.notes, id: \.self) { Text($0) }
                    }
                    .font(Theme.small).foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(30)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.switchError {
                Text(error).font(Theme.small).foregroundStyle(Theme.removed).fixedSize(horizontal: false, vertical: true)
            }
            if let last = model.lastSwitch {
                HStack(spacing: 6) {
                    Text("Last change: \(last.description), \(Format.dateTime(last.date))").font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(1)
                    QuietButton(title: "Undo", systemImage: "arrow.uturn.backward") { model.undoSwitch() }
                        .help("Put back what the last switch changed, in " + last.files.map { model.abbreviate($0) }.joined(separator: ", "))
                    if model.harness == .claude {
                        QuietButton(title: model.measuring ? "Measuring…" : "Measure again", systemImage: "gauge.with.dots.needle.33percent") { model.measure() }
                            .disabled(model.measuring)
                            .help("Run claude -p \"/context\" here to see the saving: a few seconds, no tokens.")
                    }
                }
                if model.harness == .claude, let now = model.measured, let before = model.measuredBeforeSwitch, now.measuredAt > last.date {
                    MeasurementDiff(current: now, previous: before)
                }
            }
            HStack {
                Text("Running sessions keep their tools until they restart.").font(Theme.small).foregroundStyle(Theme.ink3)
                Spacer()
                if model.pendingSwitch == nil {
                    Button("Done") { model.showingMcpSwitches = false; dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// One server or plugin: switch, name, where it is defined, its state per scope and its cost.
struct SwitchRow: View {
    @Environment(AppModel.self) private var model
    var toggle: McpToggle

    var body: some View {
        let allowed = toggle.scopes.contains(model.mcpScope)
        HStack(spacing: 8) {
            if toggle.kind == .fixed {
                Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(Theme.ink3).frame(width: 32)
            } else {
                Toggle("", isOn: Binding(get: { toggle.on }, set: { model.requestSwitch(toggle, on: $0) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .disabled(!allowed)
                    .frame(width: 32)
            }
            Text(toggle.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
            Text(toggle.definedIn).font(.system(size: 10, weight: .medium)).foregroundStyle(Theme.ink3)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.hairline))
            Text(toggle.state).font(Theme.small).foregroundStyle(toggle.on ? Theme.ink2 : Theme.ink3).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 6)
            Text(toggle.tokens.map(Format.tokens) ?? "–")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(toggle.on ? Theme.ink : Theme.ink3)
                .frame(minWidth: 44, alignment: .trailing)
                .help(toggle.tokensFrom.map { "MCP tool schemas, measured by claude /context in \($0)" } ?? "Not measured yet: Measure in a folder where it is on.")
        }
        .padding(.horizontal, 16)
        .frame(height: 28)
        .opacity(toggle.kind == .fixed ? 0.7 : 1)
        .help(help(allowed: allowed))
    }

    private func help(allowed: Bool) -> String {
        var lines = [toggle.note].compactMap { $0 }
        if !allowed, toggle.kind != .fixed {
            lines.insert("Can't be switched \(model.mcpScope == .user ? "everywhere" : "for this folder"); try the other scope.", at: 0)
        }
        return lines.joined(separator: "\n")
    }
}

/// What a switch will write, file by file, before it writes it.
struct SwitchConfirmation: View {
    @Environment(AppModel.self) private var model
    var plan: TogglePlan
    var previews: [ConfigWriter.Preview]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(plan.description).font(.system(size: 13, weight: .semibold))
            ForEach(plan.warnings, id: \.self) { w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(Theme.small).foregroundStyle(Theme.stale)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(previews, id: \.file) { p in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.abbreviate(p.file) + (p.before == nil ? " (new file)" : "")).font(Theme.small).foregroundStyle(Theme.ink2)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(p.diff.enumerated()), id: \.offset) { _, line in
                                    Text(line.unified).font(Theme.monoSmall)
                                        .foregroundStyle(line.kind == .added ? Theme.added : line.kind == .removed ? Theme.removed : Theme.ink3)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(line.kind == .added ? Theme.added.opacity(0.08) : line.kind == .removed ? Theme.removed.opacity(0.08) : .clear)
                                }
                            }
                            .padding(6)
                            .background(RoundedRectangle(cornerRadius: 5).fill(Theme.editor))
                        }
                    }
                }
            }
            Text("Backed up to ~/.context-lens/backups before writing; Undo puts it back. After this one, switches apply without asking unless there is a warning.")
                .font(Theme.small).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.pendingSwitch = nil; model.loadMcpSwitches() }.keyboardShortcut(.cancelAction)
                Button("Write") { model.confirmSwitch() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

/// The Settings affordance in the top bar.
struct McpSwitchesButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        IconButton(systemImage: "switch.2", help: "MCP settings: switch MCP servers and plugins on or off for this folder or everywhere (edits \(model.harness.displayName)'s settings)") {
            model.openMcpSwitches()
        }
        .disabled(model.selectedDirectory == nil)
    }
}

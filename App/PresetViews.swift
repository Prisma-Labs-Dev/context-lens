import ContextLensCore
import SwiftUI

/// Top-bar menu: pick, create, rename and delete presets.
struct PresetPicker: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Menu {
            Section("Presets") {
                ForEach(model.presets) { p in
                    Button { model.select(preset: p.id) } label: {
                        Label(p.name, systemImage: p.id == model.preset.id ? "checkmark" : (p.isBuiltIn ? "square.stack" : "slider.horizontal.3"))
                    }
                }
            }
            Divider()
            Button("New Preset from “\(model.preset.name)”…") { model.namingPreset = .new }
            if !model.preset.isBuiltIn {
                Button("Rename “\(model.preset.name)”…") { model.namingPreset = .rename }
                Button("Delete “\(model.preset.name)”", role: .destructive) { model.deletePreset() }
            }
            Divider()
            Button(model.cliInstalled ? "Command Line Tool Installed" : "Install Command Line Tool") { model.installCLI() }
                .disabled(model.cliInstalled)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.preset.isBuiltIn ? "square.stack" : "slider.horizontal.3").font(.system(size: 11))
                Text(model.preset.name).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.ink3)
            }
            .font(.system(size: 12, weight: model.presetIsActive ? .medium : .regular))
            .foregroundStyle(model.presetApplies ? Theme.ink : Theme.ink3)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(model.presetIsActive ? Theme.preset.opacity(0.14) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(model.presetIsActive ? Theme.preset.opacity(0.5) : Theme.hairline))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(!model.presetApplies)
        .help(model.presetApplies
            ? "Preset: what the harness loads when you launch it from here. Files on disk are never changed."
            : "Presets shape new launches. Switch the source back to Now to use one.")
    }
}

/// Starts the harness in Terminal under the selected preset; the chevron menu copies the command.
struct LaunchButton: View {
    @Environment(AppModel.self) private var model
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button { model.launch() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 8.5))
                    Text("Launch")
                }
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.leading, 10)
                .padding(.trailing, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Terminal here and start \(model.harness.displayName) with the \(model.preset.name) preset")
            Rectangle().fill(.white.opacity(0.35)).frame(width: 1, height: 14)
            Menu {
                Button("Copy Command") { model.copyCommand() }
                Button(model.cliInstalled ? "Command Line Tool Installed" : "Install Command Line Tool") { model.installCLI() }
                    .disabled(model.cliInstalled)
            } label: {
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 7).contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(RoundedRectangle(cornerRadius: 7).fill(model.harness.color.opacity(hovering ? 1 : 0.9)))
        .onHover { hovering = $0 }
        .fixedSize()
        .disabled(model.selectedDirectory == nil)
    }
}

/// What the selected preset is and, for custom presets, how it treats instructions.
struct PresetBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let preset = model.preset
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: preset.isBuiltIn ? "square.stack" : "slider.horizontal.3")
                    .font(.system(size: 11)).foregroundStyle(Theme.preset)
                Text(preset.name).font(.system(size: 12.5, weight: .semibold))
                Text(preset.summary).font(Theme.small).foregroundStyle(Theme.ink2).lineLimit(2)
                Spacer(minLength: 0)
                QuietButton(title: "Show on disk", systemImage: "arrow.uturn.backward") { model.select(preset: Preset.onDisk.id) }
                    .help("Back to what a plain launch loads")
            }
            Text("Preview of a launch with this preset. Running sessions and plain launches still load everything on disk; \"off\" means only this preset skips it.")
                .font(Theme.small).foregroundStyle(Theme.ink3).fixedSize(horizontal: false, vertical: true)
            if preset.isBuiltIn {
                HStack(spacing: 6) {
                    Text("Built-in. Make a copy to switch parts on or off.").font(Theme.small).foregroundStyle(Theme.ink3)
                    Spacer()
                    QuietButton(title: "Make a copy", systemImage: "plus.square.on.square", tint: Theme.preset) { model.namingPreset = .new }
                }
            } else {
                HStack(spacing: 8) {
                    Text("Instructions").font(Theme.small).foregroundStyle(Theme.ink2)
                    Picker("Instructions", selection: Binding(
                        get: { preset.instructionsMode },
                        set: { mode in
                            model.updatePreset { $0.instructionsMode = mode }
                            if mode != .keep, preset.instructions.trimmingCharacters(in: .whitespaces).isEmpty {
                                model.showingInstructionsEditor = true
                            }
                        }
                    )) {
                        Text("As on disk").tag(Preset.InstructionsMode.keep)
                        Text("Add mine").tag(Preset.InstructionsMode.append)
                        Text("Replace global").tag(Preset.InstructionsMode.replace)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    .fixedSize()
                    .tint(Theme.preset)
                    .help("Add: load the preset's instructions too. Replace global: use them instead of \(model.harness == .claude ? "~/.claude/CLAUDE.md" : "~/.codex/AGENTS.md"); project files still load.")
                    if preset.instructionsMode != .keep {
                        QuietButton(title: "Edit…", systemImage: "square.and.pencil") { model.showingInstructionsEditor = true }
                    }
                    Spacer(minLength: 0)
                }
                if model.harness == .claude {
                    Toggle(isOn: Binding(get: { !preset.disableBundledSkills }, set: { on in model.updatePreset { $0.disableBundledSkills = !on } })) {
                        Text("Claude Code's built-in skills").font(Theme.small).foregroundStyle(Theme.ink2)
                    }
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.preset.opacity(0.06))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.hairline).frame(height: 1) }
    }
}

/// Small checkbox at the start of a tree row for switching an item in a custom preset.
struct PresetToggle: View {
    @Environment(AppModel.self) private var model
    var item: ContextItem

    var body: some View {
        let info = model.toggleInfo(item)
        let on = model.isOn(item)
        if info.key != nil {
            Button { model.toggle(item) } label: {
                Image(systemName: on ? "checkmark.square.fill" : "square")
                    .font(.system(size: 12))
                    .foregroundStyle(on ? Theme.preset : Theme.ink3)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(on ? "On in \(model.preset.name). Click to switch off." : (item.presetOff ?? "Off") + " Click to switch on.")
        } else {
            Image(systemName: "minus.square")
                .font(.system(size: 12))
                .foregroundStyle(Theme.hairline)
                .frame(width: 16, height: 16)
                .help(info.reason ?? "")
        }
    }
}

struct InstructionsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var mode: Preset.InstructionsMode = .append

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Instructions for \(model.preset.name)").font(.system(size: 14, weight: .semibold))
                Spacer()
                Menu("Start from") {
                    Button("Autonomous: go as far as possible") { text = PresetExamples.autonomousText }
                    Button("Careful: small steps, tests, review") { text = PresetExamples.carefulText }
                    Divider()
                    Button("My ~/.claude/CLAUDE.md") { text = read(PresetKeys.userInstructionsPath(.claude)) }
                    Button("My ~/.codex/AGENTS.md") { text = read(PresetKeys.userInstructionsPath(.codex)) }
                }
                .fixedSize()
            }
            Picker("Mode", selection: $mode) {
                Text("Add to the files on disk").tag(Preset.InstructionsMode.append)
                Text("Replace the global file").tag(Preset.InstructionsMode.replace)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            Text(mode == .replace
                ? "Used instead of ~/.claude/CLAUDE.md and ~/.codex/AGENTS.md. Project files still load unless you switch them off."
                : "Loaded in addition to every instruction file that is on.")
                .font(Theme.small).foregroundStyle(Theme.ink2)
            TextEditor(text: $text)
                .font(Theme.mono)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.editor))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                .frame(minHeight: 300)
            HStack {
                Text("≈\(Format.tokens(TokenEstimate.tokens(text))) tokens").font(Theme.small).foregroundStyle(Theme.ink3).monospacedDigit()
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    let t = text, m = mode
                    model.updatePreset { $0.instructions = t; $0.instructionsMode = m }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 640, height: 520)
        .onAppear {
            text = model.preset.instructions
            mode = model.preset.instructionsMode == .replace ? .replace : .append
        }
    }

    private func read(_ path: String) -> String {
        (try? String(contentsOf: URL(filePath: path), encoding: .utf8)) ?? ""
    }
}

struct PresetNameSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var naming: PresetNaming
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(naming == .new ? "New preset" : "Rename preset").font(.system(size: 14, weight: .semibold))
            if naming == .new {
                Text("Starts as a copy of \(model.preset.name). Your files on disk are never changed.")
                    .font(Theme.small).foregroundStyle(Theme.ink2)
            }
            TextField("Name", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(naming == .new ? "Create" : "Rename") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    if naming == .new { model.createPreset(named: n) } else { model.renamePreset(to: n) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { name = naming == .new ? "\(model.preset.name) copy" : model.preset.name }
    }
}

/// A transient message at the bottom of the window.
struct NoticeToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let text = model.notice {
            HStack(spacing: 8) {
                Text(text).font(.system(size: 12)).lineLimit(2)
                Button { model.notice = nil } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .bold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.raised).shadow(color: .black.opacity(0.18), radius: 8, y: 2))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
            .padding(14)
            .task(id: text) {
                try? await Task.sleep(for: .seconds(6))
                if model.notice == text { model.notice = nil }
            }
        }
    }
}

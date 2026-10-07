import ContextLensCore
import ServiceManagement
import SwiftUI

@main
struct ContextLensApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Context Lens", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1080, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Inspect Folder…") { model.chooseFolder() }
                    .keyboardShortcut("o")
                Button("Reload") { model.reloadAll() }
                    .keyboardShortcut("r")
                HealthCommand()
                SkillsCommand()
            }
        }

        Window("Agent Health", id: "health") {
            HealthView()
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)

        Window("Skills", id: "skills") {
            SkillsView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1240, height: 820)

        MenuBarExtra {
            MenuBarMenu().environment(model)
        } label: {
            Image(nsImage: MenuBarIcon.image)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The menu bar icon keeps the app useful with no window open.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// The menu bar menu: jump straight to a recent folder's context.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Button("Open Context Lens") { show() }
        Button("Agent Health") {
            openWindow(id: "health")
            NSApp.activate()
        }
        Button("Skills") {
            openWindow(id: "skills")
            NSApp.activate()
        }
        Divider()
        let folders = Array((model.pinnedEntries + model.recentDirectories).prefix(10))
        if folders.isEmpty {
            Text(model.loadingSessions ? "Reading session history…" : "No folders yet")
        } else {
            Section("Recent \(model.harness.displayName) folders") {
                ForEach(folders) { entry in
                    Button(model.duplicateNames.contains(entry.name)
                        ? "\(entry.name) (\(URL(filePath: entry.path).deletingLastPathComponent().lastPathComponent))"
                        : entry.name) {
                        model.select(directory: entry.path)
                        show()
                    }
                }
            }
        }
        Button("Inspect Folder…") {
            show()
            model.chooseFolder()
        }
        Divider()
        Toggle("Open at Login", isOn: Binding(get: { openAtLogin }, set: { on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Context Lens: open at login failed: \(error)")
            }
            openAtLogin = SMAppService.mainApp.status == .enabled
        }))
        Button("Quit Context Lens") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate()
    }
}

/// Window menu command for the Agent Health window (⌘⇧H).
struct HealthCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Agent Health") { openWindow(id: "health") }
            .keyboardShortcut("h", modifiers: [.command, .shift])
    }
}

/// Window menu command for the Skills window (⌘⇧K).
struct SkillsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Skills") { openWindow(id: "skills") }
            .keyboardShortcut("k", modifiers: [.command, .shift])
    }
}

/// A template glyph that echoes the app icon: context bars under a lens.
enum MenuBarIcon {
    static let image: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            for (y, width) in [(3.0, 9.0), (7.0, 6.5), (11.0, 4.5)] {
                NSBezierPath(roundedRect: NSRect(x: 1, y: y, width: width, height: 1.8), xRadius: 0.9, yRadius: 0.9).fill()
            }
            let ring = NSBezierPath(ovalIn: NSRect(x: 7.5, y: 3.5, width: 7.5, height: 7.5))
            ring.lineWidth = 1.7
            ring.stroke()
            let handle = NSBezierPath()
            handle.move(to: NSPoint(x: 13.9, y: 10))
            handle.line(to: NSPoint(x: 16.6, y: 12.8))
            handle.lineWidth = 2
            handle.lineCapStyle = .round
            handle.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

/// Folders on the left; the selected folder's context on the right, as a tree and a reader.
struct ContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                .background(Theme.sidebar)
            VStack(spacing: 0) {
                TopBar()
                Rectangle().fill(Theme.hairline).frame(height: 1)
                HSplitView {
                    ContextTreeView()
                        .frame(minWidth: 320, idealWidth: 400, maxWidth: 560)
                        .background(Theme.window)
                    EditorView()
                        .frame(minWidth: 400, maxWidth: .infinity)
                        .background(Theme.editor)
                }
            }
            .background(Theme.window)
        }
        .ignoresSafeArea()
        .foregroundStyle(Theme.ink)
        .tint(Theme.claude)
        .overlay(alignment: .bottom) { NoticeToast() }
        .sheet(isPresented: Binding(get: { model.showingInstructionsEditor }, set: { model.showingInstructionsEditor = $0 })) {
            InstructionsEditor().environment(model)
        }
        .sheet(item: Binding(get: { model.namingPreset }, set: { model.namingPreset = $0 })) { naming in
            PresetNameSheet(naming: naming).environment(model)
        }
        .onAppear {
            // `-appearance light|dark` forces an appearance, for checking both themes.
            let args = ProcessInfo.processInfo.arguments
            if let i = args.firstIndex(of: "-appearance"), i + 1 < args.count {
                NSApp.appearance = NSAppearance(named: args[i + 1] == "dark" ? .darkAqua : .aqua)
            }
            // `-health` opens the Agent Health window too.
            if args.contains("-health") { openWindow(id: "health") }
            // `-skills` opens the Skills window too.
            if args.contains("-skills") { openWindow(id: "skills") }
        }
    }
}

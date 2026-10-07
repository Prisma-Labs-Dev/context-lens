import ContextLensCore
import Foundation

/// `context-lens mcp list [dir]`, `mcp enable|disable <name> [--scope folder|user] [dir]`,
/// `mcp undo`: switch MCP servers and plugins in the harnesses' own settings.
func runMcp(_ opts: Options) {
    let args = opts.positional
    guard let sub = args.first else { fail("mcp needs list, enable, disable or undo") }
    let engine = McpToggleEngine(measurements: MeasuredContextStore())
    let writer = ConfigWriter()
    func folder(_ i: Int) -> URL {
        URL(filePath: NSString(string: args.count > i ? args[i] : FileManager.default.currentDirectoryPath).expandingTildeInPath).standardizedFileURL
    }
    var harnesses = Harness.allCases
    if let name = opts.flags["harness"] {
        guard let h = Harness(rawValue: name) else { fail("unknown harness \(name)") }
        harnesses = [h]
    }

    switch sub {
    case "list":
        let dir = folder(1)
        emit(harnesses.map { engine.list(folder: dir, harness: $0) })
    case "enable", "disable":
        guard args.count >= 2 else { fail("mcp \(sub) needs a server or plugin name") }
        let name = args[1], dir = folder(2)
        guard let scope = ToggleScope(rawValue: opts.flags["scope"] ?? "folder") else { fail("--scope takes folder or user") }
        guard let toggle = harnesses.lazy.compactMap({ McpToggleEngine.find(name, in: engine.list(folder: dir, harness: $0)) }).first else {
            fail(ConfigEditError.unknown(name).description)
        }
        let dryRun = opts.flags["dry-run"] != nil
        do {
            let plan = try engine.plan(toggle, on: sub == "enable", scope: scope, folder: dir)
            let previews = try writer.preview(plan.edits)
            let applied = dryRun ? nil : try writer.apply(plan.edits, description: plan.description)
            let after = McpToggleEngine.find(toggle.pluginKey ?? toggle.name, in: engine.list(folder: dir, harness: toggle.harness))
            emit(ToggleOut(plan: plan, previews: previews, applied: applied, dryRun: dryRun, state: after?.state))
        } catch {
            fail("\(error)")
        }
    case "undo":
        do {
            guard let undone = try writer.undoLast() else { fail("nothing to undo") }
            emit(undone)
        } catch {
            fail("\(error)")
        }
    default:
        fail("unknown mcp command \(sub)")
    }
}

struct ToggleOut: Encodable {
    struct FileDiff: Encodable { var file: String; var diff: [String] }
    var description: String
    var scope: String
    var dryRun: Bool
    var changed: Bool
    var edits: [String]
    var files: [FileDiff]
    var warnings: [String]
    var backups: [String]
    /// The switch's state after the change.
    var state: String?
    var note: String

    init(plan: TogglePlan, previews: [ConfigWriter.Preview], applied: ConfigWriter.Applied?, dryRun: Bool, state: String?) {
        description = plan.description
        scope = plan.scope.rawValue
        self.dryRun = dryRun
        changed = !previews.isEmpty
        edits = plan.edits.map { "\($0.file): \($0.summary)" }
        files = previews.map { FileDiff(file: $0.file, diff: $0.diff.map(\.unified)) }
        warnings = plan.warnings
        backups = applied?.backups ?? []
        self.state = state
        note = dryRun ? "Nothing written (--dry-run)." : "Running sessions keep their tools until restarted. context-lens mcp undo reverts the last change."
    }
}

import ContextLensCore
import Foundation

/// `context-lens skills [--since 30d|all] [--cwd <dir>]`: which skills sessions used, and which
/// installed skills none did. `--session <transcript or id>`: the skills one session used.
func runSkills(_ opts: Options) {
    if let query = opts.flags["session"] {
        guard let session = SkillUsageScanner().session(query) else { fail("no single session matches \(query)") }
        emit(session)
        return
    }
    let window = opts.flags["since"] ?? "30d"
    var since: Date?
    if window != "all" {
        guard let age = parseAge(window) else { fail("--since takes 24h, 7d, 2w or all") }
        since = Date().addingTimeInterval(-age)
    }
    let folder = opts.flags["cwd"].map { URL(filePath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path }
    emit(SkillUsageScanner().report(since: since, folder: folder))
}

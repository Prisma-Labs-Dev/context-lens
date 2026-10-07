import ContextLensCore
import Foundation

/// `context-lens skills [--since 30d|all] [--cwd <dir>]`: which skills sessions used, and which
/// installed skills none did.
func runSkills(_ opts: Options) {
    let window = opts.flags["since"] ?? "30d"
    var since: Date?
    if window != "all" {
        guard let age = parseAge(window) else { fail("--since takes 24h, 7d, 2w or all") }
        since = Date().addingTimeInterval(-age)
    }
    let folder = opts.flags["cwd"].map { URL(filePath: NSString(string: $0).expandingTildeInPath).standardizedFileURL.path }
    emit(SkillUsageScanner().report(since: since, folder: folder))
}

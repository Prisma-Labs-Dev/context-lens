import Foundation

/// Folders macOS guards with a privacy prompt (TCC). Listing or reading one asks the user for
/// access, one prompt per folder, so walkers never enter them and the app reads session folders
/// inside them only once it has Full Disk Access.
public enum PrivacyGuard {
    /// Home folders a walker stays out of. All of `~/Library`, not only its guarded parts (Mail,
    /// Messages, iCloud Drive, containers): nothing a harness loads lives there.
    static let homeFolders: Set<String> = ["Desktop", "Documents", "Downloads", "Library", "Movies", "Music", "Pictures"]
    /// Parts of `~/Library` a session folder can sit in that need access.
    static let libraryFolders = ["Mobile Documents", "CloudStorage", "Containers", "Group Containers", "Mail", "Messages"]
    /// Photos, Music and TV libraries, wherever they are.
    static let libraryExtensions: Set<String> = ["photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary"]

    /// Whether a walker that reached `dir` should skip it.
    public static func skip(_ dir: URL, home: String) -> Bool {
        if libraryExtensions.contains(dir.pathExtension.lowercased()) { return true }
        return dir.deletingLastPathComponent().path == home && homeFolders.contains(dir.lastPathComponent)
    }

    /// Whether reading in `path` may ask for access: it is in a guarded home folder, in iCloud
    /// Drive or another guarded part of `~/Library`, or on another volume.
    public static func isProtected(_ path: String, home: String) -> Bool {
        if path.hasPrefix("/Volumes/") { return true }
        guard path.hasPrefix(home + "/") else { return false }
        let rest = path.dropFirst(home.count + 1).split(separator: "/").map(String.init)
        guard let top = rest.first else { return false }
        if top == "Library" { return rest.count > 1 && libraryFolders.contains(rest[1]) }
        return homeFolders.contains(top)
    }

    /// Full Disk Access, tested by opening the system TCC database: without access the open
    /// fails quietly, with no prompt.
    public static func hasFullDiskAccess() -> Bool {
        let fd = open("/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno != EPERM && errno != EACCES
    }

    /// Whether to leave `path` alone for now: it needs access the app does not have.
    public static func blocked(_ path: String, home: String) -> Bool {
        isProtected(path, home: home) && !hasFullDiskAccess()
    }

    /// System Settings, Privacy & Security, Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}

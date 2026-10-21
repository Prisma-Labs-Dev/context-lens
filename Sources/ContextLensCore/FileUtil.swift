import Foundation

enum FileUtil {
    static var fm: FileManager { .default }

    static func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }

    /// realpath(3). Foundation's resolvingSymlinksInPath maps /private/tmp to /tmp, but the
    /// harnesses record the real /private path.
    static func realPath(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved))
    }

    static func isDirectory(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue
    }

    static func isFile(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    static func read(_ url: URL) -> String? {
        guard isFile(url) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    static func modified(_ url: URL) -> Date? {
        (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// The path-based call follows a symlinked directory (`~/.claude/skills -> ~/dotfiles/skills`);
    /// the URL-based one fails on it with "Not a directory".
    static func children(_ url: URL) -> [URL] {
        ((try? fm.contentsOfDirectory(atPath: url.path)) ?? [])
            .sorted()
            .map { url.appending(path: $0) }
    }

    /// All markdown files under a directory, recursively, sorted by path.
    static func markdownFiles(under dir: URL) -> [URL] {
        guard isDirectory(dir),
              let e = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        var out: [URL] = []
        for case let url as URL in e where url.pathExtension == "md" && isFile(url) {
            out.append(url)
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `SKILL.md` files under a skills root, up to a few levels deep.
    static func skillFiles(under root: URL, maxDepth: Int = 4) -> [URL] {
        guard isDirectory(root) else { return [] }
        var out: [URL] = []
        func walk(_ dir: URL, _ depth: Int) {
            let skill = dir.appending(path: "SKILL.md")
            if depth > 0, isFile(skill) {
                out.append(skill)
                return
            }
            guard depth < maxDepth else { return }
            for child in children(dir) where isDirectory(child) {
                walk(child, depth + 1)
            }
        }
        walk(root, 0)
        return out
    }

    /// Ancestors from the filesystem root down to `dir`, excluding `/` itself.
    static func ancestorsTopDown(_ dir: URL) -> [URL] {
        var chain: [URL] = []
        var cur = dir
        while cur.path != "/" && !cur.path.isEmpty {
            chain.append(cur)
            cur = cur.deletingLastPathComponent()
        }
        return chain.reversed()
    }

    static func expandTilde(_ path: String, home: URL) -> String {
        if path == "~" { return home.path }
        if path.hasPrefix("~/") { return home.path + String(path.dropFirst(1)) }
        return path
    }

    /// Display a path relative to home with `~`.
    static func abbreviate(_ path: String, home: URL) -> String {
        let h = home.path
        if path == h { return "~" }
        if path.hasPrefix(h + "/") { return "~" + path.dropFirst(h.count) }
        return path
    }
}

/// YAML-ish frontmatter: enough for `name`, `description`, `paths` and boolean flags.
struct Frontmatter {
    var fields: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var body: String

    init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else {
            body = text
            return
        }
        var currentList: String?
        for line in lines[1..<end] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), let key = currentList {
                lists[key, default: []].append(Self.unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if value.isEmpty {
                currentList = key
            } else {
                currentList = nil
                fields[key] = Self.unquote(value)
            }
        }
        body = lines[(end + 1)...].joined(separator: "\n")
    }

    static func unquote(_ s: String) -> String {
        var v = s
        if v.count >= 2, let f = v.first, let l = v.last, f == l, f == "\"" || f == "'" {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }
}

enum Git {
    struct Roots {
        /// The working tree root: the directory holding `.git` (a dir, or a file for worktrees).
        var worktree: URL
        /// The main repository root. Differs from `worktree` for linked worktrees.
        var main: URL
    }

    static func roots(for dir: URL) -> Roots? {
        var cur = dir
        while true {
            let dotGit = cur.appending(path: ".git")
            if FileUtil.isDirectory(dotGit) {
                return Roots(worktree: cur, main: cur)
            }
            if FileUtil.isFile(dotGit), let text = FileUtil.read(dotGit) {
                return Roots(worktree: cur, main: mainRoot(fromGitFile: text, worktree: cur) ?? cur)
            }
            if cur.path == "/" || cur.path.isEmpty { return nil }
            cur = cur.deletingLastPathComponent()
        }
    }

    /// `.git` file content looks like `gitdir: /repo/.git/worktrees/name`.
    static func mainRoot(fromGitFile text: String, worktree: URL) -> URL? {
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) else { return nil }
        var gitdir = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        if !gitdir.hasPrefix("/") { gitdir = worktree.appending(path: gitdir).standardizedFileURL.path }
        guard let range = gitdir.range(of: "/.git/worktrees/") else { return nil }
        return URL(filePath: String(gitdir[..<range.lowerBound]))
    }
}

enum ClaudePaths {
    /// Claude Code names per-project state directories by replacing every non-alphanumeric
    /// character of the path with `-`.
    static func slug(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}

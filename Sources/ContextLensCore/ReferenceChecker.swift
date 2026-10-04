import Foundation

/// Finds absolute and `~/` paths mentioned in instruction text that no longer exist.
/// Stale paths are the cheapest signal that a note has outlived the thing it describes.
public enum ReferenceChecker {
    nonisolated(unsafe) static let pattern = try! NSRegularExpression(
        pattern: #"(?<![\w.:/@-])(~/|/(?:Users|opt|Applications|Library|private|etc|usr|Volumes|tmp)/)(?:Application Support|[A-Za-z0-9._@+\-/])*[A-Za-z0-9_@+\-/]"#
    )

    public static func referencedPaths(in text: String, home: URL) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let ns = text as NSString
        for match in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            // The only space allowed inside a path is "Application Support".
            var raw = ns.substring(with: match.range)
            while let last = raw.last, ".,:;)".contains(last) { raw.removeLast() }
            guard raw.count > 2, !raw.contains("<"), !raw.contains("*") else { continue }
            if seen.insert(raw).inserted { out.append(raw) }
        }
        return out.filter { !isPlaceholder($0, home: home) }
    }

    public static func missingPaths(in text: String, home: URL) -> [String] {
        referencedPaths(in: text, home: home).filter { raw in
            let path = FileUtil.expandTilde(raw, home: home)
            return !FileManager.default.fileExists(atPath: path)
        }
    }

    public static func issues(for text: String, home: URL) -> [Issue] {
        missingPaths(in: text, home: home).map {
            Issue(kind: .missingPath, message: "Mentions \($0), which does not exist")
        }
    }

    /// Paths that are examples or scratch locations rather than references: other users' homes,
    /// placeholders (`YYYY-MM-DD`, `some-service`), prefixes (`WebDriverAgent-`), and temp dirs
    /// that are expected to come and go.
    static func isPlaceholder(_ path: String, home: URL) -> Bool {
        if path.hasPrefix("/Users/"), !path.hasPrefix(home.path + "/"), path != home.path {
            return true
        }
        if let last = path.last, "-_".contains(last) { return true }
        let ephemeral = ["/tmp/", "/private/tmp/", "/private/var/", "/var/folders/"]
        if ephemeral.contains(where: { path.hasPrefix($0) }) { return true }
        let lowered = path.lowercased()
        return ["/path/to", "/example", "/foo", "your-", "xxx", "yyyy", "some-", "<"].contains { lowered.contains($0) }
    }
}

import Foundation
import TOMLKit

public enum ConfigEditError: Error, CustomStringConvertible, Equatable {
    case invalidJSON(String)
    case notAnObject(String)
    case notAnArray(String)
    case tomlTableMissing(server: String, file: String)
    case locked(String)
    case changedWhileWriting(String)
    case notAllowed(String)
    case unknown(String)

    public var description: String {
        switch self {
        case .invalidJSON(let e): "not valid JSON (\(e)); Context Lens edits only files it can parse exactly"
        case .notAnObject(let p): "\(p) is not a JSON object"
        case .notAnArray(let p): "\(p) is not a JSON array"
        case .tomlTableMissing(let s, let f): "\(f) has no [mcp_servers.\(s)] table to edit; set enabled = false there by hand"
        case .locked(let f): "\(f) is locked by another process (\(f).lock); try again in a moment"
        case .changedWhileWriting(let f): "\(f) kept changing while Context Lens tried to write it; nothing was written"
        case .notAllowed(let why): why
        case .unknown(let name): "no MCP server or plugin named \(name) here"
        }
    }
}

/// One change to one key of a config file. Applying an edit returns the edit that undoes it,
/// computed from the file as it was at that moment, so undo works on whatever else changed since.
public enum ConfigEdit: Codable, Hashable, Sendable {
    /// Set a JSON value at a path of object keys; nil removes the key.
    case jsonValue(file: String, path: [String], value: JSONValue?)
    /// Add an element to (or remove every copy of it from) the array at a path. When the parent
    /// object is missing and an element is added, it is created from `parent`.
    case jsonMember(file: String, path: [String], element: JSONValue, present: Bool, parent: JSONValue?)
    /// Set or remove `enabled` in `[mcp_servers.<server>]` of a Codex TOML file, keeping comments.
    case tomlEnabled(file: String, server: String, value: Bool?, createTable: Bool)

    public var file: String {
        switch self {
        case .jsonValue(let f, _, _), .jsonMember(let f, _, _, _, _), .tomlEnabled(let f, _, _, _): f
        }
    }

    /// "enabledPlugins › figma@x = false"
    public var summary: String {
        switch self {
        case .jsonValue(_, let path, let value): path.joined(separator: " › ") + (value.map { " = \($0.compact)" } ?? " removed")
        case .jsonMember(_, let path, let element, let present, _): (present ? "add \(element.compact) to " : "remove \(element.compact) from ") + path.joined(separator: " › ")
        case .tomlEnabled(_, let server, let value, _): "[mcp_servers.\(TOML.key(server))] " + (value.map { "enabled = \($0)" } ?? "enabled removed")
        }
    }

    /// Applies the edit to a file's text (nil: the file doesn't exist). Returns the new text and the
    /// inverse edit, or nil for the inverse when nothing changed.
    func apply(to text: String?) throws -> (text: String, inverse: ConfigEdit?) {
        switch self {
        case .jsonValue(let file, let path, let value):
            var doc = try JSONDocument(text)
            let old = doc.value.value(at: path)
            guard old != value else { return (text ?? doc.text, nil) }
            try doc.value.set(value, at: path)
            return (try doc.verifiedText(), .jsonValue(file: file, path: path, value: old))
        case .jsonMember(let file, let path, let element, let present, let parent):
            var doc = try JSONDocument(text)
            let current = doc.value.value(at: path)
            if current != nil && current?.array == nil { throw ConfigEditError.notAnArray(path.joined(separator: " › ")) }
            var items = current?.array ?? []
            if present {
                guard !items.contains(element) else { return (text ?? doc.text, nil) }
                items.append(element)
                if let parent, doc.value.value(at: Array(path.dropLast())) == nil {
                    try doc.value.set(parent, at: Array(path.dropLast()))
                }
            } else {
                guard items.contains(element) else { return (text ?? doc.text, nil) }
                items.removeAll { $0 == element }
            }
            try doc.value.set(.array(items), at: path)
            return (try doc.verifiedText(), .jsonMember(file: file, path: path, element: element, present: !present, parent: nil))
        case .tomlEnabled(let file, let server, let value, let createTable):
            let (newText, old) = try TOMLEdit.setEnabled(text ?? "", server: server, value: value, createTable: createTable, file: file)
            guard newText != (text ?? "") else { return (newText, nil) }
            return (newText, .tomlEnabled(file: file, server: server, value: old, createTable: false))
        }
    }
}

/// Line-based edits to a Codex `config.toml`, so comments, ordering and formatting stay as the
/// user wrote them. A TOML library would rewrite the whole file.
enum TOMLEdit {
    /// The dotted key of a `[table]` header line, or nil for other lines (and `[[array]]` tables).
    static func header(_ line: String) -> [String]? {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("["), !t.hasPrefix("[[") else { return nil }
        var parts: [String] = [], cur = "", quote: Character?
        var it = t.dropFirst().makeIterator()
        while let c = it.next() {
            if let q = quote {
                if c == q { quote = nil } else if c == "\\" && q == "\"", let n = it.next() { cur.append(n) } else { cur.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == "." {
                parts.append(cur.trimmingCharacters(in: .whitespaces)); cur = ""
            } else if c == "]" {
                parts.append(cur.trimmingCharacters(in: .whitespaces))
                return parts
            } else {
                cur.append(c)
            }
        }
        return nil
    }

    /// The lines that start a table (`[t]`, or `[[t]]` with a nil key). Lines inside multi-line
    /// strings and multi-line arrays can start with "[" too; they are skipped.
    static func tables(_ lines: [String]) -> [(index: Int, key: [String]?)] {
        var out: [(Int, [String]?)] = []
        var multiline: String?, depth = 0
        for (i, line) in lines.enumerated() {
            if multiline == nil && depth == 0 {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("[[") { out.append((i, nil)); continue }
                if t.hasPrefix("["), let key = header(line) { out.append((i, key)); continue }
            }
            scan(Array(line), multiline: &multiline, depth: &depth)
        }
        return out
    }

    /// Follows strings, comments and brackets through one line.
    static func scan(_ c: [Character], multiline: inout String?, depth: inout Int) {
        var i = 0
        func at(_ s: String) -> Bool { i + s.count <= c.count && String(c[i..<i + s.count]) == s }
        while i < c.count {
            if let m = multiline {
                if at(m) { multiline = nil; i += 3 } else { i += (m == "\"\"\"" && c[i] == "\\") ? 2 : 1 }
                continue
            }
            if at("\"\"\"") || at("'''") { multiline = String(c[i..<i + 3]); i += 3; continue }
            switch c[i] {
            case "#": return
            case "\"", "'":
                let q = c[i]
                i += 1
                while i < c.count, c[i] != q { i += (q == "\"" && c[i] == "\\") ? 2 : 1 }
            case "[": depth += 1
            case "]": depth = max(0, depth - 1)
            default: break
            }
            i += 1
        }
    }

    static func setEnabled(_ text: String, server: String, value: Bool?, createTable: Bool, file: String) throws -> (String, Bool?) {
        let result = try edit(text, server: server, value: value, createTable: createTable, file: file)
        try verify(old: text, new: result.0, server: server, value: value, file: file)
        return result
    }

    /// The edit must leave a file TOML can read, with `enabled` as asked and nothing else changed.
    static func verify(old: String, new: String, server: String, value: Bool?, file: String) throws {
        func parse(_ s: String) throws -> TOMLTable {
            do { return try TOMLTable(string: s) } catch { throw ConfigEditError.notAllowed("\(file) is not valid TOML (\(error)); nothing was written") }
        }
        let a = try parse(old), b = try parse(new)
        guard b["mcp_servers"]?.table?[server]?.table?["enabled"]?.bool == value else {
            throw ConfigEditError.notAllowed("could not set enabled for \(server) in \(file) safely; nothing was written")
        }
        func strip(_ t: TOMLTable) -> String {
            if let servers = t["mcp_servers"]?.table, let s = servers[server]?.table {
                s.remove(at: "enabled")
                if s.isEmpty { servers.remove(at: server) }
                if servers.isEmpty { t.remove(at: "mcp_servers") }
            }
            return t.convert()
        }
        guard strip(a) == strip(b) else {
            throw ConfigEditError.notAllowed("editing \(file) would change more than \(server)'s enabled; nothing was written")
        }
    }

    static func edit(_ text: String, server: String, value: Bool?, createTable: Bool, file: String) throws -> (String, Bool?) {
        var lines = text.components(separatedBy: "\n")
        let tables = tables(lines)
        var start: Int?, end = lines.count
        if let n = tables.firstIndex(where: { $0.key == ["mcp_servers", server] }) {
            start = tables[n].index
            if n + 1 < tables.count { end = tables[n + 1].index }
        }
        let enabledPattern = #"^\s*enabled\s*=\s*(true|false)\s*(#.*)?$"#
        guard let start else {
            guard createTable, let value else {
                if value == nil { return (text, nil) }
                throw ConfigEditError.tomlTableMissing(server: server, file: file)
            }
            var out = text
            if !out.isEmpty && !out.hasSuffix("\n") { out += "\n" }
            if !out.isEmpty { out += "\n" }
            out += "[mcp_servers.\(TOML.key(server))]\nenabled = \(value)\n"
            return (out, nil)
        }
        var old: Bool?
        var found: Int?
        for i in (start + 1)..<end where lines[i].range(of: enabledPattern, options: .regularExpression) != nil {
            found = i
            old = lines[i].split(separator: "#", maxSplits: 1).first?.contains("true") == true
            break
        }
        switch (found, value) {
        case (let i?, let v?):
            let lead = lines[i].prefix { $0 == " " || $0 == "\t" }
            let comment = lines[i].range(of: "#").map { "  " + lines[i][$0.lowerBound...] } ?? ""
            lines[i] = "\(lead)enabled = \(v)\(comment)"
        case (let i?, nil):
            lines.remove(at: i)
            // A table left with nothing at all in it was one Context Lens added: remove its
            // header and the blank line before it too. A comment keeps the table.
            if lines[(start + 1)..<(end - 1)].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                lines.removeSubrange(start..<(end - 1))
                if start > 0, lines[start - 1].trimmingCharacters(in: .whitespaces).isEmpty,
                   start >= lines.count || lines[start].trimmingCharacters(in: .whitespaces).isEmpty {
                    lines.remove(at: start - 1)
                }
                var out = lines.joined(separator: "\n")
                if text.hasSuffix("\n"), !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
                return (out, old)
            }
        case (nil, let v?):
            lines.insert("enabled = \(v)", at: start + 1)
        case (nil, nil):
            break
        }
        return (lines.joined(separator: "\n"), old)
    }
}

/// Writes config files the harnesses read, as safely as a second writer can:
/// - takes `<file>.lock`, the lock directory Claude Code's own config writes use;
/// - re-reads under the lock and applies key-level edits to what is there now;
/// - backs up the old file to `~/.context-lens/backups/` before replacing it;
/// - writes a temp file next to the real target (following symlinks) and renames it over, keeping
///   the file's permissions;
/// - records the inverse edits so the last change can be undone.
public struct ConfigWriter: Sendable {
    public let backupRoot: URL
    /// Tries 100 ms apart to take a file's lock.
    var lockAttempts = 50

    public init(backupRoot: URL? = nil) {
        self.backupRoot = backupRoot ?? HarnessEnvironment.userHome.appending(path: ".context-lens/backups")
    }

    public struct Applied: Codable, Sendable {
        public var date: Date
        public var description: String
        /// Edits that undo this change, in the order to apply them.
        public var inverse: [ConfigEdit]
        public var files: [String]
        public var backups: [String]
    }

    /// The result of applying edits to files in memory, for the confirmation's diff.
    public struct Preview: Sendable {
        public var file: String
        public var before: String?
        public var after: String
        public var diff: [DiffLine]
    }

    public func preview(_ edits: [ConfigEdit]) throws -> [Preview] {
        var texts: [String: String?] = [:]
        var order: [String] = []
        for edit in edits {
            if texts[edit.file] == nil { texts[edit.file] = .some(Self.read(edit.file)); order.append(edit.file) }
            texts[edit.file] = .some(try edit.apply(to: texts[edit.file]!).text)
        }
        return order.compactMap { file in
            let before = Self.read(file), after = texts[file]!!
            guard before != after else { return nil }
            return Preview(file: file, before: before, after: after, diff: DiffLine.hunk(before ?? "", after))
        }
    }

    /// Applies edits file by file. Returns nil when nothing changed.
    @discardableResult
    public func apply(_ edits: [ConfigEdit], description: String, recordUndo: Bool = true) throws -> Applied? {
        var inverse: [ConfigEdit] = [], files: [String] = [], backups: [String] = []
        var order: [String] = []
        for e in edits where !order.contains(e.file) { order.append(e.file) }
        func record() -> Applied? {
            guard !files.isEmpty else { return nil }
            let applied = Applied(date: Date(), description: description, inverse: inverse, files: files, backups: backups)
            if recordUndo { saveLast(applied) }
            return applied
        }
        for file in order {
            let fileEdits = edits.filter { $0.file == file }
            do {
                let (inv, backup) = try write(file, fileEdits)
                if !inv.isEmpty {
                    inverse = inv.reversed() + inverse
                    files.append(file)
                    if let backup { backups.append(backup) }
                }
            } catch {
                // Files already written stay undoable.
                _ = record()
                throw error
            }
        }
        return record()
    }

    /// Undoes the last recorded change, and forgets it.
    public func undoLast() throws -> Applied? {
        guard let last = lastChange() else { return nil }
        let result = try apply(last.inverse, description: "Undo: " + last.description, recordUndo: false)
        try? FileManager.default.removeItem(at: lastURL)
        return result
    }

    var lastURL: URL { backupRoot.appending(path: "last-change.json") }

    public func lastChange() -> Applied? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: lastURL)).flatMap { try? d.decode(Applied.self, from: $0) }
    }

    func saveLast(_ a: Applied) {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try? FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)
        try? e.encode(a).write(to: lastURL, options: .atomic)
    }

    static func read(_ path: String) -> String? {
        FileManager.default.fileExists(atPath: path) ? (try? String(contentsOfFile: path, encoding: .utf8)) : nil
    }

    /// The file a path finally names: a symlinked settings file (dotfiles) is edited in place, not
    /// replaced by a plain file.
    static func target(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else {
            // A new file in a symlinked directory still lands in the real directory.
            let dir = (path as NSString).deletingLastPathComponent
            guard let d = realpath(dir, nil) else { return path }
            defer { free(d) }
            return String(cString: d) + "/" + (path as NSString).lastPathComponent
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    func write(_ path: String, _ edits: [ConfigEdit]) throws -> (inverse: [ConfigEdit], backup: String?) {
        let target = Self.target(path)
        let fm = FileManager.default
        try fm.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // Claude Code locks by the path it was given, so the lock goes next to the path, not the target.
        return try withLock(path) {
            for _ in 0..<3 {
                // Stat before reading: a write after the stat changes it, so the check below sees it.
                let stat = Self.stat(target)
                let before = try? Data(contentsOf: URL(filePath: target))
                var text: String?
                if let before {
                    guard let t = String(data: before, encoding: .utf8) else { throw ConfigEditError.notAllowed("\(path) is not UTF-8; nothing was written") }
                    text = t
                }
                var current = text
                var inverse: [ConfigEdit] = []
                for edit in edits {
                    let r = try edit.apply(to: current)
                    current = r.text
                    if let inv = r.inverse { inverse.append(inv) }
                }
                guard let new = current, new != text, !inverse.isEmpty else { return ([], nil) }
                // Someone wrote between our read and now: start again on their version.
                guard Self.stat(target) == stat else { continue }
                let backup = try before.map { try self.backup($0, of: target) }
                try Self.atomicWrite(Data(new.utf8), to: target, mode: stat?.mode)
                return (inverse, backup)
            }
            throw ConfigEditError.changedWhileWriting(path)
        }
    }

    struct Stat: Equatable { var size: Int; var mtime: Date; var mode: Int }

    static func stat(_ path: String) -> Stat? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return Stat(size: (a[.size] as? Int) ?? 0, mtime: (a[.modificationDate] as? Date) ?? .distantPast, mode: (a[.posixPermissions] as? Int) ?? 0o644)
    }

    static func atomicWrite(_ data: Data, to path: String, mode: Int?) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/." + (path as NSString).lastPathComponent + ".context-lens-\(UUID().uuidString.prefix(8)).tmp"
        guard FileManager.default.createFile(atPath: tmp, contents: data, attributes: [.posixPermissions: mode ?? 0o644]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: tmp])
        }
        if let h = FileHandle(forWritingAtPath: tmp) { try? h.synchronize(); try? h.close() }
        guard rename(tmp, path) == 0 else {
            let err = errno
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: err) ?? .EIO)
        }
    }

    func backup(_ data: Data, of path: String) throws -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss.SSS"
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = f.string(from: Date()) + "-" + ClaudePaths.slug(path).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let url = backupRoot.appending(path: name)
        // ~/.claude.json holds credentials-adjacent state: keep backups private.
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        pruneBackups()
        return url.path
    }

    /// Keeps the newest 100 backups.
    func pruneBackups() {
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: backupRoot.path)) ?? [])
            .filter { $0 != "last-change.json" && !$0.hasPrefix(".") }.sorted()
        for old in files.dropLast(100) { try? FileManager.default.removeItem(at: backupRoot.appending(path: old)) }
    }

    /// The `proper-lockfile` convention Claude Code uses for `~/.claude.json`: a directory at
    /// `<file>.lock`, stale after 10 seconds without an update.
    func withLock<T>(_ path: String, _ body: () throws -> T) throws -> T {
        let lock = path + ".lock"
        var acquired = false
        for _ in 0..<lockAttempts {
            if mkdir(lock, 0o755) == 0 { acquired = true; break }
            if let m = Self.stat(lock)?.mtime, Date().timeIntervalSince(m) > 15 {
                rmdir(lock)
                continue
            }
            usleep(100_000)
        }
        guard acquired else { throw ConfigEditError.locked(path) }
        defer { rmdir(lock) }
        return try body()
    }
}

/// A compact diff for the confirmation: the changed lines with a little context. Edits are local,
/// so the common head and tail are trimmed and what is between is shown as removed and added.
public struct DiffLine: Hashable, Sendable {
    public enum Kind: String, Sendable { case same, added, removed, gap }
    public var kind: Kind
    public var text: String

    public static func hunk(_ old: String, _ new: String, context: Int = 2) -> [DiffLine] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.components(separatedBy: "\n")
        var head = 0
        while head < a.count, head < b.count, a[head] == b[head] { head += 1 }
        var tail = 0
        while tail < a.count - head, tail < b.count - head, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        var out: [DiffLine] = []
        let from = max(0, head - context)
        if from > 0 { out.append(DiffLine(kind: .gap, text: "… \(from) lines")) }
        out += a[from..<head].map { DiffLine(kind: .same, text: $0) }
        out += a[head..<(a.count - tail)].map { DiffLine(kind: .removed, text: $0) }
        out += b[head..<(b.count - tail)].map { DiffLine(kind: .added, text: $0) }
        let after = min(tail, context)
        out += a[(a.count - tail)..<(a.count - tail + after)].map { DiffLine(kind: .same, text: $0) }
        if tail > after { out.append(DiffLine(kind: .gap, text: "… \(tail - after) lines")) }
        return out
    }

    /// "  same", "- removed", "+ added"
    public var unified: String {
        switch kind {
        case .same: "  " + text
        case .added: "+ " + text
        case .removed: "- " + text
        case .gap: text
        }
    }
}

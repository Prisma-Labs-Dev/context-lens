import Foundation

/// Lists recorded sessions cheaply: only the head and tail of each transcript are read.
public struct SessionIndex: Sendable {
    public var env: HarnessEnvironment

    public init(env: HarnessEnvironment = .current) {
        self.env = env
    }

    public func all() -> [SessionSummary] {
        (claudeSessions() + codexSessions()).sorted { $0.date > $1.date }
    }

    // MARK: - Claude Code

    public func claudeSessions() -> [SessionSummary] {
        let projects = env.claudeHome.appending(path: "projects")
        var files: [URL] = []
        for dir in FileUtil.children(projects) where FileUtil.isDirectory(dir) {
            files += FileUtil.children(dir).filter { $0.pathExtension == "jsonl" }
        }
        return Self.concurrentMap(files) { claudeSummary($0) }
    }

    /// Transcript reads are I/O bound; spreading them over cores cuts listing time several-fold.
    static func concurrentMap(_ files: [URL], _ transform: (URL) -> SessionSummary?) -> [SessionSummary] {
        let results = UnsafeMutableBufferPointer<SessionSummary?>.allocate(capacity: files.count)
        results.initialize(repeating: nil)
        defer {
            results.deinitialize()
            results.deallocate()
        }
        DispatchQueue.concurrentPerform(iterations: files.count) { i in
            results[i] = transform(files[i])
        }
        return results.compactMap { $0 }
    }

    public func claudeSummary(_ file: URL) -> SessionSummary? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int, size > 0 else { return nil }
        let date = attrs[.modificationDate] as? Date ?? .distantPast
        let head = JSONLines.head(file, bytes: 64 * 1024)
        let tail = size > 64 * 1024 ? JSONLines.tail(file, bytes: 128 * 1024) : head
        guard let cwd = JSONLines.lastString("cwd", in: head) ?? JSONLines.lastString("cwd", in: tail) else { return nil }
        let title = JSONLines.lastString("customTitle", in: tail)
            ?? JSONLines.lastString("aiTitle", in: tail)
            ?? JSONLines.lastString("lastPrompt", in: tail)
            ?? JSONLines.firstUserText(in: head)
            ?? "Untitled"
        let started = JSONLines.firstString("timestamp", in: head).flatMap(Self.parseISO)
        return SessionSummary(
            id: "claude:" + file.deletingPathExtension().lastPathComponent,
            harness: .claude, file: file, title: Self.clean(title), cwd: cwd, date: date, sizeBytes: size, started: started
        )
    }

    // MARK: - Codex

    public func codexSessions() -> [SessionSummary] {
        let names = codexThreadNames()
        var files: [URL] = []
        for root in [env.codexHome.appending(path: "sessions"), env.codexHome.appending(path: "archived_sessions")] {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "jsonl" && url.lastPathComponent.hasPrefix("rollout-") {
                files.append(url)
            }
        }
        return Self.concurrentMap(files) { codexSummary($0, names: names) }
    }

    public func codexSummary(_ file: URL, names: [String: String]) -> SessionSummary? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? Int, size > 0 else { return nil }
        let date = attrs[.modificationDate] as? Date ?? .distantPast
        let stem = file.deletingPathExtension().lastPathComponent
        let id = String(stem.suffix(36))
        let head = JSONLines.head(file, bytes: 16 * 1024)
        guard let cwd = JSONLines.firstString("cwd", in: head) else { return nil }
        var title = names[id]
        if title == nil {
            let more = JSONLines.head(file, bytes: 192 * 1024)
            title = JSONLines.codexFirstUserText(in: more)
        }
        let archived = file.path.contains("/archived_sessions/")
        let started = JSONLines.firstString("timestamp", in: head).flatMap(Self.parseISO)
        return SessionSummary(
            id: "codex:" + id, harness: .codex, file: file,
            title: Self.clean(title ?? "Untitled") + (archived ? " (archived)" : ""),
            cwd: cwd, date: date, sizeBytes: size, started: started
        )
    }

    func codexThreadNames() -> [String: String] {
        guard let text = FileUtil.read(env.codexHome.appending(path: "session_index.jsonl")) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let id = obj["id"] as? String, let name = obj["thread_name"] as? String else { continue }
            out[id] = name
        }
        return out
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func clean(_ title: String) -> String {
        let oneLine = title.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
    }
}

/// Byte-level helpers for large JSONL transcripts.
enum JSONLines {
    static func head(_ url: URL, bytes: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        return (try? h.read(upToCount: bytes)) ?? Data()
    }

    static func tail(_ url: URL, bytes: Int) -> Data {
        guard let h = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: end > UInt64(bytes) ? end - UInt64(bytes) : 0)
        return (try? h.readToEnd()) ?? Data()
    }

    static func decode(_ escaped: Data) -> String {
        if !escaped.contains(0x5C) { return String(decoding: escaped, as: UTF8.self) }
        var data = Data("\"".utf8)
        data.append(escaped)
        data.append(contentsOf: Data("\"".utf8))
        return (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String)
            ?? String(decoding: escaped, as: UTF8.self)
    }

    /// The JSON string value following `"key":"` at `range`, read up to the closing quote.
    static func stringValue(in data: Data, after range: Range<Data.Index>) -> String? {
        var i = range.upperBound
        var escaped = false
        while i < data.endIndex {
            let b = data[i]
            if escaped {
                escaped = false
            } else if b == 0x5C {
                escaped = true
            } else if b == 0x22 {
                return decode(data[range.upperBound..<i])
            }
            i = data.index(after: i)
        }
        return nil
    }

    static func firstString(_ key: String, in data: Data) -> String? {
        guard let r = data.range(of: Data("\"\(key)\":\"".utf8)) else { return nil }
        return stringValue(in: data, after: r)
    }

    static func lastString(_ key: String, in data: Data) -> String? {
        let needle = Data("\"\(key)\":\"".utf8)
        var searchEnd = data.endIndex
        while let r = data.range(of: needle, options: .backwards, in: data.startIndex..<searchEnd) {
            if let v = stringValue(in: data, after: r), !v.isEmpty { return v }
            searchEnd = r.lowerBound
        }
        return nil
    }

    /// First typed prompt in a Claude Code transcript head.
    static func firstUserText(in data: Data) -> String? {
        for line in data.split(separator: 0x0A) where line.range(of: Data("\"type\":\"user\"".utf8)) != nil {
            guard let obj = parse(line), let message = obj["message"] as? [String: Any] else { continue }
            if let s = message["content"] as? String, !s.hasPrefix("<") { return s }
            if let parts = message["content"] as? [[String: Any]],
               let s = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String,
               !s.hasPrefix("<") {
                return s
            }
        }
        return nil
    }

    /// First user message in a Codex rollout head, skipping injected context blocks.
    static func codexFirstUserText(in data: Data) -> String? {
        for line in data.split(separator: 0x0A) where line.range(of: Data("\"role\":\"user\"".utf8)) != nil {
            guard let obj = parse(line), let payload = obj["payload"] as? [String: Any],
                  let content = payload["content"] as? [[String: Any]] else { continue }
            for part in content {
                if let s = part["text"] as? String, !s.hasPrefix("<"), !s.hasPrefix("# AGENTS.md") { return s }
            }
        }
        return nil
    }

    static func parse(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    /// Calls `body` for each line of a file that contains any of `needles`.
    static func forEachLine(in url: URL, containing needles: [String], _ body: ([String: Any]) -> Void) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        let needleData = needles.map { Data($0.utf8) }
        var start = data.startIndex
        while start < data.endIndex, !Task.isCancelled {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            let line = data[start..<end]
            if needleData.contains(where: { line.range(of: $0) != nil }),
               let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                body(obj)
            }
            start = end < data.endIndex ? data.index(after: end) : end
        }
    }
}

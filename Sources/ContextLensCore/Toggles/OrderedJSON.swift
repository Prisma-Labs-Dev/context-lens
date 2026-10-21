import Foundation

/// JSON that keeps what a config file had: key order, duplicate keys, and numbers as written.
/// Context Lens edits files the harnesses own (`~/.claude.json`, settings files), so an edit must
/// change only the keys it means to. Serializing matches `JSON.stringify(value, null, 2)`, which is
/// how Claude Code writes them, so a file it wrote round-trips byte for byte.
public indirect enum JSONValue: Hashable, Sendable {
    public struct Member: Hashable, Sendable {
        public var key: String
        public var value: JSONValue
        public init(_ key: String, _ value: JSONValue) { self.key = key; self.value = value }
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    /// The number's text as written, so `1.0` and `1e3` stay as they were.
    case number(String)
    case bool(Bool)
    case null

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var string: String? { if case .string(let s) = self { s } else { nil } }
    public var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var members: [Member]? { if case .object(let m) = self { m } else { nil } }

    /// The value at a path of object keys.
    public func value(at path: [String]) -> JSONValue? {
        var cur: JSONValue? = self
        for key in path { cur = cur?[key] }
        return cur
    }

    /// Sets (or with nil removes) the value at a path of object keys. Missing objects on the way are
    /// created; an existing key keeps its position. Throws when the path runs through a non-object.
    public mutating func set(_ value: JSONValue?, at path: [String]) throws {
        guard let key = path.first else {
            if let value { self = value }
            return
        }
        guard case .object(var members) = self else { throw ConfigEditError.notAnObject(path.joined(separator: " › ")) }
        let index = members.lastIndex { $0.key == key }
        if path.count == 1 {
            if let value {
                if let index { members[index].value = value } else { members.append(Member(key, value)) }
            } else {
                members.removeAll { $0.key == key }
            }
        } else {
            if index == nil && value == nil { return }
            var child = index.map { members[$0].value } ?? .object([])
            try child.set(value, at: Array(path.dropFirst()))
            if let index { members[index].value = child } else { members.append(Member(key, child)) }
        }
        self = .object(members)
    }

    // MARK: - Parsing

    public static func parse(_ text: String) throws -> JSONValue {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWhitespace()
        let v = try p.value()
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw ConfigEditError.invalidJSON("unexpected text at byte \(p.i)") }
        return v
    }

    struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        func fail(_ what: String) -> ConfigEditError { .invalidJSON("\(what) at byte \(i)") }

        mutating func value() throws -> JSONValue {
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""): return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            default: return .number(try number())
            }
        }

        mutating func literal(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<i + w.count]) == w else { throw fail("expected \(word)") }
            i += w.count
        }

        mutating func object() throws -> JSONValue {
            i += 1
            var members: [Member] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                let key = try string()
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
                i += 1
                skipWhitespace()
                members.append(Member(key, try value()))
                skipWhitespace()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail("expected , or }")
            }
        }

        mutating func array() throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while true {
                skipWhitespace()
                items.append(try value())
                skipWhitespace()
                guard i < bytes.count else { throw fail("unexpected end") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail("expected , or ]")
            }
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count, let v = UInt32(String(decoding: bytes[i..<i + 4], as: UTF8.self), radix: 16) else { throw fail("bad \\u escape") }
            i += 4
            return v
        }

        mutating func string() throws -> String {
            i += 1
            var out = [UInt8]()
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; break }
                if b < 0x20 { throw fail("control character in string") }
                if b != UInt8(ascii: "\\") { out.append(b); i += 1; continue }
                i += 1
                guard i < bytes.count else { throw fail("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        i += 2
                        let low = try hex4()
                        guard (0xDC00..<0xE000).contains(low) else { throw fail("bad surrogate pair") }
                        code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                    }
                    // A lone surrogate has no UTF-8 form; JSON.parse would keep it, Swift cannot.
                    guard let scalar = Unicode.Scalar(code) else { throw fail("lone surrogate") }
                    out += Array(String(Character(scalar)).utf8)
                default: throw fail("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }

        mutating func number() throws -> String {
            let start = i
            while i < bytes.count, "+-0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            guard !text.isEmpty, Double(text) != nil else { throw fail("bad value") }
            return text
        }
    }

    // MARK: - Writing

    /// `indent` is one level: two spaces by default, as Claude Code writes.
    public func serialized(indent: String = "  ") -> String {
        var out = ""
        write(&out, indent: indent, level: 0)
        return out
    }

    /// One line, for the undo record and messages.
    public var compact: String {
        switch self {
        case .object(let m): "{" + m.map { Self.quote($0.key) + ":" + $0.value.compact }.joined(separator: ",") + "}"
        case .array(let a): "[" + a.map(\.compact).joined(separator: ",") + "]"
        case .string(let s): Self.quote(s)
        case .number(let n): n
        case .bool(let b): b ? "true" : "false"
        case .null: "null"
        }
    }

    func write(_ out: inout String, indent: String, level: Int) {
        let pad = String(repeating: indent, count: level + 1)
        let close = String(repeating: indent, count: level)
        switch self {
        case .object(let members):
            guard !members.isEmpty else { out += "{}"; return }
            out += "{\n"
            for (n, m) in members.enumerated() {
                out += pad + Self.quote(m.key) + ": "
                m.value.write(&out, indent: indent, level: level + 1)
                out += n == members.count - 1 ? "\n" : ",\n"
            }
            out += close + "}"
        case .array(let items):
            guard !items.isEmpty else { out += "[]"; return }
            out += "[\n"
            for (n, v) in items.enumerated() {
                out += pad
                v.write(&out, indent: indent, level: level + 1)
                out += n == items.count - 1 ? "\n" : ",\n"
            }
            out += close + "]"
        default:
            out += compact
        }
    }

    /// What `JSON.stringify` escapes: quote, backslash and control characters.
    static func quote(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        self = try JSONValue.parse(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(compact)
    }
}

/// A JSON config file's text with the layout it was written in, so an edit writes it back the
/// same way.
struct JSONDocument {
    var value: JSONValue
    var indent: String
    var trailingNewline: Bool

    init(_ text: String?) throws {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            value = .object([]); indent = "  "; trailingNewline = true
            return
        }
        value = try JSONValue.parse(text)
        guard value.members != nil else { throw ConfigEditError.notAnObject("the file") }
        trailingNewline = text.hasSuffix("\n")
        // The first indented line gives the unit: Claude Code uses two spaces.
        let second = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).dropFirst().first ?? ""
        let lead = second.prefix { $0 == " " || $0 == "\t" }
        indent = lead.isEmpty ? "  " : String(lead)
    }

    var text: String { value.serialized(indent: indent) + (trailingNewline ? "\n" : "") }

    /// The text to write, read back to check it holds exactly the edited value.
    func verifiedText() throws -> String {
        let t = text
        guard (try? JSONValue.parse(t)) == value else { throw ConfigEditError.invalidJSON("Context Lens wrote JSON it can't read back; nothing was written") }
        return t
    }
}

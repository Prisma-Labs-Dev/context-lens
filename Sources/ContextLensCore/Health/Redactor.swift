import Foundation

/// Removes secrets from text before it leaves the Mac. A coarse net by design: it prefers
/// redacting a harmless long hash over letting a token through.
public enum Redactor {
    static let rules: [(NSRegularExpression, String)] = [
        // Private key blocks.
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)"#, "[private key]"),
        // Vendor token shapes.
        (#"\b(sk-ant-[A-Za-z0-9_-]{10,}|sk-(proj-)?[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abposr]-[A-Za-z0-9-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|glpat-[A-Za-z0-9_-]{16,}|sntrys_[A-Za-z0-9_=+/-]{20,}|phc_[A-Za-z0-9]{20,}|lin_api_[A-Za-z0-9]{20,}|whsec_[A-Za-z0-9+/=]{16,}|(sk|rk|pk)_(live|test)_[A-Za-z0-9]{16,})"#, "[secret]"),
        // JWTs.
        (#"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#, "[jwt]"),
        // Authorization headers.
        (#"(?i)\b(bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{16,}"#, "$1 [secret]"),
        // KEY=value, "password": "value", api_key: value.
        (#"(?i)([A-Za-z0-9_]*(api[_-]?key|secret|token|passw(or)?d|pwd|credential|session[_-]?key|auth)[A-Za-z0-9_]*\s*["']?\s*[:=]\s*["']?)[^\s"',;&]{6,}"#, "$1[secret]"),
        // Secrets in URLs: user:pass@host and ?token=...
        (#"(://[^/\s:@]+:)[^@\s/]{3,}@"#, "$1[secret]@"),
        (#"(?i)([?&](key|token|sig|signature|secret|access_token|api_key)=)[^&\s"']{6,}"#, "$1[secret]"),
        // Long random-looking strings: 32+ letters and digits, mixed. Paths, UUIDs and snake_case
        // names have separators, so they survive; vendor tokens with dashes are caught above.
        (#"\b(?=[A-Za-z0-9+]{32,})(?=[A-Za-z0-9+]*[0-9])(?=[A-Za-z0-9+]*[A-Za-z])[A-Za-z0-9+]{32,}={0,2}"#, "[redacted]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    public static func redact(_ text: String) -> String {
        var s = text
        for (re, template) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    /// Redacts and trims to `limit` characters, keeping the head and the tail, where errors sit.
    public static func clip(_ text: String, _ limit: Int) -> String {
        let s = redact(text.count > limit * 3 ? String(text.prefix(limit * 2)) + "\n…\n" + String(text.suffix(limit)) : text)
        guard s.count > limit else { return s }
        let head = limit * 2 / 3
        return String(s.prefix(head)) + " … " + String(s.suffix(limit - head - 3))
    }
}

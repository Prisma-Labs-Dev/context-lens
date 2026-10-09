import CryptoKit
import Foundation

/// Which budget a call drew from. Transcripts do not record auth, so a call's route is the one in
/// effect when it was made, read from time windows in `~/.context-lens/auth-windows.json`
/// (docs/costs.md). Two routes need no window: the desktop app on a claude.ai account (entrypoint
/// `claude-desktop`) and Copilot CLI (the Copilot seat).
public struct CostRoute: Codable, Sendable, Hashable {
    public var id: String
    public var label: String
    /// How to ask the gateway's usage API what this route was billed. Nil: no gateway figure.
    public var auth: RouteAuth?

    public init(id: String, label: String, auth: RouteAuth? = nil) { self.id = id; self.label = label; self.auth = auth }

    public static let claudeAI = CostRoute(id: "claude.ai", label: "claude.ai account")
    public static let copilot = CostRoute(id: "copilot", label: "Copilot seat")
    public static let unknown = CostRoute(id: "unknown", label: "Unknown route")
}

/// Credentials for the usage API. Key values are never stored here: `keyFile` names a file that
/// is read at request time and goes only into the request header.
public struct RouteAuth: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case entra, apiKey }
    public var kind: Kind
    /// Entra: `az account get-access-token --resource <resource> --tenant <tenant>`.
    public var resource: String?
    public var tenant: String?
    /// API key: the header name (such as `api-key`) and the file holding the key.
    public var header: String?
    public var keyFile: String?

    public init(kind: Kind, resource: String? = nil, tenant: String? = nil, header: String? = nil, keyFile: String? = nil) {
        self.kind = kind; self.resource = resource; self.tenant = tenant; self.header = header; self.keyFile = keyFile
    }
}

/// Which Claude Code installs a window covers: the terminal CLI (with its headless runs,
/// background jobs and subagents) or the desktop app.
public enum AuthScope: String, Codable, Sendable, CaseIterable {
    case cli, desktop, all
}

/// From `start` until the next window of the same scope, calls drew from `route`.
public struct AuthWindow: Codable, Sendable, Hashable {
    public var start: Date
    public var scope: AuthScope
    public var route: String
    public var note: String?

    public init(start: Date, scope: AuthScope, route: String, note: String? = nil) {
        self.start = start; self.scope = scope; self.route = route; self.note = note
    }
}

/// `~/.context-lens/auth-windows.json`. Kept outside the repo and meant to be edited by hand:
///
///     {"usageURL": "https://gateway.example/usage/anthropic/",
///      "routes": [{"id": "entra", "label": "Entra ID", "auth": {"kind": "entra", "resource": "api://…", "tenant": "…"}},
///                 {"id": "team", "label": "Team key", "auth": {"kind": "apiKey", "header": "api-key", "keyFile": "~/.keys/team"}}],
///      "windows": [{"start": "2026-09-01T09:00:00+02:00", "scope": "cli", "route": "entra"},
///                  {"start": "2026-10-01T10:20:00+02:00", "scope": "all", "route": "team"}]}
public struct AuthWindows: Codable, Sendable {
    public var usageURL: String?
    public var routes: [CostRoute] = []
    public var windows: [AuthWindow] = []
    /// Why the file could not be read, when it exists but does not parse.
    public var problem: String?

    enum CodingKeys: String, CodingKey { case usageURL, routes, windows }

    public init(usageURL: String? = nil, routes: [CostRoute] = [], windows: [AuthWindow] = []) {
        self.usageURL = usageURL; self.routes = routes; self.windows = windows.sorted { $0.start < $1.start }
    }

    public static func file(env: HarnessEnvironment = .current) -> URL { env.home.appending(path: ".context-lens/auth-windows.json") }

    public static func load(env: HarnessEnvironment = .current) -> AuthWindows {
        let url = file(env: env)
        guard FileManager.default.fileExists(atPath: url.path) else { return AuthWindows() }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do {
            let w = try dec.decode(AuthWindows.self, from: Data(contentsOf: url))
            return AuthWindows(usageURL: w.usageURL, routes: w.routes, windows: w.windows)
        } catch {
            var bad = AuthWindows()
            bad.problem = "~/.context-lens/auth-windows.json was not read: \(Self.describe(error))"
            return bad
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case DecodingError.dataCorrupted(let c), DecodingError.typeMismatch(_, let c), DecodingError.valueNotFound(_, let c):
            return "\(c.debugDescription) at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        case DecodingError.keyNotFound(let k, let c):
            return "missing \(k.stringValue) at \(c.codingPath.map(\.stringValue).joined(separator: "."))"
        default:
            return error.localizedDescription
        }
    }

    public func route(id: String) -> CostRoute {
        routes.first { $0.id == id } ?? [CostRoute.claudeAI, .copilot, .unknown].first { $0.id == id } ?? CostRoute(id: id, label: id)
    }

    /// The route in effect for a call at `time` from a session of `kind`, started through `entrypoint`.
    public func route(at time: Date, kind: CostKind, entrypoint: String?) -> CostRoute {
        if kind == .copilot { return .copilot }
        let scope: AuthScope
        if let e = entrypoint, e.hasPrefix("claude-desktop") || e.hasPrefix("desktop") {
            // The desktop app signed in to claude.ai, not to a gateway.
            if e == "claude-desktop" || e == "desktop" { return .claudeAI }
            scope = .desktop
        } else {
            scope = .cli
        }
        let w = windows.last { $0.start <= time && ($0.scope == scope || $0.scope == .all) }
        return w.map { route(id: $0.route) } ?? .unknown
    }

    /// The route each install is set up for now, read from its settings: Entra when the credential
    /// helper fetches an `az` token, a key route when the configured header's key hashes the same
    /// as the route's key file. Compared only by hash; no key is kept or shown.
    public func configuredNow(env: HarnessEnvironment = .current) -> [AuthScope: String] {
        var out: [AuthScope: String] = [:]
        func match(key: String?, helper: String?) -> String? {
            if let key, !key.isEmpty {
                let digest = Self.hash(key)
                for r in routes where r.auth?.kind == .apiKey {
                    if let k = r.auth?.keyFile, let stored = Self.readKey(k), Self.hash(stored) == digest { return r.id }
                }
                return nil
            }
            // An Entra helper names its resource and tenant; more than one matching route is ambiguous.
            guard let helper, helper.contains("get-access-token") else { return nil }
            let entra = routes.filter { r in
                guard let a = r.auth, a.kind == .entra, let resource = a.resource, let tenant = a.tenant else { return false }
                return helper.contains(resource) && helper.contains(tenant)
            }
            return entra.count == 1 ? entra[0].id : nil
        }
        if let s = Self.json(env.claudeHome.appending(path: "settings.json")) {
            let envs = s["env"] as? [String: Any] ?? [:]
            let headers = (envs["ANTHROPIC_CUSTOM_HEADERS"] as? String ?? "").split(separator: "\n")
            let key = headers.lazy.compactMap { line -> String? in
                let parts = line.split(separator: ":", maxSplits: 1)
                return parts.count == 2 && parts[0].lowercased() == "api-key" ? parts[1].trimmingCharacters(in: .whitespaces) : nil
            }.first
            if let id = match(key: key, helper: s["apiKeyHelper"] as? String) { out[.cli] = id }
        }
        let library = env.home.appending(path: "Library/Application Support/Claude-3p/configLibrary")
        if let meta = Self.json(library.appending(path: "_meta.json")), let applied = meta["appliedId"] as? String,
           let p = Self.json(library.appending(path: "\(applied).json")) {
            let helper = ([p["inferenceCredentialHelper"] as? String ?? ""] + (p["inferenceCredentialHelperArgs"] as? [String] ?? [])).joined(separator: " ")
            let key = (p["inferenceCustomHeaders"] as? [String: Any])?.first { $0.key.lowercased() == "api-key" }?.value as? String
            if let id = match(key: key, helper: helper) { out[.desktop] = id }
        }
        return out
    }

    /// Scopes whose configured route differs from the window in effect now: a switch nobody
    /// recorded yet.
    /// Also reports a file that exists but does not parse.
    public func drift(env: HarnessEnvironment = .current, now: Date = Date()) -> [String] {
        if let problem { return [problem] }
        return configuredNow(env: env).sorted { $0.key.rawValue < $1.key.rawValue }.compactMap { scope, id in
            let current = windows.last { $0.start <= now && ($0.scope == scope || $0.scope == .all) }?.route
            guard current != id else { return nil }
            return "\(scope.rawValue) is set up for \(route(id: id).label), but auth-windows.json has \(current.map { route(id: $0).label } ?? "no window") now"
        }
    }

    static func json(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func readKey(_ path: String) -> String? {
        guard let s = try? String(contentsOfFile: NSString(string: path).expandingTildeInPath, encoding: .utf8) else { return nil }
        let key = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return key.isEmpty ? nil : key
    }

    static func hash(_ s: String) -> String { SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined() }
}

/// What the gateway billed one route this month, from its usage API
/// (`{subscription_id, month, cost_usd, tier, monthly_limit_usd}`), next to the list-price
/// estimate of the calls attributed to the route in the same month.
public struct GatewayUsage: Encodable, Sendable, Hashable, Identifiable {
    public var id: String { route }
    public var route: String
    public var label: String
    public var month: String
    public var subscription: String?
    public var tier: String?
    public var billed: Double?
    public var limit: Double?
    /// List-price estimate of this month's calls on the route.
    public var estimate = 0.0
    public var error: String?

    public var remaining: Double? { billed.flatMap { b in limit.map { max(0, $0 - b) } } }
    /// Gateway price over list price.
    public var ratio: Double? { billed.flatMap { estimate > 0 ? $0 / estimate : nil } }

    enum CodingKeys: String, CodingKey { case route, label, month, subscription, tier, billed, limit, remaining, estimate, ratio, error }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(route, forKey: .route); try c.encode(label, forKey: .label); try c.encode(month, forKey: .month)
        try c.encodeIfPresent(subscription, forKey: .subscription); try c.encodeIfPresent(tier, forKey: .tier)
        try c.encodeIfPresent(billed, forKey: .billed); try c.encodeIfPresent(limit, forKey: .limit)
        try c.encodeIfPresent(remaining, forKey: .remaining); try c.encode(estimate, forKey: .estimate)
        try c.encodeIfPresent(ratio, forKey: .ratio); try c.encodeIfPresent(error, forKey: .error)
    }
}

public enum GatewayClient {
    /// The month the usage API reports, in UTC: `2026-10`.
    public static func month(_ d: Date = Date()) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let c = cal.dateComponents([.year, .month], from: d)
        return String(format: "%04d-%02d", c.year!, c.month!)
    }

    public static func monthStart(_ d: Date = Date()) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal.date(from: cal.dateComponents([.year, .month], from: d))!
    }

    /// Asks the usage API about every route with auth. `estimates` is list price per route ID for
    /// the same month. Read-only: one GET per route.
    public static func fetch(_ auth: AuthWindows, estimates: [String: Double], month: String = month()) -> [GatewayUsage] {
        guard let base = auth.usageURL, var url = URLComponents(string: base) else { return [] }
        url.queryItems = [URLQueryItem(name: "month", value: month)]
        return auth.routes.filter { $0.auth != nil }.map { r in
            var out = GatewayUsage(route: r.id, label: r.label, month: month, estimate: estimates[r.id] ?? 0)
            do {
                let header = try credential(r.auth!)
                var req = URLRequest(url: url.url!, timeoutInterval: 20)
                req.setValue("application/json", forHTTPHeaderField: "accept")
                req.setValue(header.value, forHTTPHeaderField: header.name)
                let (data, status) = try get(req)
                guard status == 200 else { throw GatewayError("HTTP \(status)") }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GatewayError("unexpected response") }
                func num(_ k: String) -> Double? { (obj[k] as? NSNumber)?.doubleValue ?? (obj[k] as? String).flatMap(Double.init) }
                out.subscription = obj["subscription_id"] as? String
                out.tier = obj["tier"] as? String
                out.billed = num("cost_usd")
                out.limit = num("monthly_limit_usd")
            } catch {
                out.error = "\(error)"
            }
            return out
        }
    }

    struct GatewayError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    static func credential(_ a: RouteAuth) throws -> (name: String, value: String) {
        switch a.kind {
        case .apiKey:
            guard let file = a.keyFile, let key = AuthWindows.readKey(file) else { throw GatewayError("no key in keyFile") }
            return (a.header ?? "api-key", key)
        case .entra:
            guard let resource = a.resource, let tenant = a.tenant else { throw GatewayError("entra auth needs resource and tenant") }
            let p = Process()
            p.executableURL = URL(filePath: "/usr/bin/env")
            p.arguments = ["az", "account", "get-access-token", "--resource", resource, "--tenant", tenant, "--query", "accessToken", "-o", "tsv"]
            var e = ProcessInfo.processInfo.environment
            // The app starts without a login shell's PATH.
            e["PATH"] = (e["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin"
            p.environment = e
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard p.terminationStatus == 0, !token.isEmpty else { throw GatewayError("az account get-access-token failed (az login?)") }
            return ("Authorization", "Bearer " + token)
        }
    }

    static func get(_ req: URLRequest) throws -> (Data, Int) {
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: Result<(Data, Int), Error> = .failure(GatewayError("no response"))
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        URLSession(configuration: config).dataTask(with: req) { data, resp, err in
            if let err { result = .failure(err) } else { result = .success((data ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0)) }
            done.signal()
        }.resume()
        done.wait()
        return try result.get()
    }
}

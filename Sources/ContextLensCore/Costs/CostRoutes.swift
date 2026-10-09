import CryptoKit
import Foundation

/// Which budget a call drew from. Transcripts do not record auth, so a call's route is the one in
/// effect when it was made, read from time windows in `~/.context-lens/auth-windows.json`
/// (docs/costs.md). Two routes need no window: the desktop app on a claude.ai account (entrypoint
/// `claude-desktop`) and Copilot CLI (the Copilot seat). A route in the file with their ID
/// (`claude.ai`, `copilot`) relabels them or gives them a billed figure.
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

/// Where a route's billed figure comes from. Key values are never stored here: `keyFile` names a
/// file that is read at request time and goes only into the request header.
public struct RouteAuth: Codable, Sendable, Hashable {
    /// `entra` and `apiKey` ask the usage API; `command` runs a quota tool that prints
    /// `{"sources": [{"id", "account", "period", "metrics": [{"id", "unit", "used", "entitlement"}]}]}`,
    /// cached for five minutes.
    public enum Kind: String, Codable, Sendable { case entra, apiKey, command }
    public var kind: Kind
    /// Entra: `az account get-access-token --resource <resource> --tenant <tenant>`.
    public var resource: String?
    public var tenant: String?
    /// API key: the header name (such as `api-key`) and the file holding the key.
    public var header: String?
    public var keyFile: String?
    /// Command: the program and its arguments, and which source and metric to read. A metric
    /// with unit `count` is AI credits; `currency` is USD.
    public var command: [String]?
    public var source: String?
    public var metric: String?

    public init(kind: Kind, resource: String? = nil, tenant: String? = nil, header: String? = nil, keyFile: String? = nil,
                command: [String]? = nil, source: String? = nil, metric: String? = nil) {
        self.kind = kind; self.resource = resource; self.tenant = tenant; self.header = header; self.keyFile = keyFile
        self.command = command; self.source = source; self.metric = metric
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
        if kind == .copilot { return route(id: CostRoute.copilot.id) }
        let scope: AuthScope
        if let e = entrypoint, e.hasPrefix("claude-desktop") || e.hasPrefix("desktop") {
            // The desktop app signed in to claude.ai, not to a gateway.
            if e == "claude-desktop" || e == "desktop" { return route(id: CostRoute.claudeAI.id) }
            scope = .desktop
        } else {
            scope = .cli
        }
        let w = windows.last { $0.start <= time && ($0.scope == scope || $0.scope == .all) }
        return route(id: w?.route ?? CostRoute.unknown.id)
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

/// What one route was billed this month, from the gateway's usage API
/// (`{subscription_id, month, cost_usd, tier, monthly_limit_usd}`) or a quota command, next to
/// the estimate for the calls attributed to the route in the same month. In USD, or in AI credits
/// when `credits` is set.
public struct GatewayUsage: Encodable, Sendable, Hashable, Identifiable {
    public var id: String { route }
    public var route: String
    public var label: String
    public var month: String
    public var subscription: String?
    public var tier: String?
    public var billed: Double?
    public var limit: Double?
    /// List-price estimate of this month's calls on the route, in the route's unit.
    public var estimate = 0.0
    public var error: String?
    /// Billed, limit and estimate count Copilot AI credits rather than dollars.
    public var credits = false

    public var remaining: Double? { billed.flatMap { b in limit.map { max(0, $0 - b) } } }
    /// Gateway price over list price.
    public var ratio: Double? { billed.flatMap { estimate > 0 ? $0 / estimate : nil } }

    enum CodingKeys: String, CodingKey { case route, label, month, subscription, tier, billed, limit, remaining, estimate, ratio, error, credits }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(route, forKey: .route); try c.encode(label, forKey: .label); try c.encode(month, forKey: .month)
        try c.encodeIfPresent(subscription, forKey: .subscription); try c.encodeIfPresent(tier, forKey: .tier)
        try c.encodeIfPresent(billed, forKey: .billed); try c.encodeIfPresent(limit, forKey: .limit)
        try c.encodeIfPresent(remaining, forKey: .remaining); try c.encode(estimate, forKey: .estimate)
        try c.encodeIfPresent(ratio, forKey: .ratio); try c.encodeIfPresent(error, forKey: .error)
        try c.encode(credits, forKey: .credits)
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

    /// Asks about every route with auth. `estimates` is list price per route ID in USD for the
    /// same month. Read-only: one GET or one cached quota command per route. A route whose
    /// command is not installed is left out.
    public static func fetch(_ auth: AuthWindows, estimates: [String: Double], month: String = month(),
                             cacheFile: URL? = nil) -> [GatewayUsage] {
        auth.routes.compactMap { r -> GatewayUsage? in
            guard let a = r.auth else { return nil }
            var out = GatewayUsage(route: r.id, label: r.label, month: month, estimate: estimates[r.id] ?? 0)
            if a.kind == .command {
                return QuotaCommand.read(a, into: out, cacheFile: cacheFile ?? HarnessEnvironment.current.home.appending(path: ".context-lens/costs/quota-cache.json"))
            }
            do {
                guard let base = auth.usageURL, var url = URLComponents(string: base) else { throw GatewayError("no usageURL") }
                url.queryItems = [URLQueryItem(name: "month", value: month)]
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
        case .command:
            throw GatewayError("a command route has no credential")
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

/// Runs a quota tool that prints JSON and reads one source's metric. The output is
/// cached for five minutes, keyed by the command, so a window refresh does not start it again.
enum QuotaCommand {
    static let ttl: TimeInterval = 300

    struct CacheEntry: Codable {
        var time: Date
        var output: Data
    }

    /// Nil when the tool is not installed: a missing optional source is left out quietly.
    static func read(_ a: RouteAuth, into usage: GatewayUsage, cacheFile: URL, now: Date = Date()) -> GatewayUsage? {
        guard let command = a.command, !command.isEmpty else {
            var out = usage
            out.error = "command route needs a command"
            return out
        }
        var out = usage
        let key = command.joined(separator: " ")
        var cache = (try? JSONDecoder().decode([String: CacheEntry].self, from: Data(contentsOf: cacheFile))) ?? [:]
        let data: Data
        if let hit = cache[key], now.timeIntervalSince(hit.time) < ttl, hit.time <= now {
            data = hit.output
        } else {
            guard let run = run(command) else { return nil }
            guard run.status == 0 else {
                out.error = "\(command[0]) exited with \(run.status)"
                return out
            }
            data = run.output
            cache[key] = CacheEntry(time: now, output: data)
            try? FileManager.default.createDirectory(at: cacheFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(cache).write(to: cacheFile, options: .atomic)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sources = obj["sources"] as? [[String: Any]],
              let source = sources.first(where: { $0["id"] as? String == a.source }) else {
            out.error = "no source \(a.source ?? "?") in the output of \(command[0])"
            return out
        }
        guard source["available"] as? Bool ?? true else {
            out.error = source["unavailableReason"] as? String ?? "source unavailable"
            return out
        }
        let metrics = source["metrics"] as? [[String: Any]] ?? []
        guard let metric = metrics.first(where: { $0["id"] as? String == a.metric }) ?? (a.metric == nil ? metrics.first : nil) else {
            out.error = "no metric \(a.metric ?? "?") in source \(a.source ?? "?")"
            return out
        }
        func num(_ k: String) -> Double? { (metric[k] as? NSNumber)?.doubleValue }
        out.credits = metric["unit"] as? String == "count"
        out.billed = num("used")
        out.limit = metric["unlimited"] as? Bool == true ? nil : num("entitlement")
        out.subscription = source["account"] as? String
        out.tier = source["plan"] as? String
        if let period = source["period"] as? String { out.month = period }
        // The estimate comes in USD; a credit route compares credits.
        if out.credits { out.estimate /= Pricing.copilotCredit }
        return out
    }

    /// Nil when the program is not found.
    static func run(_ command: [String]) -> (status: Int32, output: Data)? {
        let p = Process()
        p.executableURL = URL(filePath: "/usr/bin/env")
        p.arguments = command
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = (e["PATH"].map { $0 + ":" } ?? "") + "/opt/homebrew/bin:/usr/local/bin"
        p.environment = e
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        // env exits 127 when it cannot find the program.
        return p.terminationStatus == 127 ? nil : (p.terminationStatus, data)
    }
}

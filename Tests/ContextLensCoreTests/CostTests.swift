import Foundation
import Testing
@testable import ContextLensCore

@Suite struct PricingTests {
    @Test func matchesClaudeCodesOwnCost() {
        // A cost-state line Claude Code wrote: 2 input, 4 output, 1,764 tokens written, $0.008908.
        let call = CostCall(id: "m", time: Date(), model: "claude-opus-5-5", input: 2, cacheWrite5m: 1764, output: 4)
        #expect(abs(call.cost! - 0.008908) < 1e-9)
    }

    @Test func normalizesModelIDs() {
        #expect(Pricing.normalize("claude-opus-5-5[1m]") == "claude-opus-5-5")
        #expect(Pricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(Pricing.normalize("us.anthropic.claude-sonnet-4-5-20250929-v1:0") == "claude-sonnet-4-5")
        #expect(Pricing.price("claude-opus-5-5")?.cacheRead == 0.20)
        #expect(Pricing.price("claude-opus-5")?.cacheRead == 0.50)
        #expect(Pricing.price("claude-fable-5-1")?.cacheRead == 0.25)
        // A newer version is not priced as the one before it.
        #expect(Pricing.price("claude-opus-5-6") == nil)
        #expect(Pricing.price("gpt-6.1-sol") == nil)
    }

    @Test func fastModeKeepsCacheMultipliers() {
        let p = Pricing.price("claude-opus-5-5", fast: true)!
        #expect(p.input == 8 && p.output == 40)
        #expect(abs(p.cacheRead - 0.40) < 1e-9 && abs(p.cacheWrite5m - 10) < 1e-9)
    }

    @Test func haiku55PricesByPromptLength() {
        #expect(Pricing.price("claude-haiku-5-5", promptTokens: 90_000)?.input == 0.10)
        #expect(Pricing.price("claude-haiku-5-5", promptTokens: 120_000)?.input == 0.50)
    }
}

/// A throwaway home with Claude Code and Copilot CLI transcripts.
struct CostFixture {
    let f: Fixture
    let t0 = Date().addingTimeInterval(-3600)

    init() throws {
        f = try Fixture()
        let project = ".claude/projects/-Users-me-code-app"
        let a = "aaaa1111-0000-0000-0000-000000000000", b = "bbbb2222-0000-0000-0000-000000000000"
        try f.write("\(project)/\(a).jsonl", [
            #"{"type":"custom-title","customTitle":"Lead","sessionId":"\#(a)"}"#,
            assistant(a, "m1", t0, input: 10, w5m: 50_000, read: 0, output: 10, entry: "claude-desktop-3p"),
            assistant(a, "m1", t0, input: 10, w5m: 50_000, read: 0, output: 100, entry: "claude-desktop-3p"),
            assistant(a, "m2", t0 + 60, input: 5, w5m: 1000, read: 50_000, output: 200, entry: "claude-desktop-3p"),
            // Twenty idle minutes: the 5-minute cache is gone and the whole context is written again.
            assistant(a, "m3", t0 + 60 + 1200, input: 5, w5m: 51_300, read: 0, output: 50, entry: "claude-desktop-3p"),
            #"{"type":"cost-state","sessionId":"\#(a)","totalCostUSD":0.58}"#,
        ].joined(separator: "\n"), base: f.home)
        try f.write("\(project)/\(a)/subagents/agent-x.jsonl",
                    assistant(a, "m4", t0 + 100, input: 0, w5m: 10_000, read: 0, output: 100, entry: "claude-desktop-3p", sidechain: true),
                    base: f.home)
        try f.write("\(project)/\(a)/subagents/agent-x.meta.json", #"{"agentType":"Explore","description":"Read the docs"}"#, base: f.home)
        // A background job that copied one call from the session above when it was forked.
        try f.write("\(project)/\(b).jsonl", [
            assistant(a, "m1", t0, input: 10, w5m: 50_000, read: 0, output: 100, entry: "cli"),
            assistant(b, "m5", t0 + 30, input: 1000, w5m: 0, read: 0, output: 1000, entry: "cli", model: "claude-sonnet-5"),
            assistant(b, "m6", t0 + 40, input: 1000, w5m: 0, read: 0, output: 0, entry: "cli", model: "claude-opus-9"),
            // Ten days ago: outside a 7-day window.
            assistant(b, "m7", Date().addingTimeInterval(-10 * 86_400), input: 1_000_000, w5m: 0, read: 0, output: 0, entry: "cli", model: "claude-sonnet-5"),
        ].joined(separator: "\n"), base: f.home)
        try f.write(".claude/jobs/bbbb2222/state.json", "{}", base: f.home)
        try f.write(".copilot/session-state/c1/events.jsonl", [
            #"{"type":"session.start","data":{"selectedModel":"gpt-6.1-sol","context":{"cwd":"/Users/me/code/app"}},"timestamp":"\#(iso(t0))"}"#,
            #"{"type":"user.message","data":{"content":"Review the change"},"timestamp":"\#(iso(t0))"}"#,
            #"{"type":"session.usage_record","data":{"usage":{"model":"gpt-6.1-sol","inputTokens":100,"outputTokens":10,"cacheReadTokens":50,"cacheWriteTokens":5}},"timestamp":"\#(iso(t0))"}"#,
            #"{"type":"session.usage_checkpoint","data":{"totalNanoAiu":2500000000},"timestamp":"\#(iso(t0 + 5))"}"#,
            // Spent the day before: outside a window that starts later.
        ].joined(separator: "\n"), base: f.home)
        try f.write(".copilot/session-state/c0/events.jsonl", [
            #"{"type":"session.usage_checkpoint","data":{"totalNanoAiu":1000000000},"timestamp":"\#(iso(t0 - 86_400))"}"#,
            #"{"type":"session.usage_checkpoint","data":{"totalNanoAiu":1500000000},"timestamp":"\#(iso(t0 + 10))"}"#,
        ].joined(separator: "\n"), base: f.home)
    }

    var scanner: CostScanner { CostScanner(env: f.env, cacheFile: f.root.appending(path: "cache/costs.json")) }

    func assistant(_ session: String, _ id: String, _ t: Date, input: Int, w5m: Int, read: Int, output: Int,
                   entry: String, model: String = "claude-opus-5-5", sidechain: Bool = false) -> String {
        #"{"type":"assistant","sessionId":"\#(session)","isSidechain":\#(sidechain),"entrypoint":"\#(entry)","cwd":"/Users/me/code/app","timestamp":"\#(iso(t))","message":{"id":"\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"cache_creation_input_tokens":\#(w5m),"cache_read_input_tokens":\#(read),"output_tokens":\#(output),"cache_creation":{"ephemeral_5m_input_tokens":\#(w5m),"ephemeral_1h_input_tokens":0}}}}"#
    }

    func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

@Suite struct CostReportTests {
    @Test func readsCallsKindsAndTitles() throws {
        let x = try CostFixture()
        defer { x.f.cleanup() }
        let files = x.scanner.scan()
        let lead = try #require(files.first { $0.kind == .desktop })
        #expect(lead.title == "Lead")
        #expect(lead.calls.map(\.id) == ["m1", "m2", "m3"])
        // The last of a message's lines has the final output count.
        #expect(lead.calls[0].output == 100)
        #expect(lead.reportedCost == 0.58)
        let sub = try #require(files.first { $0.kind == .subagent })
        #expect(sub.session == lead.session && sub.agentType == "Explore")
        #expect(files.first { $0.kind == .background }?.calls.first { $0.id == "m1" }?.copied == true)
        #expect(files.first { $0.session == "copilot:c1" }?.creditSteps.map(\.credits) == [2.5])
        // A second scan reads the cache.
        #expect(x.scanner.scan().count == files.count)
    }

    @Test func buildsGroupsModelsAndDrivers() throws {
        let x = try CostFixture()
        defer { x.f.cleanup() }
        let config = CostConfig(groups: [CostGroupRule(name: "Leads", title: "Lead")])
        let r = CostReportBuilder.build(files: x.scanner.scan(), since: Date().addingTimeInterval(-7 * 86_400), config: config)

        let lead = try #require(r.sessions.first { $0.title == "Lead" })
        #expect(lead.group == "Leads")
        #expect(abs(lead.own.cost - (0.25204 + 0.01902 + 0.25752)) < 1e-9)
        #expect(abs(lead.subagents.cost - 0.052) < 1e-9)
        #expect(lead.coldRestarts == 1)
        #expect(abs(lead.coldExtra - 51_205 * (5 - 0.2) / 1e6) < 1e-9)

        // The copied call counts once, in the session that made it; the old call is outside the window.
        #expect(r.duplicateCalls == 1)
        let job = try #require(r.sessions.first { $0.kind == .background })
        #expect(job.own.calls == 2 && job.own.unpricedCalls == 1)
        #expect(abs(job.own.cost - (1000 * 2.0 + 1000 * 10.0) / 1e6) < 1e-9)

        #expect(Set(r.groups.map(\.name)) == ["Leads", "Subagents", "Background jobs", "Copilot CLI"])
        #expect(r.copilotCredits == 4.0)
        let recent = CostReportBuilder.build(files: x.scanner.scan(), since: x.t0 - 3600, config: config)
        #expect(recent.copilotCredits == 3.0)
        #expect(abs(r.totals.cost - r.groups.reduce(0) { $0 + $1.totals.cost }) < 1e-9)
        #expect(r.models.first?.model == "claude-opus-5-5")

        #expect(r.ttl1h.restartsSaved == 1)
        #expect(abs(r.ttl1h.savedRestarts - 51_205 * (8 - 0.2) / 1e6) < 1e-9)
        #expect(abs(r.ttl1h.extraWrites - 112_300 * 3 / 1e6) < 1e-9)
        #expect(r.hints.contains { $0.id == "cold-restarts" })
        #expect(r.byEntrypoint["claude-desktop-3p"] != nil)
    }

    @Test func reconcilesWithClaudeCodesTotal() throws {
        let x = try CostFixture()
        defer { x.f.cleanup() }
        let rec = CostReconciliation.build(files: x.scanner.scan(), since: nil)
        let row = try #require(rec.rows.first)
        // Own calls plus the subagent's, against the 0.58 Claude Code recorded.
        #expect(abs(row.computed - 0.58058) < 1e-9)
        #expect(abs(row.error) < 0.002)
    }
}

@Suite struct CostRouteTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    var auth: AuthWindows {
        AuthWindows(routes: [CostRoute(id: "a", label: "Route A"), CostRoute(id: "b", label: "Route B")], windows: [
            AuthWindow(start: t0 + 100, scope: .desktop, route: "b"),
            AuthWindow(start: t0, scope: .all, route: "a"),
        ])
    }

    @Test func attributesByTimeAndScope() {
        let w = auth
        #expect(w.route(at: t0 - 1, kind: .terminal, entrypoint: "cli") == .unknown)
        #expect(w.route(at: t0, kind: .terminal, entrypoint: "cli").id == "a")
        #expect(w.route(at: t0 + 99, kind: .desktop, entrypoint: "claude-desktop-3p").id == "a")
        // A window starts at its own time, and only for its scope.
        #expect(w.route(at: t0 + 100, kind: .desktop, entrypoint: "claude-desktop-3p").id == "b")
        #expect(w.route(at: t0 + 100, kind: .headless, entrypoint: "sdk-cli").id == "a")
        // Subagents carry their parent's entrypoint.
        #expect(w.route(at: t0 + 200, kind: .subagent, entrypoint: "claude-desktop-3p").id == "b")
        // The desktop app on claude.ai and Copilot need no window.
        #expect(w.route(at: t0 + 200, kind: .desktop, entrypoint: "claude-desktop") == .claudeAI)
        #expect(w.route(at: t0 + 200, kind: .copilot, entrypoint: nil) == .copilot)
    }

    @Test func loadsWindowsWithOffsets() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".context-lens/auth-windows.json", #"""
        {"usageURL": "https://gateway.example/usage/anthropic/",
         "routes": [{"id": "team", "label": "Team key", "auth": {"kind": "apiKey", "header": "api-key", "keyFile": "~/k"}}],
         "windows": [{"start": "2026-10-01T10:20:00+02:00", "scope": "cli", "route": "team"},
                     {"start": "2026-09-01T00:00:00Z", "scope": "all", "route": "entra"}]}
        """#, base: f.home)
        let w = AuthWindows.load(env: f.env)
        #expect(w.windows.map(\.route) == ["entra", "team"])
        #expect(w.windows[1].start == ISO8601DateFormatter().date(from: "2026-10-01T08:20:00Z"))
        #expect(w.route(id: "team").auth?.keyFile == "~/k")
        // A route ID no route defines still reads.
        #expect(w.route(at: w.windows[0].start, kind: .terminal, entrypoint: "cli").label == "entra")
    }

    @Test func reportsABrokenFile() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write(".context-lens/auth-windows.json", #"{"windows": [{"start": "2026-10-01T10:20:00Z", "scope": "CLI", "route": "a"}]}"#, base: f.home)
        let w = AuthWindows.load(env: f.env)
        #expect(w.windows.isEmpty)
        #expect(w.drift(env: f.env).first?.contains("auth-windows.json was not read") == true)
        // No file is not a problem.
        try FileManager.default.removeItem(at: AuthWindows.file(env: f.env))
        #expect(AuthWindows.load(env: f.env).problem == nil)
    }

    @Test func routesWithOneLabelStaySeparate() {
        var r = CostReport(until: Date())
        r.cells = [CostCell(model: "m", harness: "h", route: "Key", routeID: "a"), CostCell(model: "m", harness: "h", route: "Key", routeID: "b")]
        r.cells[0].credits = 1; r.cells[1].credits = 2
        #expect(r.slices(by: [.route]).map(\.credits) == [2, 1])
        #expect(r.slices(by: [.model]).map(\.credits) == [3])
    }

    @Test func encodesComputedFigures() throws {
        var s = CostSlice(keys: ["Copilot seat"], groupKeys: ["copilot"])
        s.credits = 4
        let g = GatewayUsage(route: "a", label: "A", month: "2026-10", billed: 105, limit: 700, estimate: 100)
        let json = String(decoding: try JSONEncoder().encode(Pair(slice: s, gateway: g)), as: UTF8.self)
        #expect(json.contains(#""usd":0.04"#) && json.contains(#""remaining":595"#) && json.contains(#""ratio":1.05"#))
    }

    struct Pair: Encodable { var slice: CostSlice; var gateway: GatewayUsage }

    @Test func parsesDimensions() {
        #expect(CostDimension.parse("model, harness") == [.model, .harness])
        #expect(CostDimension.parse("route") == [.route])
        #expect(CostDimension.parse("model,team") == nil)
    }

    @Test func slicesByModelHarnessAndRoute() throws {
        let x = try CostFixture()
        defer { x.f.cleanup() }
        let w = AuthWindows(routes: [CostRoute(id: "a", label: "Route A"), CostRoute(id: "b", label: "Route B")], windows: [
            AuthWindow(start: x.t0 - 10, scope: .all, route: "a"),
            AuthWindow(start: x.t0 + 100, scope: .desktop, route: "b"),
        ])
        let r = CostReportBuilder.build(files: x.scanner.scan(), since: Date().addingTimeInterval(-7 * 86_400), auth: w)

        let routes = Dictionary(uniqueKeysWithValues: r.slices(by: [.route]).map { ($0.keys[0], $0) })
        // m1 and m2 before the desktop switch, the job's calls on the CLI; m3 and the subagent after it.
        #expect(abs(routes["Route A"]!.usd - (0.25204 + 0.01902 + 0.012)) < 1e-9)
        #expect(routes["Route A"]!.totals.calls == 4)
        #expect(abs(routes["Route B"]!.usd - (0.25752 + 0.052)) < 1e-9)
        #expect(routes["Copilot seat"]!.credits == 4.0)
        #expect(abs(routes["Copilot seat"]!.usd - 0.04) < 1e-9)
        #expect(abs(r.routeEstimates["a"]! - 0.28306) < 1e-9)

        let pairs = r.slices(by: [.model, .harness])
        #expect(pairs.contains { $0.keys == ["claude-opus-5-5", "Subagents"] && abs($0.usd - 0.052) < 1e-9 })
        #expect(pairs.contains { $0.keys == ["gpt-6.1-sol", "Copilot CLI"] && $0.credits == 2.5 })
        #expect(pairs.contains { $0.keys == ["copilot", "Copilot CLI"] && $0.credits == 1.5 })
        // Every slicing sums to the same total.
        let all = r.totals.cost + r.copilotUSD
        for dims in [[CostDimension.model], [.harness], [.route], [.model, .harness, .route]] {
            #expect(abs(r.slices(by: dims).reduce(0) { $0 + $1.usd } - all) < 1e-9)
        }
    }

    @Test func noWindowsMeansUnknownRoute() throws {
        let x = try CostFixture()
        defer { x.f.cleanup() }
        let r = CostReportBuilder.build(files: x.scanner.scan(), since: nil)
        #expect(Set(r.slices(by: [.route]).map { $0.keys[0] }) == ["Unknown route", "Copilot seat"])
    }

    @Test func readsTheConfiguredRouteByKeyHash() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.write("keys/team", "synthetic-key-1\n", base: f.root)
        try f.write(".claude/settings.json", #"{"apiKeyHelper": "echo dummy", "env": {"ANTHROPIC_CUSTOM_HEADERS": "api-key: synthetic-key-1"}}"#, base: f.home)
        let lib = "Library/Application Support/Claude-3p/configLibrary"
        try f.write("\(lib)/_meta.json", #"{"appliedId": "p1"}"#, base: f.home)
        try f.write("\(lib)/p1.json", #"{"inferenceCredentialHelper": "/usr/local/bin/az", "inferenceCredentialHelperArgs": ["account", "get-access-token", "--resource", "api://x", "--tenant", "t"]}"#, base: f.home)
        let w = AuthWindows(routes: [
            CostRoute(id: "entra", label: "Entra", auth: RouteAuth(kind: .entra, resource: "api://x", tenant: "t")),
            CostRoute(id: "team", label: "Team key", auth: RouteAuth(kind: .apiKey, keyFile: f.root.appending(path: "keys/team").path)),
        ], windows: [AuthWindow(start: .distantPast, scope: .all, route: "entra")])
        #expect(w.configuredNow(env: f.env) == [.cli: "team", .desktop: "entra"])
        #expect(w.drift(env: f.env) == ["cli is set up for Team key, but auth-windows.json has Entra now"])
        // An Entra helper for another tenant is no route of ours.
        var other = w
        other.routes[0].auth?.tenant = "other"
        #expect(other.configuredNow(env: f.env) == [.cli: "team"])
    }

    @Test func gatewayRatio() {
        var g = GatewayUsage(route: "a", label: "A", month: "2026-10", billed: 105, limit: 700, estimate: 100)
        #expect(g.remaining == 595 && abs(g.ratio! - 1.05) < 1e-9)
        g.estimate = 0
        #expect(g.ratio == nil)
        #expect(GatewayClient.fetch(AuthWindows(), estimates: [:]).isEmpty)
    }
}

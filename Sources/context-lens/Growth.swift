import ContextLensCore
import Foundation

/// `context-lens growth <transcript|id> [--all]`: what a Claude Code session's first call
/// measured against what the transcript shows, and how the context grew call by call.
func runGrowth(_ opts: Options) {
    guard let query = opts.positional.first else { fail("growth needs a transcript path or session id") }
    let session: SessionSummary?
    if query.contains("/") {
        session = SessionIndex().claudeSummary(URL(filePath: NSString(string: query).expandingTildeInPath))
    } else {
        let matches = SessionIndex().claudeSessions().filter { $0.id == query || ($0.id.split(separator: ":").last ?? "").hasPrefix(query) }
        guard matches.count <= 1 else { fail("\(matches.count) sessions match \(query)") }
        session = matches.first
    }
    guard let session else { fail("no Claude Code session matches \(query)") }
    guard let growth = ContextGrowthReader().read(session.file) else { fail("the transcript records no API usage") }
    emit(GrowthOut(session, growth: growth, estimated: ClaudeSessionParser().parse(session).startingTokens, all: opts.flags["all"] != nil))
}

struct GrowthOut: Encodable {
    struct Jump: Encodable {
        var call: Int, tokens: Int, delta: Int, cause: String?, causeTokens: Int?
    }

    var session: String, title: String, cwd: String, entrypoint: String?, model: String?
    /// Estimated from the transcript: the context before the first message.
    var estimatedBeforeFirstMessage: Int
    var firstMessage: Int
    /// From the API usage of the first call.
    var measuredFirstCall: Int?
    /// Measured minus what the transcript shows: tool definitions and the harness prompt.
    var notInTranscript: Int?
    var peak: Int, last: Int?, callCount: Int
    var compactions: [ContextGrowth.Compaction]
    var topJumps: [Jump]
    /// Every call, with `--all`.
    var calls: [ContextGrowth.Call]?

    init(_ s: SessionSummary, growth g: ContextGrowth, estimated: Int, all: Bool) {
        session = s.id; title = s.title; cwd = s.cwd; entrypoint = g.entrypoint; model = g.model
        estimatedBeforeFirstMessage = estimated; firstMessage = g.firstMessageTokens
        measuredFirstCall = g.firstCall; notInTranscript = g.hiddenTokens(estimated: estimated)
        peak = g.peak; last = g.last; callCount = g.calls.count; compactions = g.compactions
        topJumps = g.topJumps(10).map { Jump(call: $0.index, tokens: $0.tokens, delta: $0.delta, cause: $0.cause?.label, causeTokens: $0.cause?.tokens) }
        calls = all ? g.calls : nil
    }
}

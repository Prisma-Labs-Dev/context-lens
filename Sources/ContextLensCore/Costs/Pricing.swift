import Foundation

/// USD per million tokens for one model. Cache writes and reads are listed per model rather than
/// derived, because the read multiplier differs (0.1x on most models, 0.05x on Opus 5.5 and
/// Sonnet 5.5, 0.025x on Fable 5.1).
public struct ModelPrice: Codable, Sendable, Hashable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheWrite1h: Double
    public var cacheRead: Double
    public var output: Double
    /// Fast mode input and output; cache multipliers apply on top. Nil where fast mode does not exist.
    public var fastInput: Double?
    public var fastOutput: Double?

    public init(input: Double, cacheWrite5m: Double, cacheWrite1h: Double, cacheRead: Double, output: Double,
                fastInput: Double? = nil, fastOutput: Double? = nil) {
        self.input = input; self.cacheWrite5m = cacheWrite5m; self.cacheWrite1h = cacheWrite1h
        self.cacheRead = cacheRead; self.output = output; self.fastInput = fastInput; self.fastOutput = fastOutput
    }

    /// The same model in fast mode: base input and output replaced, cache multipliers kept.
    var fast: ModelPrice {
        guard let fi = fastInput, let fo = fastOutput else { return self }
        let k = fi / input
        return ModelPrice(input: fi, cacheWrite5m: cacheWrite5m * k, cacheWrite1h: cacheWrite1h * k,
                          cacheRead: cacheRead * k, output: fo)
    }
}

/// Anthropic's list prices: the one table every cost in Context Lens comes from.
///
/// Source: https://platform.claude.com/docs/en/about-claude/pricing ("Model pricing", "Fast mode
/// pricing", "Web search tool"), read 2026-10-09. Claude Code's own `costUSD` in transcripts
/// matches these to the micro-dollar (see docs/costs.md). Gateways and cloud platforms may bill
/// differently: US-only inference is 1.1x, and negotiated discounts are not visible here.
public enum Pricing {
    public static let source = "https://platform.claude.com/docs/en/about-claude/pricing"
    public static let readOn = "2026-10-09"
    /// USD per web search request.
    public static let webSearch = 0.01

    /// Model family prefix to price. The longest matching prefix wins, so `claude-opus-5-5`
    /// is not priced as `claude-opus-5`.
    public static let table: [String: ModelPrice] = [
        "claude-fable-5-1": .init(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "claude-mythos-5-1": .init(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 0.25, output: 50),
        "claude-fable-5": .init(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50),
        "claude-mythos-5": .init(input: 10, cacheWrite5m: 12.5, cacheWrite1h: 20, cacheRead: 1, output: 50),
        "claude-opus-5-5": .init(input: 4, cacheWrite5m: 5, cacheWrite1h: 8, cacheRead: 0.20, output: 20, fastInput: 8, fastOutput: 40),
        "claude-opus-5": .init(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25, fastInput: 10, fastOutput: 50),
        "claude-opus-4-8": .init(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25, fastInput: 10, fastOutput: 50),
        "claude-opus-4-7": .init(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25),
        "claude-opus-4-6": .init(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25),
        "claude-opus-4-5": .init(input: 5, cacheWrite5m: 6.25, cacheWrite1h: 10, cacheRead: 0.50, output: 25),
        "claude-opus-4-1": .init(input: 15, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.50, output: 75),
        "claude-opus-4": .init(input: 15, cacheWrite5m: 18.75, cacheWrite1h: 30, cacheRead: 1.50, output: 75),
        "claude-sonnet-5-5": .init(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.10, output: 10),
        "claude-sonnet-5": .init(input: 2, cacheWrite5m: 2.5, cacheWrite1h: 4, cacheRead: 0.20, output: 10),
        "claude-sonnet-4-6": .init(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30, output: 15),
        "claude-sonnet-4-5": .init(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30, output: 15),
        "claude-sonnet-4": .init(input: 3, cacheWrite5m: 3.75, cacheWrite1h: 6, cacheRead: 0.30, output: 15),
        "claude-haiku-4-5": .init(input: 1, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.10, output: 5),
        "claude-3-5-haiku": .init(input: 0.80, cacheWrite5m: 1, cacheWrite1h: 1.6, cacheRead: 0.08, output: 4),
    ]

    /// Haiku 5.5 is priced by prompt length: over 100,000 prompt tokens (input plus cache reads
    /// and writes) the whole request pays the higher row.
    static let haiku55 = ModelPrice(input: 0.10, cacheWrite5m: 0.125, cacheWrite1h: 0.20, cacheRead: 0.01, output: 0.50)
    static let haiku55Long = ModelPrice(input: 0.50, cacheWrite5m: 0.625, cacheWrite1h: 1, cacheRead: 0.05, output: 2.50)

    /// `claude-opus-5-5[1m]`, `us.anthropic.claude-haiku-4-5-20251001-v1:0` and the like, reduced
    /// to the bare model ID.
    public static func normalize(_ model: String) -> String {
        var m = model.lowercased()
        if let i = m.firstIndex(of: "[") { m = String(m[..<i]) }
        if let r = m.range(of: "claude-") { m = String(m[r.lowerBound...]) }
        if let r = m.range(of: #"-\d{8}.*$"#, options: .regularExpression) { m.removeSubrange(r) }
        if let r = m.range(of: #"(@|-v\d+:).*$"#, options: .regularExpression) { m.removeSubrange(r) }
        return m
    }

    /// The price for a model, or nil when the table does not know it.
    public static func price(_ model: String, promptTokens: Int = 0, fast: Bool = false) -> ModelPrice? {
        let m = normalize(model)
        if m.hasPrefix("claude-haiku-5-5") { return promptTokens > 100_000 ? haiku55Long : haiku55 }
        // A suffix that starts with a digit is a newer version (`claude-opus-5-6`), not a variant.
        let key = table.keys.filter { m == $0 || (m.hasPrefix($0 + "-") && !(m.dropFirst($0.count + 1).first?.isNumber ?? true)) }
            .max { $0.count < $1.count }
        guard let key, let p = table[key] else { return nil }
        return fast ? p.fast : p
    }
}

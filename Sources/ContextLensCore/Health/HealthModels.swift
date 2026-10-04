import Foundation

/// One moment of possible friction in a session, found by code. Jev decides later whether it
/// was friction and what kind. Every text field is redacted before it is stored.
public struct HealthEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        /// A tool call that returned an error or a non-zero exit.
        case toolError = "tool_error"
        /// A message the user typed after the session started.
        case userMessage = "user_message"
        /// The user stopped a turn.
        case interrupt
        /// The model API failed (overload, timeout, refusal).
        case apiError = "api_error"
        /// The agent asked the user a question through the question tool.
        case question
    }

    public var id: String
    public var session: String
    public var harness: String
    public var kind: Kind
    public var time: Date?
    /// The tool name (`Bash`, `exec`, `mcp__…`).
    public var tool: String?
    /// What to blame by name: the tool, or for shell calls the program run (`Bash: gh`).
    public var source: String
    public var input: String?
    public var text: String
    /// For user messages: the end of the agent's last message before it.
    public var context: String?
    /// How many times this exact call had already failed earlier in the session.
    public var repeats: Int = 0
    /// Skills invoked earlier in the session.
    public var skills: [String] = []
}

public struct HealthSession: Codable, Sendable {
    public var id: String
    public var harness: String
    public var file: String
    public var cwd: String
    public var title: String?
    /// Opens the session: a Claude desktop link, or a Codex thread link.
    public var link: String?
    public var subagent: Bool
    public var model: String?
    public var started: Date?
    public var ended: Date?
    public var activeSeconds: Double = 0
    public var toolCalls = 0
    public var toolErrors = 0
    public var userMessages = 0
    public var interrupts = 0
    public var apiErrors = 0
    public var questions = 0
    public var inputTokens = 0
    public var outputTokens = 0
    public var cacheReadTokens = 0
    public var cacheWriteTokens = 0
    /// Instruction files the harness loaded (CLAUDE.md, AGENTS.md, rules, memory).
    public var ruleFiles: [String] = []
    public var skills: [String] = []
}

public struct HealthExtract: Codable, Sendable {
    public var since: Date
    public var sessions: [HealthSession]
    public var events: [HealthEvent]
    public var files: Int
    public var bytes: Int
    public var seconds: Double
}

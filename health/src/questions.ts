// Every Jev question and threshold for agent health lives here, so a reviewer reads one file.
// Change a question, bump VERSION (it keys the answer cache), then run `pnpm eval`.

export const VERSION = "2026-10-04.3";
export const MODEL = "jev-1.13.0";

/** Why a tool call failed. State: { tool, command, error, failed_before }. */
export const TOOL_ERROR = {
  question:
    "Why did this tool call fail? `tool` is the tool the coding agent called, `command` what it ran, `error` what came back.",
  labels: {
    guard: {
      what: "A rule built into the agent harness, or a hook, refused the call before it ran and said what to do instead",
      examples: [
        "This session is isolated in the worktree ... Refusing to run it",
        "PreToolUse hook error",
        "Blocked: sleep 30 followed by ...",
        "File has been modified since read. Read it again before writing",
        "File has not been read yet. Read it first",
        "take a screenshot before using coordinate",
        "Write is disabled for this session",
      ],
    },
    permission: {
      what: "A person or a permission check said no: the user rejected the call, an auto-mode classifier or safety check denied it, the sandbox or the operating system did not permit it",
      examples: [
        "Permission for this action was denied",
        "The user doesn't want to proceed with this tool use",
        "operation not permitted",
        "Rejected by sandbox",
      ],
    },
    auth: {
      what: "A login, credential, API key or token was missing, expired or rejected",
      examples: ["401 Unauthorized", "not logged in", "invalid API key", "gh auth login"],
    },
    misuse: {
      what: "The agent's own mistake, visible in `error`: wrong path, file that does not exist, bad arguments, a tool that does not exist, a bug in a script it just wrote, shell syntax error, unmatched glob",
      examples: [
        "(eval):1: ===== not found (zsh reads `echo =====` as a command, even after normal output)",
        "zsh: no matches found: src/*.swift",
        "sed: 1: invalid command code",
        "Unknown option: --output",
      ],
      not_for:
        "Output that looks normal with only a non-zero exit code; failures of the project's code under test; searches that found nothing",
    },
    environment: {
      what: "Something outside the agent was broken or unavailable: a missing program, device not connected, server or service down, network error, timeout, rate limit",
    },
    work: {
      what: "Normal work, not friction: the project's own build, test, lint or type check failed; a search found nothing; a diff or check reported differences; or `error` shows ordinary output (file contents, matches, a diff) with only a non-zero exit code, because the last command in a chain such as grep, rg, ls or diff found nothing",
    },
  },
  minP: 0.6,
};

/** How much a failure cost. Same state as TOOL_ERROR. */
export const COST = {
  question: "How much did this failure slow the coding agent down?",
  levels: [
    "Nothing: an expected result the agent wanted to see",
    "A little: one wasted call, easy to fix",
    "A lot: needs a workaround or several tries",
    "Blocked: the agent cannot continue without a person",
  ] as [string, string, string, string],
};

/** What a person's message does. State: { agent_said, user_message }. */
export const USER_MESSAGE = {
  question:
    "What is the person doing in `user_message`, their reply to a coding agent whose last words were `agent_said`?",
  labels: {
    correction: {
      what: "Says the agent did something wrong or must change or undo it, or pushes back on its work: doubts a result, says it is not enough, or tells it to try harder",
      examples: [
        "no, that's wrong",
        "not what I asked",
        "why did you delete that",
        "stop, revert it",
        "this number seems questionable?",
        "this is not enough",
        "try harder, don't give up",
      ],
    },
    repeat: {
      what: "Asks again for something asked before, or says the agent skipped or forgot an instruction",
      examples: ["I already told you to ...", "you still haven't ...", "again: ..."],
    },
    frustration: {
      what: "Complains about speed, quality, verbosity or the agent asking too much, without a specific correction",
    },
    answer: {
      what: "Answers the agent's question, picks an option or approves a proposal",
    },
    request: {
      what: "A new request, a follow-up, more detail or context, a test prompt, or a status question, with no complaint",
    },
  },
  minP: 0.6,
};

/** Labels that count as friction. */
export const FRICTION = new Set([
  "guard",
  "permission",
  "auth",
  "misuse",
  "environment",
  "correction",
  "repeat",
  "frustration",
]);

/** Fixed costs for user friction (on the COST scale, 1 to 4). */
export const USER_COST: Record<string, number> = {
  correction: 2,
  repeat: 3,
  frustration: 3,
  answer: 1,
  request: 1,
};

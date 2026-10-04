// One Jev request per event: the label and, for tool errors, the cost share the state.
import { createHash } from "node:crypto";
import { classifyPlan, readScore, score, type Jev, type Plan } from "@prisma-labs/jev";
import {
  COST,
  FRICTION,
  MODEL,
  TOOL_ERROR,
  USER_COST,
  USER_MESSAGE,
  VERSION,
} from "./questions.ts";

/** An event from `context-lens health` (events.jsonl). Only the fields the classifier reads. */
export interface HealthEvent {
  id: string;
  kind: "tool_error" | "user_message" | "interrupt" | "api_error" | "question";
  tool?: string;
  input?: string;
  text: string;
  context?: string;
  repeats: number;
}

export interface Label {
  id: string;
  label: string;
  p: number;
  /** 1 (no cost) to 4 (blocks the task). */
  severity: number;
  friction: boolean;
  escalate: boolean;
  /** For escalated events: a ready-made prompt for a stronger model. */
  prompt?: string;
}

const ANSI = new RegExp(`${String.fromCharCode(27)}\\[[0-9;]*m`, "g");

/** What Jev sees. Only the fields a question needs, clipped; the extractor already redacted them. */
export function stateFor(e: HealthEvent): Record<string, string | number> | null {
  if (e.kind === "tool_error") {
    return {
      tool: e.tool ?? "tool",
      command: (e.input ?? "").slice(0, 300),
      error: e.text.replace(ANSI, "").slice(0, 700),
      failed_before: e.repeats,
    };
  }
  if (e.kind === "user_message") {
    return { agent_said: (e.context ?? "").slice(-400), user_message: e.text.slice(0, 600) };
  }
  return null;
}

export function cacheKey(state: object): string {
  return createHash("sha256")
    .update(`${MODEL}|${VERSION}|${JSON.stringify(state)}`)
    .digest("hex")
    .slice(0, 32);
}

const cost: Plan<number> = {
  questions: { cost: score(COST.question, COST.levels) },
  // The API's expected level runs 0..n-1; the report uses 1..4.
  read: (a) => readScore(a, "cost").score + 1,
};

/**
 * A non-zero exit whose output reads as normal: no error words at the start or the end, where a
 * failing command writes. Usually the last command in a chain (grep, rg, ls, diff) found nothing.
 * Nothing in the text says what failed, so Jev guesses; code calls it work instead.
 */
export function quietExit(e: HealthEvent): boolean {
  if (e.kind !== "tool_error" || !/^Exit code \d+\n/.test(e.text) || KILLED.test(e.text))
    return false;
  return !ERROR_WORDS.test(e.text.slice(0, 240)) && !ERROR_WORDS.test(e.text.slice(-240));
}
const ERROR_WORDS =
  /error|fail|not found|no such|denied|invalid|cannot|can't|unable|fatal|traceback|exception|refus|timed? ?out|unknown|usage:|not permitted|missing|abort|panic|killed|no matches/i;
const KILLED = /^Exit code (124|130|137|143)\n/;

export async function labelEvent(jev: Jev, e: HealthEvent): Promise<Omit<Label, "id"> | null> {
  const state = stateFor(e);
  if (!state) return null;
  if (quietExit(e)) return { label: "work", p: 1, severity: 1, friction: false, escalate: false };
  if (e.kind === "tool_error") {
    const { results } = await jev.run(state, {
      kind: classifyPlan({ state, ...TOOL_ERROR }),
      cost,
    });
    const { kind } = results;
    return {
      label: kind.label,
      p: round(kind.p),
      severity: kind.label === "work" ? 1 : round(results.cost),
      friction: FRICTION.has(kind.label),
      escalate: kind.status === "escalate",
      ...(kind.escalation ? { prompt: kind.escalation.prompt } : {}),
    };
  }
  const { results } = await jev.run(state, { kind: classifyPlan({ state, ...USER_MESSAGE }) });
  const { kind } = results;
  return {
    label: kind.label,
    p: round(kind.p),
    severity: USER_COST[kind.label] ?? 1,
    friction: FRICTION.has(kind.label),
    escalate: kind.status === "escalate",
    ...(kind.escalation ? { prompt: kind.escalation.prompt } : {}),
  };
}

const round = (n: number) => Math.round(n * 100) / 100;

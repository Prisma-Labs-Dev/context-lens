// Labels health events with Jev. Called by `context-lens health`; runs alone too:
//   node src/classify.ts <events.jsonl> <labels.jsonl> [cache.jsonl]
// Identical events (the same guard message on the same command) cost one call, and answers are
// cached by (model, question version, state), so a re-run only pays for new events.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createJev } from "@prisma-labs/jev";
import { cacheKey, labelEvent, stateFor, type HealthEvent, type Label } from "./label.ts";
import { MODEL } from "./questions.ts";

const [eventsPath, labelsPath, cachePath] = process.argv.slice(2);
if (!eventsPath || !labelsPath)
  throw new Error("usage: classify.ts <events.jsonl> <labels.jsonl> [cache.jsonl]");

const events = readJsonl<HealthEvent>(eventsPath);
const cache = new Map<string, Omit<Label, "id">>();
if (cachePath && existsSync(cachePath)) {
  for (const row of readJsonl<{ key: string } & Omit<Label, "id">>(cachePath)) {
    const { key, ...answer } = row;
    cache.set(key, answer);
  }
}

// Unique states not yet answered.
const todo = new Map<string, HealthEvent>();
for (const e of events) {
  const state = stateFor(e);
  if (!state) continue;
  const key = cacheKey(state);
  if (!cache.has(key) && !todo.has(key)) todo.set(key, e);
}

const started = Date.now();
// jev-1.13 allows 80 requests/s per account; stay under it with room for other jobs.
const jev = createJev({ model: MODEL, concurrency: 48, requestsPerMinute: 3600 });
let failed = 0;
const results = await jev.map([...todo.entries()], async ([key, e]) => {
  const answer = await labelEvent(jev, e);
  if (answer) {
    cache.set(key, answer);
    if (cachePath) appendFileSync(cachePath, `${JSON.stringify({ key, ...answer })}\n`);
  }
  return answer;
});
failed = results.filter((r) => !r.ok).length;

const labels: Label[] = [];
for (const e of events) {
  const state = stateFor(e);
  const answer = state ? cache.get(cacheKey(state)) : undefined;
  if (answer) labels.push({ id: e.id, ...answer });
}
writeFileSync(labelsPath, labels.map((l) => JSON.stringify(l)).join("\n") + "\n");

const t = jev.totals();
console.error(
  `context-lens health: labeled ${labels.length} events (${todo.size} unique new, ${events.length - labels.length} not sent), ` +
    `${t.calls} Jev calls, $${t.usd.toFixed(4)}, p50 ${t.p50Ms} ms, ${((Date.now() - started) / 1000).toFixed(1)} s` +
    (failed ? `, ${failed} failed` : "") +
    `, ${labels.filter((l) => l.escalate).length} escalated`,
);

function readJsonl<T>(path: string): T[] {
  return readFileSync(path, "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l) as T);
}

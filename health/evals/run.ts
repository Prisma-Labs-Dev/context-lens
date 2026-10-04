// Live eval: label every hand-labeled case, print accuracy (overall, on confident answers, per
// label), the escalation rate, latency and cost, and fail below the bar. Usage: pnpm eval
//
// Cases are synthetic: each one copies the shape of a real event (the harness's guard and
// permission wording, zsh and tool errors, CI and test-runner output, user corrections and
// requests), with invented paths, projects, commands and messages. The labels and per-label
// counts match the hand-labeled real sets they replaced, which scored the same on the holdout.
// - cases.jsonl: the tuning set. Question wording in src/questions.ts was adjusted against it.
// - holdout.jsonl: never tuned against. Its score is the honest one.
// When you change a question, add synthetic versions of the misses to cases.jsonl, and refresh
// holdout.jsonl with new cases rather than tuning against it. Never commit real transcript text.
import { readFileSync } from "node:fs";
import { createJev } from "@prisma-labs/jev";
import { labelEvent, type HealthEvent } from "../src/label.ts";
import { FRICTION, MODEL } from "../src/questions.ts";

const BAR = 0.8;
type Case = Omit<HealthEvent, "id"> & { want: string };

const jev = createJev({ model: MODEL, concurrency: 16 });
let failed = false;
for (const set of ["cases", "holdout"]) {
  const cases = readFileSync(new URL(`${set}.jsonl`, import.meta.url), "utf8")
    .split("\n")
    .filter((l) => l.trim())
    .map((l) => JSON.parse(l) as Case);
  const got = await Promise.all(cases.map((c, i) => labelEvent(jev, { ...c, id: String(i) })));

  let right = 0;
  let sure = 0;
  let sureRight = 0;
  let frictionRight = 0;
  const perLabel = new Map<string, { n: number; right: number }>();
  console.log(`\n${set}.jsonl`);
  got.forEach((g, i) => {
    const c = cases[i]!;
    const ok = g?.label === c.want;
    if (g && g.friction === FRICTION.has(c.want)) frictionRight++;
    const row = perLabel.get(c.want) ?? { n: 0, right: 0 };
    row.n++;
    perLabel.set(c.want, row);
    if (ok) {
      right++;
      row.right++;
    }
    if (g && !g.escalate) {
      sure++;
      if (ok) sureRight++;
    }
    if (!ok) {
      const what = c.kind === "tool_error" ? `${c.tool}: ${c.text}` : c.text;
      console.log(
        `  miss: want ${c.want}, got ${g?.label} (p ${g?.p}${g?.escalate ? ", escalated" : ""}) ${JSON.stringify(what.slice(0, 100))}`,
      );
    }
  });
  const pct = (a: number, b: number) => `${b ? Math.round((a / b) * 100) : 0}%`;
  console.log(
    `  accuracy ${pct(right, cases.length)} (${right}/${cases.length}, bar ${BAR * 100}%), ` +
      `on confident answers ${pct(sureRight, sure)} (${sureRight}/${sure}), escalated ${pct(cases.length - sure, cases.length)}, ` +
      `friction or not ${pct(frictionRight, cases.length)}`,
  );
  console.log(
    "  " +
      [...perLabel.entries()]
        .sort((a, b) => b[1].n - a[1].n)
        .map(([l, r]) => `${l} ${r.right}/${r.n}`)
        .join(", "),
  );
  if (right / cases.length < BAR) failed = true;
}
const t = jev.totals();
console.log(
  `\n${t.calls} calls, $${t.usd.toFixed(5)}, p50 ${t.p50Ms} ms, p90 ${t.p90Ms} ms, model ${MODEL}`,
);
if (failed) process.exit(1);

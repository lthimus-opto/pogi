/**
 * Debug Agent — SDK Entry Point
 *
 * Single autonomous (or interactive) invocation for infra debugging:
 * CloudWatch logs/metrics and live DB introspection (connections, locks,
 * query stats, replica lag, capacity headroom) against the same Aurora
 * cluster data-agent reads from. Read-only against everything it touches
 * — this agent diagnoses, it never mutates infra or application state.
 *
 * Usage: npx tsx run.ts <env-file> [question]
 * Example: npx tsx run.ts .env.atlas.prod "why did connections spike at 14:00 UTC?"
 * Example (no question): npx tsx run.ts .env.atlas.prod
 *   -> runs a general capacity/health sweep per run_prompt.md's default task list
 *
 * Built directly on the SDK (see shared/lib/sdk-bootstrap.ts) for the same
 * reasons as data-agent/run.ts: structured event subscriptions, explicit
 * tool/extension control, independent session per run.
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { bootstrapAgentSession, subscribeConsoleLogging } from "../../shared/lib/sdk-bootstrap.ts";

// ── Args ──
const envFile = process.argv[2];
const rawQuestion = process.argv[3];
const question = rawQuestion?.trim() ? rawQuestion.trim() : "general capacity/health sweep — no specific question given";
const runId = randomUUID();

if (!envFile) {
  console.error("Usage: npx tsx run.ts <env-file> [question]");
  console.error('Example: npx tsx run.ts .env.atlas.prod "why did connections spike at 14:00 UTC?"');
  process.exit(1);
}

const cwd = path.resolve(import.meta.dirname);

// ── Build prompt from template ──
const template = readFileSync(path.join(cwd, "run_prompt.md"), "utf-8");
const prompt = template.replaceAll("{{ENV_FILE}}", envFile).replaceAll("{{QUESTION}}", question);

// ── Resource loader + session: discovers .pi/skills, .pi/extensions, .pi/AGENTS.md ──
const { loader, session } = await bootstrapAgentSession({ cwd, tools: ["read", "bash"] });

// ── Subscribe to events ──
const runStart = Date.now();
const runLog = subscribeConsoleLogging(session, runStart);

// ── Run ──
console.error(`\n=== Debug Agent ===`);
console.error(`Env: ${envFile}`);
console.error(`Question: ${question}`);
console.error(`Run id: ${runId}`);
console.error(`Skills: ${loader.getSkills().skills.map((s) => s.name).join(", ")}`);
console.error(`================================\n`);

let runStatus: "success" | "failed" = "success";

try {
  await session.prompt(prompt);
  const elapsed = ((Date.now() - runStart) / 1000).toFixed(0);
  console.error(`\n\n=== Run complete (${elapsed}s, ${runLog.toolCallCount} tool calls) ===`);
} catch (err) {
  runStatus = "failed";
  console.error("\n=== Run failed ===");
  console.error(err);
} finally {
  session.dispose();
}

if (runStatus === "failed") {
  process.exit(1);
}

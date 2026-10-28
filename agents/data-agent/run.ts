/**
 * Data Agent — SDK Entry Point
 *
 * Single autonomous invocation: given one source, runs TASK_SPEC.md's
 * Tasks 1-5 end to end and writes gate_verdict rows to MotherDuck
 * (output.gate_verdict) -- not a local file. No chat, no human steering.
 *
 * Usage: npx tsx run.ts <source> <env-file> [scope]
 * Example: npx tsx run.ts security_master .env.security_master.prod
 * Example with scope: npx tsx run.ts security_master .env.security_master.prod "last 50 managers created, org_id=xxx"
 *
 * IMPORTANT -- invoke this as ONE SINGLE LINE. A backslash line-continuation
 * before a quoted scope argument is fragile across shells/copy-paste (a
 * confirmed real run lost its scope arg this way: the quoted scope string
 * was executed as a SEPARATE shell command after the fact, printing
 * "zsh: command not found: last 5 managers created, org_id=..." at the very
 * end, while the run itself silently fell back to the full-source default
 * and printed an empty "Scope: " line with no warning). If the command
 * must be split for readability, use a shell variable instead:
 *   SCOPE="last 50 managers created, org_id=xxx"
 *   npx tsx run.ts security_master .env.security_master.prod "$SCOPE"
 *
 * The single entry point for a run -- not one of several equivalent
 * options. Built on the SDK directly (not the `pi` CLI) so it has:
 * - Structured event subscriptions (for logging, monitoring, future Loop A)
 * - Explicit tool/extension control
 * - Session management (in-memory for now — each run is independent)
 */

import { readFileSync } from "node:fs";
import path from "node:path";
import { randomUUID } from "node:crypto";
import { execFileSync } from "node:child_process";
import { bootstrapAgentSession, subscribeConsoleLogging } from "../../shared/lib/sdk-bootstrap.ts";

// ── Args ──
const source = process.argv[2];
const envFile = process.argv[3];
const rawScope = process.argv[4];
const scope = rawScope?.trim() ? rawScope.trim() : "the entire source — no scope restriction";

// run type / trigger: env vars, not positional args -- keeps the existing
// <source> <env-file> [scope] positional shape backward-compatible (a free-text
// scope string shouldn't have to share argv slots with these). Defaults match
// today's only behavior (a full run, invoked by hand).
const mode = (process.env.MODE?.trim().toLowerCase() || "inception");
if (mode !== "inception" && mode !== "incremental") {
  console.error(`Invalid MODE "${mode}" -- must be "inception" or "incremental". See TASK_SPEC.md's "Mode" section.`);
  process.exit(1);
}
const triggeredBy = process.env.TRIGGERED_BY?.trim() || "cli";
const runId = randomUUID();

if (!source || !envFile) {
  console.error("Usage: npx tsx run.ts <source> <env-file> [scope]");
  console.error("Example: npx tsx run.ts security_master .env.security_master.prod");
  console.error(
    'Example with scope: npx tsx run.ts security_master .env.security_master.prod "last 50 managers created, org_id=xxx"',
  );
  process.exit(1);
}

// Loud, unmissable warning when a run is about to hit the ENTIRE source --
// this is almost always unintentional (a dropped/mangled scope arg, see the
// confirmed incident above), and a full-source run can take 15+ minutes and
// write thousands of rows before anyone notices the mistake. Printed before
// anything else runs, not buried in the trailing summary.
if (!rawScope?.trim()) {
  console.error(
    "\n!!! WARNING: no scope argument received (or it was empty) -- this run will process the ENTIRE source. !!!",
  );
  console.error(
    "If you meant to scope this run, re-check your invocation -- a quoted scope string after a line-continuing",
  );
  console.error(
    "backslash is a confirmed way to silently lose this argument. Re-run as one line or via a shell variable.\n",
  );
}

const cwd = path.resolve(import.meta.dirname);

// ── Build prompt from template ──
const template = readFileSync(path.join(cwd, "run_prompt.md"), "utf-8");
const prompt = template
  .replaceAll("{{SOURCE}}", source)
  .replaceAll("{{ENV_FILE}}", envFile)
  .replaceAll("{{MODE}}", mode)
  .replaceAll("{{SCOPE}}", scope);

// ── Resource loader + session: discovers .pi/skills, .pi/extensions, .pi/AGENTS.md ──
const { loader, session } = await bootstrapAgentSession({ cwd, tools: ["read", "bash"] });

// ── Subscribe to events ──
const runStart = Date.now();
const runLog = subscribeConsoleLogging(session, runStart);

// ── Run ──
console.error(`\n=== Data Agent: ${source} ===`);
console.error(`Env: ${envFile}`);
console.error(`Mode: ${mode} (triggered by: ${triggeredBy}, run_id: ${runId})`);
console.error(`Scope: ${scope}`);
console.error(`Output: MotherDuck data_agent_local, table output.gate_verdict`);
console.error(`Skills: ${loader.getSkills().skills.map((s) => s.name).join(", ")}`);
console.error(`================================\n`);

// meta.agent_run: one row per invocation, written once at the end (not an
// insert-then-update pattern -- run.ts already knows the full outcome by the
// time this runs, since it's a single synchronous process blocking on
// session.prompt(); see knowledge/tooling_process.md's "Run tracking" section).
function writeAgentRunRow(args: {
  status: "success" | "failed";
  startedAt: Date;
  completedAt: Date;
  errorMessage: string | null;
}): void {
  try {
    const envContents = readFileSync(path.join(cwd, ".env"), "utf-8");
    const motherduckToken = envContents
      .split("\n")
      .find((line) => line.startsWith("MOTHERDUCK_TOKEN="))
      ?.split("=")
      .slice(1)
      .join("=")
      .trim();
    if (!motherduckToken) {
      console.error("[meta.agent_run] MOTHERDUCK_TOKEN not found in .env -- skipping run-tracking write (non-fatal).");
      return;
    }
    const esc = (s: string) => s.replace(/'/g, "''");
    const startedAtIso = args.startedAt.toISOString();
    const completedAtIso = args.completedAt.toISOString();
    const duckdbEnv = { ...process.env, MOTHERDUCK_TOKEN: motherduckToken };

    // Check existence first, separately -- never create a stub table here.
    // A premature `CREATE TABLE IF NOT EXISTS output.gate_verdict (...)` with
    // the wrong (incomplete) column set would permanently block the agent's
    // own, correct `CREATE TABLE IF NOT EXISTS` from ever taking effect later
    // (IF NOT EXISTS is a no-op once ANY table with that name exists). If
    // these tables don't exist yet, the counts are just NULL -- that's an
    // honest "nothing written yet," not an error.
    const existsCheck = execFileSync(
      "duckdb",
      [
        "md:data_agent_local",
        "-csv",
        "-c",
        "SELECT table_schema || '.' || table_name FROM information_schema.tables WHERE table_schema = 'output' AND table_name IN ('gate_verdict', 'gate_relationship');",
      ],
      { env: duckdbEnv },
    ).toString();
    const gateVerdictExists = existsCheck.includes("output.gate_verdict");
    const gateRelationshipExists = existsCheck.includes("output.gate_relationship");

    const gateVerdictCount = gateVerdictExists
      ? `(SELECT count(*) FROM output.gate_verdict WHERE input_source_name = '${esc(source)}' AND recorded_at >= TIMESTAMP '${startedAtIso}')`
      : "NULL";
    const gateRelationshipCount = gateRelationshipExists
      ? `(SELECT count(*) FROM output.gate_relationship WHERE input_source_name = '${esc(source)}' AND recorded_at >= TIMESTAMP '${startedAtIso}')`
      : "NULL";

    const sql = `
CREATE SCHEMA IF NOT EXISTS meta;
CREATE TABLE IF NOT EXISTS meta.agent_run (
    run_id VARCHAR, source VARCHAR, env_file VARCHAR, scope VARCHAR,
    mode VARCHAR, triggered_by VARCHAR, status VARCHAR,
    started_at TIMESTAMP, completed_at TIMESTAMP, error VARCHAR,
    gate_verdict_rows_written INTEGER, gate_relationship_rows_written INTEGER
);
INSERT INTO meta.agent_run
SELECT
    '${esc(runId)}', '${esc(source)}', '${esc(envFile)}', '${esc(scope)}',
    '${esc(mode)}', '${esc(triggeredBy)}', '${esc(args.status)}',
    TIMESTAMP '${startedAtIso}', TIMESTAMP '${completedAtIso}',
    ${args.errorMessage ? `'${esc(args.errorMessage)}'` : "NULL"},
    ${gateVerdictCount},
    ${gateRelationshipCount};
`;
    execFileSync("duckdb", ["md:data_agent_local", "-c", sql], {
      env: duckdbEnv,
      stdio: "inherit",
    });
  } catch (err) {
    console.error("[meta.agent_run] Failed to write run-tracking row (non-fatal):", err);
  }
}

const startedAt = new Date();
let runStatus: "success" | "failed" = "success";
let runError: string | null = null;

try {
  await session.prompt(prompt);

  const elapsed = ((Date.now() - runStart) / 1000).toFixed(0);
  console.error(`\n\n=== Run complete (${elapsed}s, ${runLog.toolCallCount} tool calls) ===`);
  console.error(`Check: MotherDuck data_agent_local, table output.gate_verdict (filter latest + this source)`);
  console.error(`SQL:   .scratch/${source}_pipeline.sql`);
} catch (err) {
  runStatus = "failed";
  runError = err instanceof Error ? err.message : String(err);
  console.error("\n=== Run failed ===");
  console.error(err);
} finally {
  writeAgentRunRow({ status: runStatus, startedAt, completedAt: new Date(), errorMessage: runError });
  session.dispose();
}

if (runStatus === "failed") {
  process.exit(1);
}

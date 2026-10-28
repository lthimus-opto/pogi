/**
 * Debug Agent Safety Extension
 *
 * Enforces the read-only boundary defined in AGENTS.md:
 * - The Aurora cluster is read-only — no mutating psql statements.
 * - CloudWatch/AWS calls are read-only — no `aws` subcommands that create,
 *   modify, or delete anything (alarms, log groups, dashboards, etc).
 * - Headless/autonomous runs (no human present, ctx.hasUI === false) may
 *   only write to .scratch/. Interactive sessions with a human present may
 *   update skills/docs/code elsewhere — that's the collaborative editing loop.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const AWS_MUTATION_VERBS =
  /\b(create|put|update|delete|modify|remove|set|disable|enable|tag|untag|start-instance|stop-instance|reboot|restart|terminate|attach|detach)[-_a-z]*\b/i;

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName === "bash") {
      const cmd = (event.input?.command ?? "") as string;

      // Block any mutation against Postgres via psql
      if (/psql/i.test(cmd) && /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE)\b/i.test(cmd)) {
        return {
          block: true,
          reason: "The Aurora cluster is read-only. This command contains a mutation keyword.",
        };
      }

      // Block mutating aws CLI subcommands (anything beyond get/describe/list/query/search)
      if (/\baws\s+(cloudwatch|logs|rds|ec2)\b/i.test(cmd) && AWS_MUTATION_VERBS.test(cmd)) {
        return {
          block: true,
          reason:
            "This agent is read-only against AWS — only get/describe/list/query-style aws CLI " +
            "subcommands are allowed. Blocked a command that looks mutating: " + cmd,
        };
      }

      // Block rm -rf or other destructive filesystem ops outside .scratch
      if (/\brm\s+(-[rRf]+\s+)?/.test(cmd) && !/\.scratch/.test(cmd)) {
        return {
          block: true,
          reason: "Destructive filesystem operations are only allowed inside .scratch/.",
        };
      }
    }

    // ── Guard: write/edit outside .scratch/ — only in headless agent mode ──
    if ((event.toolName === "write" || event.toolName === "edit") && !ctx.hasUI) {
      const filePath = (event.input?.path ?? "") as string;
      if (!filePath.includes(".scratch")) {
        return {
          block: true,
          reason:
            "Headless agent runs may only write to ./.scratch/. " +
            "Attempted to " + event.toolName + ": " + filePath + ". " +
            "Changes to skills/docs/code require an interactive session with a human present.",
        };
      }
    }

    return undefined;
  });

  pi.on("agent_start", async () => {
    console.error("[debug-agent] Run started — read-only boundary enforced");
  });

  pi.on("agent_end", async () => {
    console.error("[debug-agent] Run ended");
  });
}

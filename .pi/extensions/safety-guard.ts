/**
 * Data Agent Safety Extension
 *
 * Enforces the storage boundary defined in README.md and AGENTS.md:
 * - Source databases (Postgres/Aurora) are read-only
 * - Headless/autonomous agent runs (no human present, ctx.hasUI === false)
 *   may only write to .scratch/. Interactive sessions with a human present
 *   (tui, or rpc with the extension UI sub-protocol) may update skills,
 *   docs, and code elsewhere — that's the collaborative editing loop.
 * - No Python when DuckDB SQL can do the job (warning, not block)
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event, ctx) => {
    // ── Guard: bash commands ──
    if (event.toolName === "bash") {
      const cmd = (event.input?.command ?? "") as string;

      // Block any mutation against Postgres via psql
      if (/psql/i.test(cmd) && /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE)\b/i.test(cmd)) {
        return {
          block: true,
          reason:
            "Source databases are read-only. This command contains a mutation keyword. " +
            "All writes must go to DuckDB in .scratch/ only.",
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
    //
    // ctx.hasUI is true whenever a human is actually present to review
    // changes (interactive TUI, or an RPC/IDE client with the extension UI
    // sub-protocol). It is false in "print"/"json" mode, which is how
    // unattended, autonomous agent runs (e.g. the pipeline loop) are
    // launched with nobody watching.
    //
    // So: while collaborating with a human (hasUI), skills/docs/code outside
    // .scratch/ may be updated — that's exactly this kind of session. Once
    // running headless, the agent is confined to .scratch/ so it can't
    // silently rewrite its own knowledge base or code mid-run.
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

  // ── Lifecycle logging ──
  pi.on("agent_start", async () => {
    console.error("[data-agent] Run started — storage boundary enforced");
  });

  pi.on("agent_end", async () => {
    console.error("[data-agent] Run ended");
  });
}

/**
 * Atlas Migration Agent Safety Extension
 *
 * Enforces the storage boundary defined in .pi/AGENTS.md:
 * - atlas_prod (the reader-role connection) is read-only, full stop.
 * - The only Postgres this agent/its migrations may ever write to is the
 *   local Docker Compose instance inside atlas-service.
 * - Executing a migration against real prod is explicitly out of scope —
 *   this agent stops at producing + locally verifying it.
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const PROD_HOST_MARKERS = [".rds.amazonaws.com", "atlas_prod", "atlas-prod"];
const MUTATION_KEYWORDS = /\b(INSERT|UPDATE|DELETE|DROP|ALTER|TRUNCATE|CREATE|GRANT|REVOKE)\b/i;

export default function (pi: ExtensionAPI) {
  pi.on("tool_call", async (event) => {
    if (event.toolName === "bash") {
      const cmd = (event.input?.command ?? "") as string;

      // Block any mutating statement that also references the prod host/db,
      // regardless of tool (psql, pg_dump piped into psql, etc).
      const looksLikeProd = PROD_HOST_MARKERS.some((m) => cmd.includes(m));
      if (looksLikeProd && MUTATION_KEYWORDS.test(cmd)) {
        return {
          block: true,
          reason:
            "atlas_prod is read-only, full stop. This command references the prod " +
            "host/db and contains a mutation keyword. Writes only ever go to the " +
            "local atlas-service Docker Postgres.",
        };
      }

      // pg_dump against prod is fine (read-only by construction via the reader
      // role) — only flag pg_restore/psql -c targeting the prod host directly.
      if (/\bpg_restore\b/.test(cmd) && looksLikeProd) {
        return {
          block: true,
          reason: "pg_restore must never target the prod host — restore only into the local DB.",
        };
      }
    }

    return undefined;
  });

  pi.on("agent_start", async () => {
    console.error("[atlas-migration-agent] Run started — prod read-only boundary enforced");
  });

  pi.on("agent_end", async () => {
    console.error("[atlas-migration-agent] Run ended");
  });
}

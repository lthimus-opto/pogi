# Debug Agent

Diagnoses infra/data issues by cross-referencing CloudWatch (logs,
metrics, alarms) with live DB state on the shared Aurora cluster
(connections, locks, query stats, replica lag, capacity headroom).
Read-only against everything it touches — it reports root causes with
evidence, it never mutates infra or data. See `project/vision.md` for the
full context and `.pi/AGENTS.md` for the standing rules every invocation
follows.

## Layout

- `.pi/AGENTS.md` — standing rules (tool order, read-only boundary, skills).
- `.pi/skills/` — `cloudwatch-queries`, `db-capacity`, `incident-playbooks`.
- `knowledge/` — `cloudwatch_dashboards.md` (log group/metric inventory),
  `capacity_baselines.md` (known-good ranges), `failure_modes.md`
  (catalogued incidents — grows from real investigations only).
- `queries/` — reusable read-only SQL (`pg_stat_activity`, `pg_stat_statements`,
  replica lag, table bloat, connection counts).
- `run.ts` / `run_prompt.md` — SDK entry point for a single invocation.
- `connect.sh` — symlink to `../../shared/connect.sh` (same Aurora
  cluster, same IAM-auth-token pattern `data-agent` uses).

## Usage

```bash
# from repo root
npm run debug-agent -- .env.atlas.prod "why did connections spike at 14:00 UTC?"

# or directly
cd agents/debug-agent
npx tsx run.ts .env.atlas.prod "why did connections spike at 14:00 UTC?"

# general health sweep, no specific question
npx tsx run.ts .env.atlas.prod
```

## Status

Skeleton — skills/knowledge are stubs (marked `TODO`) until CloudWatch
access (profile/region/log groups) is confirmed and the first few real
investigations fill in `knowledge/capacity_baselines.md` and
`knowledge/failure_modes.md` with real numbers/incidents.

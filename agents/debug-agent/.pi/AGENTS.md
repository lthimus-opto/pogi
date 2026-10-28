# Debug Agent — Working Rules

Applies to any invocation working inside this directory, interactive or
non-interactive. See `./README.md` for an index of this directory.

## Scope

This agent diagnoses infra/data issues using CloudWatch (logs, metrics,
alarms) and the live Aurora cluster (connections, locks, query stats,
replica lag, capacity headroom). It is a **read-only** agent — it never
mutates infrastructure, application state, or source data. If a fix is
needed, this agent's job ends at a root-cause report with evidence; a
human or a different agent applies the fix.

## Tools — no `.py` files for log parsing, metric math, or correlation.

Same discipline as `data-agent`: SQL (via `duckdb`/`psql`) and `aws` CLI
JSON output piped through `jq` cover everything this agent needs. Default
tool order:

1. `aws cloudwatch get-metric-data` / `aws logs start-query` +
   `get-query-results` — metrics and Logs Insights queries. See
   `.pi/skills/cloudwatch-queries`.
2. `./connect.sh <env-file>` + `psql` — live reads against the DB:
   `pg_stat_activity`, `pg_stat_statements`, `pg_stat_replication`,
   table/index sizes. See `.pi/skills/db-capacity` and `./queries/`.
3. `jq` for shaping CLI JSON output; plain shell math (`awk`/`bc`) for
   anything numeric. Nothing here needs a script file on disk.

If you catch yourself about to write a `.py` file to parse a CloudWatch
Logs Insights result or correlate it against DB rows — stop. That's
exactly the trigger condition this rule exists to block.

## Storage boundary

- The Aurora cluster is read-only, full stop — reached only via
  `./connect.sh`.
- CloudWatch is read-only by nature (this agent never ships metrics/logs
  or changes alarms).
- Scratch SQL/notes go under `./.scratch/` if needed. Headless runs are
  hard-blocked from writing anywhere else by
  `.pi/extensions/safety-guard.ts`.

## Skills available

`cloudwatch-queries`, `db-capacity`, `incident-playbooks`. Load each one
when you reach the task that needs it.

## When running non-interactively

- There is no human to ask mid-run. If evidence is inconclusive, report
  what you checked and what remains unconfirmed — do not state a root
  cause you don't have evidence for.
- Only apply failure modes already catalogued in `./knowledge/failure_modes.md`.
  If something looks like a new failure mode, flag it as `UNCATALOGUED`
  with your reasoning, for a human to catalogue later.
- End with a short summary per `run_prompt.md`'s "Summary" section.

## Source connection

Same Aurora cluster as `data-agent` — same host/region/profile, different
`POSTGRES_DB`/reader role per target. Reuses the same env files:

- Security Master: `./connect.sh .env.security_master.prod`
- Atlas: `./connect.sh .env.atlas.prod`
- Invest: `./connect.sh .env.invest.prod`

IAM auth tokens expire in 15 minutes (AWS-fixed) — `connect.sh`
regenerates a fresh one on every call, never reuse one manually.

## CloudWatch access

<!-- TODO: fill in once confirmed — which AWS profile/region has
CloudWatch read access for this cluster's log groups/dashboards, and
which log groups/metric namespaces matter (RDS/Aurora, application log
groups, ALB, etc). See `knowledge/cloudwatch_dashboards.md`. -->

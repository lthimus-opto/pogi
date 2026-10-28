---
name: tooling-pipeline
description: >
  The standard pipeline: extract from source DB, load raw into MotherDuck,
  build Atlas SDK payloads directly in SQL, write gate verdicts to
  MotherDuck. No CSV intermediary, no local DuckDB files, no `.py` scripts
  for extraction, scoring, or payload-building.
---

# Tooling Pipeline

The living process doc is at `./knowledge/tooling_process.md` — that is the knowledge base,
where the pipeline patterns get tested against real data and refined by a human
across sessions. Read it completely before writing any data-processing logic.
This skill only explains the philosophy and how the agent should follow it.

**Standing rule, see `.pi/AGENTS.md`: no `.py` files for extraction, scoring,
or payload-building in this pipeline.** Bash + `duckdb` CLI only. This was
violated repeatedly across real sessions before being made explicit — see
`knowledge/tooling_process.md`'s "Confirmed incident" entries for what it cost each time.

## The philosophy: three stages, no intermediary files, no script files

### Stage 1 — Extract directly into MotherDuck (no CSV)

**Two run types, same pipeline: inception (full extract) vs. incremental
(delta extract).** See `knowledge/tooling_process.md`'s "Modes"
section for the full mechanics (watermark derived live from the local
raw table, `ANTI JOIN`-based replace-by-id merge, new-insert vs.
updated-existing classification). Everything below in this skill
describes an inception-style full extract -- an incremental run only
changes *what's pulled from Postgres and how it's merged into the raw
table*; mapping, scoring, and payload-building (Stages 2-3) are
identical either way, just scoped to fewer `input_id`s.

**Before extracting anything: a systematic table-discovery pass, not a
copy of a prior worked example.** Confirmed gap (see `knowledge/tooling_process.md`'s
matching "Confirmed incident" entry): a real session decided extraction
scope by copying the table names `knowledge/mapping_guide.md`'s prose happened to
mention from *prior* sessions on *other* managers, and missed two tables
with real data for the manager actually in scope (Security Master's
`performance` and `fund_note`). `knowledge/mapping_guide.md` documents what mapped
cleanly elsewhere -- it is not an inventory of every table that could
matter here. Every run, regardless of whether a worked example already
exists:

1. List all tables (`\dt public.*` via `connect.sh`).
2. Query `information_schema.columns` for every column shaped like the
   source's own entity-id columns (for Security Master:
   `manager_id`/`fund_id`/`fund_family_id`/`security_id`/`org_id`, plus
   any second-order id like `performance_id`/`position_id`/`company_id`).
3. For every table with one of those columns, `count(*)` scoped to this
   run's actual records -- and confirm the column is a real FK (check
   type/constraint, not just the name -- e.g. `arch_fund_data_table.fund_id`
   is an unrelated `bigint` sequence, not a FK to `fund.id`).
4. Every table that comes back with rows gets an explicit decision:
   extract-and-map it, or exclude it with a stated reason (workflow/CRM
   leakage, pure audit/changelog, no independent fact). Never silently
   skip a table that has rows for the records in scope.

For Security Master specifically, `manager`/`fund`/`fund_family`/
`security`/`performance` are the five tables that matter most across
every investigation so far -- pull these first, then let the systematic
pass above catch anything source- or manager-specific beyond them (see
`knowledge/mapping_guide.md`'s "Systematic table discovery" section for the full
SM table-by-table inventory this already produced).

Use DuckDB's `postgres_scanner` extension to read directly from the source
Postgres database and write raw tables straight into MotherDuck. Never export
to CSV and re-import — that wastes tokens, introduces encoding bugs, and
creates files that shouldn't exist. Generate the IAM token via bash, feed it
into a single `duckdb` invocation — no `.py` file:

```bash
set -a; source .env.security_master.prod; set +a
TOKEN=$(aws rds generate-db-auth-token --hostname "$POSTGRES_HOST" --port "$POSTGRES_PORT" \
  --username "$POSTGRES_USER" --region "$AWS_REGION" --profile "$AWS_PROFILE")
export MOTHERDUCK_TOKEN=$(grep MOTHERDUCK_TOKEN .env | cut -d= -f2)

duckdb md: <<SQL
CREATE DATABASE IF NOT EXISTS data_agent_local;
USE data_agent_local;
CREATE SCHEMA IF NOT EXISTS security_master;
INSTALL postgres; LOAD postgres;
ATTACH 'host=$POSTGRES_HOST port=$POSTGRES_PORT dbname=$POSTGRES_DB user=$POSTGRES_USER password=$TOKEN sslmode=require' AS sm (TYPE POSTGRES, READ_ONLY);
CREATE OR REPLACE TABLE security_master.manager AS SELECT * FROM sm.public.manager WHERE id IN (...);
DETACH sm;
SQL
```

**Storage layout: schema = source, table = source's own table name.**
Raw tables go into MotherDuck (`data_agent_local`) under a schema named
for the **source**, not a table-name prefix — `security_master.manager`,
`security_master.fund`, `security_master.fund_family`,
`security_master.security`, no `raw_` prefix. A second source gets its
own schema (e.g. `invest.position`), keeping sources cleanly separated by
schema while still living in one database a human can browse in the
MotherDuck UI immediately.

### Stage 2 — Build Atlas SDK payloads directly in SQL

Nested structures (`fees[]` with per-fee `attributes[]`, etc.) are not a
reason to reach for Python — `to_json()` and struct literals build these
directly. See `knowledge/tooling_process.md`'s opening section for why this rule is
absolute rather than "prefer SQL when convenient" (an earlier version of
this skill got this wrong and was corrected after a real session proved a
full `InstrumentCreateInputRecord` payload buildable entirely in SQL):

```sql
SELECT to_json({
    'entity_id': s.fund_id::VARCHAR,
    'name': s.name,
    'attributes': [
        {'name': 'eligible_investor_type', 'value': s.suitability_status::VARCHAR}
    ],
    'fees': [
        {'fee_type': 'management', 'attributes': [
            {'name': 'investment_rate', 'value': s.management_fee_invest::VARCHAR}
        ]}
    ]
})
FROM security_master.security s
```

Nested JSON is not a reason to reach for Python. Build the payload this way,
reading from the raw MotherDuck tables, per `knowledge/mapping_guide.md`'s worked
example for the source.

Before building a payload, verify the target shape against the installed
`opto_atlas_service` package directly (temporary `uv venv` + introspection,
see `atlas-ontology`) rather than assuming the shape documented there is
complete — that skill is kept accurate on a best-effort basis, but the
installed package is the actual source of truth.

### Stage 3 — Write `gate_verdict` to MotherDuck

One output table, at `output.gate_verdict` — the `output` schema holds
verdicts for every source (they're told apart by the row's own
`input_source_name`/`org_id`, not by which schema they live in). Every
entity and instrument gets a row scored on two independent QC dimensions,
not a single blended verdict (see `ingest-schemas` skill for the full rule
and current column list — includes the `IngestionSourceCreate` inputs:
`source_type`, `as_of`, `org_id`, `group_key`). `payload` is the only
JSON column — everything else is flat/typed so the table stays directly
queryable.

### Run tracking — `meta.agent_run`

Every invocation of `run.ts` writes exactly one row to `meta.agent_run`
when it finishes (success or failure) — the only way to answer "how many
times has this agent actually run." See `knowledge/tooling_process.md`'s
"Run tracking" section for the schema and why it's a single `INSERT`, not
an insert-then-update pattern.

## What NOT to do

See `knowledge/tooling_process.md`'s "Confirmed incident" entries for the full
writeup and cost of each of these, tested against real data — this list
is just the resulting rules:

- **No `.py` files for extraction, scoring, or payload-building.**
- **No CSV files** — DuckDB's `postgres_scanner` reads source DBs directly.
- **No local `.duckdb` files** — output goes to MotherDuck so humans can see it.
- **No multi-table gate schema** — one `gate_verdict` table; see
  `knowledge/ingest_gate_schema.md`'s revision history for why.
- **No single blended completeness-only verdict** — see `ingest-schemas` skill.

## Tool order

1. `connect.sh` + `psql` — only for ad-hoc exploration of live sources
2. `duckdb` CLI (`md:` / `md:data_agent_local`) + SQL — extraction (via
   `postgres_scanner`), scoring, payload-building (`to_json`/`struct`),
   writing `gate_verdict`. This is the default for everything, not a
   fallback.
3. Bash — generating the IAM token, wiring it into the `duckdb` invocation.
4. Python — not used in this pipeline. If a real case shows up where SQL
   genuinely cannot express something, that's the trigger to reconsider,
   not a default to reach for.

## MotherDuck connection

```bash
export MOTHERDUCK_TOKEN=$(grep MOTHERDUCK_TOKEN .env | cut -d= -f2)
duckdb md: -c "USE data_agent_local; SELECT count(*) FROM output.gate_verdict;"
```

The token lives in `.env` (gitignored). No database name on the initial
`md:` connection when creating a new database — that can hang; create/use
it explicitly once connected. Raw tables live under a per-source schema
(`security_master.manager`, etc.); the single output table lives under
`output.gate_verdict` — always qualify with the schema, don't rely on
DuckDB's default `main` search path.

## Reference implementation

None checked in as a `.py` file, deliberately — the pattern above (bash +
`duckdb` heredoc) is the reference. If you want a saved, reproducible
script for a specific run, save it as `.scratch/<source>_pipeline.sql`,
not `.py`.

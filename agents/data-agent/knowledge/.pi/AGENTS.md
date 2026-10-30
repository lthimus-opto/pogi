# Data Agent — Working Rules

Applies to any invocation working inside this directory, interactive or
non-interactive. See `./README.md` for an index of this directory and
`./project/vision.md` for what this agent is and where it's headed; this
file only holds the constraints that must hold on every single run,
source, and record.

## Tools — no `.py` files for extraction, scoring, or orchestration. Full stop.

**This has been violated repeatedly across real sessions. Read this section
fully before touching a source.**

Default tool order:
1. `./connect.sh` + `psql` — live reads against Atlas/Security Master for
   ad-hoc exploration only.
2. `duckdb` CLI (or `md:` connection string) + SQL — extraction,
   relationship checks, fill/completeness/accuracy scoring, writing
   `gate_verdict`, and building the Atlas SDK JSON payload. DuckDB's
   `to_json()`/`struct()` can build arbitrarily nested JSON directly in
   SQL — a real session proved this out end to end for a full
   `InstrumentCreateInputRecord`-shaped payload (fees, nested attributes,
   the works). **"SQL can't build nested payloads" is not true — don't
   reach for Python because a payload is nested.**
3. Python — only for the one thing SQL genuinely can't do: generating a
   fresh IAM auth token via `aws rds generate-db-auth-token` (needed
   inline for the `ATTACH ... TYPE POSTGRES` connection string). Even
   this should be a bash command substitution feeding a single `duckdb`
   invocation, **not a `.py` file written to disk**.

**Concrete pattern for extraction (this is the whole thing, no script file):**
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
Scoring and payload-building are separate `duckdb md:data_agent_local -c "..."`
or heredoc invocations against those raw tables — still no `.py` file.

**If you catch yourself about to run `write` on a `.py` file for this
pipeline, stop.** That is the trigger condition, not a judgment call —
writing a Python file to load, join, count, score, or build a payload from
rows is exactly the mistake this rule exists to block. The only legitimate
reason to write a `.py` file in this repo is something that is neither
extraction, scoring, nor payload-building (rare, and should be obvious
when it's actually true rather than convenient).

See `./knowledge/tooling_process.md` for the full incident history behind this rule
(pandas silently breaking NULL checks; the class of subtle bug Python
introduces here that SQL doesn't).

## Extraction scope — systematic discovery, never copied from a prior doc

**Confirmed gap** (see `knowledge/tooling_process.md`'s matching "Confirmed incident"
entry): a real run decided which tables to extract by copying the table
names `knowledge/mapping_guide.md`'s prose happened to mention from *prior* sessions
on *other* records, and missed two tables with real data for the record
actually in scope (Security Master's `performance` and `fund_note`). A
worked example documents what mapped cleanly *there* — it is never a
complete inventory of what could matter *here*.

Before extracting anything, every run, regardless of whether
`knowledge/mapping_guide.md` already has a worked example for this source: list all
tables, then query `information_schema.columns` for every column shaped
like the source's own entity-id columns, `count(*)` scoped to this run's
actual records for every table that has one (verifying it's a real FK, not
just a same-named column), and make an explicit extract-or-exclude call on
every table that comes back with rows. See `.pi/skills/tooling-pipeline`'s
Stage 1 and `knowledge/mapping_guide.md`'s "Systematic table discovery" section for
the concrete procedure. For Security Master specifically, `manager`/
`fund`/`fund_family`/`security`/`performance` are the five tables that have
mattered most across every investigation so far — treat a run that skips
`performance` as incomplete by default.

## Storage boundary

- Atlas's Postgres/Aurora and Security Master are read-only, full stop —
  reached only via `connect.sh`.
- Every artifact you produce goes into MotherDuck (`data_agent_local`),
  not a local file, laid out by **schema**, not by table-name prefix:
  - Raw extracted tables live under a schema named for the **source**
    (e.g. `security_master`), one table per source table, named exactly
    as the source names it (`security_master.manager`,
    `security_master.fund`, `security_master.fund_family`,
    `security_master.security` — no `raw_` prefix). A new source gets
    its own schema (e.g. `invest`), not a naming convention on the table.
  - The output tables live under `output` — `output.gate_verdict` (one
    schema for every source's verdicts, since `gate_verdict` already
    carries `input_source_name`/`org_id` per row to tell sources apart)
    and `output.gate_relationship` (the parent/child edges — see
    `ingest-schemas` skill; **writing `gate_verdict` without
    `gate_relationship` for every parent/child pair in scope is an
    incomplete run**, not an optional extra).
  - Run bookkeeping (one row per invocation — start/end time, status,
    row counts) lives at `meta.agent_run`, written once per run by
    `run.ts` itself, not by the agent's own Task 1-5 work — see
    `knowledge/tooling_process.md`'s "Run tracking" section.
  Scratch SQL/notes go under `./.scratch/` if needed. Never write to
  Postgres or Security Master. Never write outside `./.scratch/` on disk
  (headless runs are hard-blocked from this by
  `.pi/extensions/safety-guard.ts`).

## Skills available

You have skills loaded for: `atlas-ontology`, `source-mapping`,
`failure-modes`, `ingest-schemas`, `tooling-pipeline`, `entity-research`.
Load each one when you reach the task that needs it — don't read all docs
upfront. `entity-research` is specifically for ad-hoc "what can you tell
me about X" investigation questions (as opposed to mapping a source for
ingestion) — load it whenever a question asks for a research summary of
a real-world firm/manager/fund family by name.

## When running non-interactively

- There is no human to ask mid-run. If something is ambiguous, write it
  to the output as `DEFER` (see `knowledge/ingest_gate_schema.md`) with your
  reasoning captured — do not block, and do not guess a confident verdict
  you don't have evidence for.
- Only apply failure modes already catalogued in
  `./knowledge/failure_modes.md`. Don't decide mid-run that something new
  is a failure mode — flag the instance as `DEFER` instead, for
  a human to catalogue later.
- End with a short summary: counts per verdict/status, which failure-mode
  predicates fired and how often. Do not dump full rows.

## Source connection

All prod databases share one Aurora cluster — same host/region/profile,
different `POSTGRES_DB` and reader role per target:

- Security Master: `./connect.sh .env.security_master.prod`
- Atlas: `./connect.sh .env.atlas.prod`
- Invest: `./connect.sh .env.invest.prod`

IAM auth tokens expire in 15 minutes (AWS-fixed). `connect.sh` regenerates
a fresh token on every call — never try to reuse one. Same discipline
applies when generating a token manually for a `duckdb` `ATTACH` string.

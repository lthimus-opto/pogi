# Tooling Process

## The pipeline: extract → MotherDuck, build payloads in SQL, write one verdict table

**This replaced an earlier local-DuckDB-first process, and later dropped
Python entirely.** The original version of this doc loaded source CSVs
into a local `.duckdb` file, ran fill-rate views and `CASE`-logic verdicts
entirely in SQL, and wrote into a three-table ledger
(`ingest_gate_snapshot`/`staging`/`state`). That was tested against real
data and changed on two fronts:

1. **No CSV, no local DuckDB file.** DuckDB's `postgres_scanner` reads the
   source Postgres DB directly into MotherDuck — CSV intermediaries burned
   tokens and introduced their own bugs (quoting, encoding). A local
   `.duckdb` file is opaque to a human; writing to MotherDuck instead means
   a human can inspect every raw and output table in the MotherDuck UI
   immediately, no promotion step needed.
2. **No `.py` files for extraction, scoring, or payload-building, full
   stop.** An earlier version of this doc claimed "SQL doesn't naturally
   build deeply nested structures, Python does" and used that to justify
   a Python payload-building stage. **That claim was wrong**, proven wrong
   in a real session: a full `InstrumentCreateInputRecord`-shaped payload
   (nested `fees[]`, each with its own `attributes[]`) was built and
   validated entirely in SQL via `to_json()`/struct literals. Meanwhile,
   every real incident this pipeline hit from reaching for Python (see
   "Confirmed incident" below) was avoidable by staying in SQL. The rule
   is now absolute, not "prefer SQL when convenient" — see `.pi/AGENTS.md`.

See `.pi/skills/tooling-pipeline/SKILL.md` for the current three-stage
shape (extract → build payload → write `gate_verdict`, all in SQL) and
`knowledge/ingest_gate_schema.md` for why the ledger collapsed from three tables to
one. This doc keeps the deeper "why" and the reusable pieces that are
still true regardless of storage engine.

## Tool order (updated)

1. `connect.sh` + `psql` — ad-hoc exploration of live sources only.
2. `duckdb` CLI (`md:`/`md:data_agent_local`) + SQL — extraction via
   `postgres_scanner`, scoring, payload-building (`to_json`/struct
   literals), writing `gate_verdict`. This is the default for everything,
   not a fallback for "anything flat."
3. Bash — generating the IAM token, wiring it into the `duckdb`
   invocation.
4. Python — not used in this pipeline. No `.py` files for extraction,
   scoring, or payload-building; see `.pi/AGENTS.md`.

## What's still true from the old process

- **Relationship-integrity checks as plain joins** (orphans, FK
  mismatches) — this is exactly what SQL is for; don't loop over rows in
  a script to do it.
- **Failure-mode predicates** from `knowledge/failure_modes.md` still apply during
  mapping/scoring, but now split across two dimensions: **completeness**
  (core vs. supplementary fields, ratio against expected fields) and
  **accuracy** (does the content contradict itself). Accuracy can
  override an otherwise-passing completeness result -- see
  `knowledge/ingest_gate_schema.md`'s verdict truth table. Fill rate on raw columns
  is still a useful diagnostic signal while investigating an incident --
  just not the thing that sets `verdict` on its own anymore.
- **Log correction candidates one per field, on the same `gate_verdict`
  row** (`accuracy_proposed_value`), never a whole schedule crammed into
  one value (see `knowledge/mapping_guide.md`'s "before proposing any correction").
  There is no separate correction table -- `ingest_correction_schema.md`
  was dropped once corrections were shown to fit inside `gate_verdict`
  directly.

## Confirmed incident: pandas silently breaks NULL checks

A real session reached for a Python/pandas script to compute completeness
flags ("is this field non-null") against a MotherDuck query result loaded via
`fetchdf()`. Every single presence check came back wrong -- `bool(x)` where
`x` is a pandas-represented SQL `NULL` returns `True`, because pandas
represents `NULL` in object/string columns as `NaN` (a float), and
`bool(float('nan'))` is `True` in Python. This is exactly the class of bug
this doc already warned about ("a `to_double()`-style type error from
treating a numeric column as text") -- just a new instance of it, in Python
this time instead of SQL. The fix: redo the same logic in SQL directly
(`column IS NOT NULL`), which has no such surprise. **This is the concrete
case for the "SQL for anything flat" rule above** -- not a style preference,
a real, once-live bug that shipped wrong data until caught by a human
noticing the verdicts didn't match manual inspection.

## Confirmed incident: `now()` was not monotonic across separate `duckdb md:` CLI sessions

A real rescore pass (adding `ai_generated_preview_not_onboarded` to
`knowledge/failure_modes.md` and re-scoring `gate_verdict` rows for it) inserted new
rows whose `getvariable('run_ts')` (set from `now()` at the start of that
script) was **earlier** than the `recorded_at` already on the rows they
were meant to supersede -- a `now()` call in one `duckdb md:` CLI
invocation came back several hours behind `now()` in a separate
invocation run minutes later. Since `output.gate_verdict`'s whole
append-only design depends on `recorded_at DESC` picking the newest row
(`knowledge/ingest_gate_schema.md`'s `QUALIFY row_number() ... ORDER BY recorded_at
DESC = 1`), this silently broke "current state": the rescored rows were
in the table, correct in every column, and simply invisible to every
query that reads "latest" -- caught only because a human asked to verify
the rescore actually changed anything, not by any check in the pipeline
itself. In a non-interactive run with no human diffing before/after,
this would have shipped wrong "current" verdicts with no error anywhere.

**Root cause, not fully diagnosed**: not reproduced down to a specific
cause (clock drift between `duckdb`'s local engine and MotherDuck's
remote session, a timezone-handling difference between two separate
connections, or something else) -- flagged here as a real, confirmed
failure mode of the *tooling*, not of the data, so the next session
doesn't have to rediscover it from a silently-wrong query.

**The fix used this one time**: don't trust `now()` to be monotonic
across separate CLI invocations. Pin a rescore pass's `recorded_at` to
`(SELECT max(recorded_at) FROM output.gate_verdict) + INTERVAL 1 SECOND`
computed from the table itself, not from `now()`, guaranteeing every new
write is newest regardless of what the local/remote clocks disagree on.

**Not yet done, worth doing before the non-interactive runner exists**:
add an explicit check after every write this agent makes -- re-run the
"latest" query for the specific `input_id`s just written and confirm the
row just inserted is actually the one that comes back, failing loudly
(not just logging) if it isn't. Relying on humans to notice a silent
ordering bug doesn't survive the move to unattended runs.

## Confirmed incident: `connect.sh`'s SSL flag was a silent no-op

`connect.sh` passed `--set=sslmode=require` to `psql`. That's a psql
*variable* (equivalent to `\set sslmode require` inside a session), not a
libpq connection parameter -- it does nothing for the actual TLS handshake.
This went unnoticed because Security Master's reader role happened to
accept unencrypted connections; trying the same script against
`atlas_prod` surfaced it immediately (`pg_hba.conf rejects connection...
no encryption`). Fixed by setting the real parameter as an environment
variable: `PGPASSWORD="$TOKEN" PGSSLMODE=require psql ...`. Lesson: a
flag that looks right and has worked for every database tried so far isn't
proof it's actually doing what it says -- it just means every database
tried so far didn't need it to.

## Confirmed incident: Postgres only resolves an `ORDER BY` output-alias when it's a bare reference, not inside an expression

A denormalized/pivoted query (`MAX(CASE WHEN ... END) AS name_security_master`,
grouped, then `ORDER BY name_security_master IS NULL, name_security_master`)
failed with `ERROR: column "name_security_master" does not exist`. The
alias is valid and resolves fine as a *bare* `ORDER BY` item
(`ORDER BY name_security_master`) -- Postgres explicitly supports
referencing a `SELECT` list alias in `ORDER BY`. It does **not** resolve
the alias when it's wrapped inside any expression (`alias IS NULL`,
`alias + 1`, etc.) -- at that point Postgres tries to resolve the
identifier against the underlying `FROM`-clause columns instead, and
fails if no such column exists. Fix: don't hand-roll null-ordering with
the alias -- Postgres already sorts `NULL`s last by default in ascending
order, so `ORDER BY name_security_master, name_form_adv` alone was both
correct and simpler. Lesson: if an `ORDER BY` alias error ever shows
"column does not exist" for a column that's clearly in the `SELECT` list,
suspect an expression wrapping the alias before suspecting anything else.

## Confirmed incident: extraction scope copied from a prior doc's worked example, not verified against the live schema

A real session (Zero Prime, both Security Master orgs) decided which
tables to extract by pattern-matching on `knowledge/mapping_guide.md`'s SM worked
example -- pulling `manager`/`fund_family`/`fund`/`security` because those
are the tables that doc's prose names, plus three more (`field_provenance`,
`strategy_weight_exposure`, `internal_note`) recalled from other prose in
the same doc. The session had already run `\dt public.*` and seen the
full 63-table live schema -- including `performance` -- but never checked
which of those tables actually had rows for the manager in scope before
deciding what to extract. Two tables with real, relevant facts were
missed entirely: `performance` (fund-level IRR/TVPI/DPI/MOIC track
record, a dedicated FK'd table) and `fund_note` (quarterly manager-update
letters containing a full historical TVPI/MOIC time series in narrative
text, absent from the `performance` snapshot). Both surfaced only because
a human asked "is there no performance data?" after the run -- not
because the process caught it.

**Root cause**: `knowledge/mapping_guide.md` is a living record of what *prior*
sessions found on *other* managers -- it documents what mapped cleanly
there, not an inventory of every table that could matter for a *new*
manager. Treating its prose as a checklist is exactly the mistake the
doc's own "live schema outranks the doc" language (see `source-mapping`
skill) warns about -- just not followed here.

**The fix**: Task 1 now requires a systematic pass over
`information_schema.columns` for every column shaped like the source's
own entity-id columns, a `count(*)` scoped to the actual records in this
run for every table that has one, and an explicit extract-or-exclude
decision for every table that comes back with rows -- before any
extraction happens, every run, regardless of whether a worked example
already exists. See `run_prompt.md`'s Task 1 and `knowledge/mapping_guide.md`'s
"Systematic table discovery" section for the concrete procedure and the
full table-by-table results this produced for Security Master.

## A reusable check worth keeping verbatim: name-overlap excluding generic words


Naive word-overlap between a fund's name and its manager's name produces
false signals from generic corporate suffixes ("Partners," "Capital,"
"Fund"). Filter those before comparing:

```sql
list_filter(str_split(regexp_replace(lower(name), '[(),]', '', 'g'), ' '),
            x -> length(x) >= 3 AND NOT list_contains(
              ['partners','capital','fund','funds','management','advisors','group',
               'holdings','investments','llc','inc','ltd','value',
               'private','credit','tactical','opportunity','opportunities'], x))
```

Known limitation: this doesn't understand acronyms/initialisms ("FCM" for
"Fermat Capital Management" looks like a mismatch but isn't). Don't treat
a hit from this check as confirmed without eyeballing it.

## Modes: inception vs. incremental

Two distinct run shapes against the same source, same pipeline, same
output tables -- not two different mechanisms:

- **Inception** -- the first run against a source (or scope). No
  watermark, no delta: extract every table in full
  (`CREATE OR REPLACE TABLE ... AS SELECT * FROM sm.public.<table>`),
  map/score/write every record. This is the only run type covered
  elsewhere in this doc and in `TASK_SPEC.md` as written so far.
- **Incremental** -- every run after inception, whether scheduled (daily cron)
  or on-demand (a human asks for a fresh pull right now). **Both are the
  exact same code path** -- they differ only in what triggers them, not
  in what they do. Don't build two mechanisms for this.

### Watermark: derived live, never persisted

An incremental run's "since when" cursor is never stored anywhere as its own
piece of state -- it's always `SELECT max(updated_at) FROM
<schema>.<table>` against the **local MotherDuck raw table itself**,
computed fresh at the start of each incremental run. The local raw table
already *is* the record of what has been pulled; a separately persisted
watermark could drift from that reality (e.g. a prior run partially
wrote raw tables then crashed) in a way a live-derived one can't.
Confirmed real columns to key on: Security Master's
`manager`/`fund`/`fund_family`/`security`/`performance`/`fund_note` all
carry a real `updated_at`, bumped on both insert and update -- so a
single filter captures both cases in one query, no need to distinguish
them at extraction time.

### Extraction (Task 1) for an incremental run: delta, merged by replace-by-id

```sql
-- delta: every row changed since the local copy's own last-known state
CREATE OR REPLACE TEMP TABLE delta AS
SELECT * FROM sm.public.manager
WHERE updated_at > (SELECT max(updated_at) FROM security_master.manager);

-- merge into the raw table: replace-by-id, not append-only
-- (an update and a new insert land in `delta` the same way -- both are
-- just "a row whose updated_at moved past the watermark")
CREATE OR REPLACE TABLE security_master.manager AS
  SELECT old.* FROM security_master.manager AS old
  ANTI JOIN delta USING (id)
  UNION ALL
  SELECT * FROM delta;
```

**Use `ANTI JOIN`, not `NOT IN`.** `col NOT IN (subquery)` returns `NULL`
(matches nothing) for every row the moment the subquery contains a single
`NULL` -- a classic SQL foot-gun. `ANTI JOIN ... USING (id)` doesn't have
that failure mode and reads as exactly what's intended: "every old row
with no match in `delta`, plus every row in `delta`."

### Classify each delta row: new insert vs. updated existing

```sql
SELECT *, (created_at = updated_at) AS is_new_insert FROM delta;
```

This distinction drives how far rescoring reaches -- see
`knowledge/ingest_gate_schema.md`'s "Incremental scoring" section (and the
`ingest-schemas` skill) for the full rule: a new insert only reconsiders
its immediate parent, and only if that parent already has prior history;
an updated existing record reconsiders its immediate parent **and**
siblings (because `possible_misattributed_manager`'s family-consistency
check reaches across siblings, and child-corroboration reaches to the
parent). Mapping/scoring/payload-building (Stages 2-3 below) are
unchanged either way -- same SQL, just scoped to a smaller set of
`input_id`s than an inception run.

### What an incremental run does *not* try to catch

An incremental run only reconsiders the delta record itself, its
immediate parent, and (for updates) its siblings -- one bounded hop, not
a wider dependency search. This already covers the case of a new child
quietly making a thin, pre-existing parent independently loadable (new
insert under an existing parent triggers a parent recheck, by design).
What it won't catch is anything reaching further than one hop, or any
future failure mode added to `knowledge/failure_modes.md` that compares
across a wider set than "parent" or "same-parent siblings" without this
doc being updated to match. The backstop for that is an occasional full
rescore (literally rerunning the inception path) plus Loop B's
on-demand recheck of a specific record a human asks about -- not
something the incremental job itself should try to solve preemptively.

## Run tracking: `meta.agent_run`

Every invocation (`run.ts`) writes exactly **one** row to
`meta.agent_run` when it finishes -- not two (no insert-then-update).
`run.ts` is a single synchronous process that already knows the full
outcome (success/failure, timing, row counts) by the time its
`try/finally` block runs, so there's no partial-state window worth
protecting against the way `gate_verdict`'s append-only discipline
protects judgment history. If `run.ts` is killed before `finally` runs,
that invocation simply leaves no row -- an honest, crude signal on its
own, not a gap worth solving with a `status='running'` row written at
start (that's a different feature -- hang-detection -- not needed yet).

```sql
CREATE TABLE meta.agent_run (
    run_id          VARCHAR,   -- uuid, generated once at the top of run.ts
    source          VARCHAR,
    env_file        VARCHAR,
    scope           VARCHAR,
    mode            VARCHAR,   -- 'inception' | 'incremental'
    triggered_by    VARCHAR,   -- 'cron' | 'cli' | 'human:<name>'
    status          VARCHAR,   -- 'success' | 'failed'
    started_at      TIMESTAMP,
    completed_at    TIMESTAMP,
    error           VARCHAR,   -- NULL unless status='failed'
    gate_verdict_rows_written       INTEGER,
    gate_relationship_rows_written  INTEGER
)
```

This is the only way to answer "how many times has this agent actually
run" -- before this table existed, that question had no answer short of
reading terminal scrollback.

## Where working files live

Everything a session produces that isn't already in MotherDuck — scratch
scripts, notes, the reference pipeline — goes in `data-agent/.scratch/`
(gitignored). Raw and output tables themselves belong in MotherDuck, not
as local files; per `.pi/extensions/safety-guard.ts`, headless/autonomous
runs are hard-blocked from writing anywhere else on disk. This is real
manager/fund data; it must never be committed.

**Resolved** (was "open" in the previous version of this doc): the
question of whether a local `.duckdb` file becomes the persistent ledger
is moot now — MotherDuck is the persistent store, not a local file, per
the tooling-pipeline skill.

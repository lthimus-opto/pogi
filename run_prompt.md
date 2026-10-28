# Data Agent Run — Single Source

Source: **{{SOURCE}}**
Env file: **{{ENV_FILE}}**
Mode: **{{MODE}}** -- `inception` (first run, full extract/score)
or `incremental` (every run after, scheduled or on-demand -- same path either
way; see `TASK_SPEC.md`'s "Mode" section and
`knowledge/tooling_process.md`'s "Modes" section for the mechanics)
Scope: **{{SCOPE}}**
Output: MotherDuck database `data_agent_local` -- raw tables under a
per-source schema (e.g. `security_master.manager`), `gate_verdict` at
`output.gate_verdict`, `gate_relationship` at `output.gate_relationship`

---

## Instructions

Run Tasks 1-5 from `./TASK_SPEC.md` against this source, end to end,
non-interactively, restricted to the **Scope** stated above (if Scope says
the entire source, run against the entire source -- otherwise every task
below applies only to records matching Scope, not the whole database).
Your standing rules are in `.pi/AGENTS.md` — they are already loaded into
your context.

### Task 1 — Extract

1. Load skill: `tooling-pipeline` for the standard pipeline.
2. **If Mode is `inception`**: orient on the schema first via
   `./connect.sh {{ENV_FILE}}`: list all tables (`\dt public.*`), then run
   the systematic FK-column scope check below -- every run, even when
   `knowledge/mapping_guide.md` already has a worked example for this
   source. Never decide extraction scope by copying the table names a
   prior session's mapping-guide prose happens to mention -- that doc is
   written from other records and is not a checklist (confirmed gap: a
   real run copied Security Master's manager/fund_family/fund/security
   from `knowledge/mapping_guide.md`'s worked example and missed
   `performance` and `fund_note` entirely, both of which had real rows in
   scope -- see `knowledge/mapping_guide.md`'s "Systematic table discovery"
   note and `knowledge/tooling_process.md`'s matching incident writeup).
   - If **Scope** above names a specific subset (e.g. a manager, an
     `org_id`, a record count ordered by a date column), resolve it to
     concrete source IDs *first*, against the live source via
     `connect.sh` -- then scope every table-discovery/extraction query in
     this task to those IDs. Never extract the whole table "to be safe"
     when Scope says otherwise.
   - Query `information_schema.columns` for every column named like the
     source's own entity-id columns (for Security Master:
     `manager_id`/`fund_id`/`fund_family_id`/`security_id`/`org_id`/
     `performance_id`/`position_id`/`company_id`).
   - For every table with one of those columns, run a `count(*)` scoped to
     this run's actual records (not the whole table) -- confirm the column
     is a real FK to the entity id, not a coincidentally-named unrelated
     column (e.g. Security Master's `arch_fund_data_table.fund_id` is a
     `bigint` sequence, not a FK to `fund.id` -- check the type/FK
     constraint, don't assume from the column name alone).
   - Every table with rows scoped to this run's records gets an explicit
     decision: extract it (real fact, mapped per Task 2), or explicitly
     exclude it with a stated reason (workflow/CRM leakage, pure
     audit/changelog, no independent fact beyond a table already
     extracted). Never silently skip a table that has rows.
   - Extract directly from the source Postgres DB into MotherDuck using
     DuckDB's `postgres_scanner` (`ATTACH ... TYPE POSTGRES`) — no CSV
     intermediary, no local `.duckdb` file. Full `CREATE OR REPLACE TABLE
     ... AS SELECT * FROM sm.public.<table>` per extracted table.
3. **If Mode is `incremental`**: skip the table-discovery pass above (the
   set of tables to pull incrementally is whatever inception already decided
   to extract for this source) and instead, for each of those tables:
   - Derive the watermark live: `SELECT max(updated_at) FROM
     <schema>.<table>` against the **local MotherDuck raw table**, never
     a persisted value.
   - Pull the delta from live Postgres: `WHERE updated_at > watermark`.
   - Merge delta into the raw table by replace-by-id: `ANTI JOIN ...
     USING (id)` + `UNION ALL` -- never `CREATE OR REPLACE TABLE ... AS
     SELECT *` (that would discard everything outside the delta window)
     and never `NOT IN` (breaks silently on a `NULL` id). See
     `knowledge/tooling_process.md`'s "Modes" section for the exact
     pattern.
   - Classify each delta row: `created_at = updated_at` -> new insert;
     otherwise -> updated existing record. Carry this classification into
     Task 4 (it decides how far rescoring reaches).

### Task 2 — Map onto Atlas

1. Load skill: `source-mapping`.
2. Check whether `./knowledge/mapping_guide.md` already has a worked example
   for this source. If yes, follow it. If no, derive
   the mapping using the decision test and the four red flags.
3. Load skill: `atlas-ontology` if you need to check the Atlas schema or
   the `opto-atlas-service` SDK payload shapes.
4. Verify the live Atlas schema via `./connect.sh .env.atlas.prod` — don't
   trust any doc's inventory without checking.

### Task 3 — Find what's wrong

1. Load skill: `failure-modes`.
2. **If Mode is `inception`**: run every catalogued predicate against
   every record in the raw MotherDuck tables.
   **If Mode is `incremental`**: run every catalogued predicate against the
   delta records plus the bounded set Task 4 step 6 below defines
   (immediate parent, and for updated-existing records, siblings) -- not
   the entire source every time. Each predicate is either a
   **completeness** signal or an **accuracy** check with a severity
   (`block`/`correct`/`flag`).
3. For anything that looks wrong but isn't catalogued: `accuracy_passed = false`,
   `accuracy_failure_mode = NULL`, severity `flag`, reasoning in
   `accuracy_reason` — never invent a new catalogued failure mode mid-run.

### Task 4 — Propose

1. Load skill: `ingest-schemas` for the `gate_verdict` schema and the
   Accept/Quarantine/Reject verdict rule — derived from **both**
   `completeness_passed` and `accuracy_passed`/`accuracy_severity`, not a
   raw attribute count.
2. Populate `source_type` (`'manual'` — decided, not a placeholder),
   `as_of` (the source record's own `created_at`), `org_id` (the source
   record's own `org_id` — Security Master is multi-tenant, this is
   per-record, never a run-wide constant), `group_key` (`'data-agent'`).
   Leave `source_external_key`/`pipe_type`/`pipe_run_id`/`uploaded_by`
   unset — the downstream pipe fills those in.
3. Build the Atlas SDK payload directly in SQL (`to_json`/struct literals)
   for each entity/instrument (`EntityCreateInputRecord` /
   `InstrumentCreateInputRecord`), per `knowledge/mapping_guide.md`'s worked
   example -- no `.py` file, see `tooling-pipeline`. If the record has
   `universal_id` set, use the linked/canonical record's name for
   `EntityNameCreate`, not this org's own `name` field -- see
   `atlas-ontology`.
4. Any accuracy `correct`-severity fix goes into `accuracy_proposed_value`
   on the same row -- there is no separate correction table. Only use a
   `correct`-severity failure mode when the source field actually has
   convertible content (not a placeholder like `'null'`/`'none'`/empty),
   and set `accuracy_proposed_value` to the real parsed target value, not
   the raw narrative text restated.
5. Populate `parent_input_id` on every row -- the parent record's own
   `input_id` one level up the hierarchy (manager for a fund, fund for an
   instrument), `NULL` for a manager. Required on every row, not optional.
6. **If Mode is `incremental`**: for each delta record, determine the
   bounded rescoring set per `knowledge/ingest_gate_schema.md`'s "Incremental
   scoring" section --
   - new insert (per Task 1's classification): the record itself, plus
     its immediate parent **only if that parent already has a prior
     `gate_verdict` row**;
   - updated existing record: the record itself, plus its immediate
     parent, plus every sibling sharing the same `parent_input_id`.
   The delta record itself always gets a fresh `gate_verdict` row
   (step 7). A parent/sibling pulled in only by this rule is
   diff-aware -- score it, but only proceed to write it in Task 5 if its
   recomputed `verdict`/`completeness_passed`/`accuracy_passed`/
   `accuracy_failure_mode` actually differs from its current latest row.
7. Every delta record (inception: every record in scope) gets exactly one
   fresh `gate_verdict` row. No record is silently skipped.
8. For every parent/child pair among the records just scored, write a
   row to `output.gate_relationship` (`knowledge/ingest_gate_schema.md`)
   -- `DEFER` with `payload = NULL` if the parent hasn't resolved in
   Atlas yet, a real payload once it has. This is a required part of
   every run, not an optional extra -- a run that writes `gate_verdict`
   without `gate_relationship` is incomplete. For `incremental`, a new insert
   with a parent gets a **new** `gate_relationship` row (the edge didn't
   exist before); an updated existing record doesn't need a new edge.

### Task 5 — Store

1. Write `gate_verdict` rows to `output.gate_verdict` in MotherDuck
   (`data_agent_local`). Populate the new `input_source_name` column
   (e.g. `'security_master'`) on every row. **For `incremental`**: write the
   delta record's row unconditionally; write a pulled-in parent/sibling
   row only when Task 4 step 6 found it actually differs from its
   current latest row -- otherwise skip writing that one, it stays as it
   was.
2. Write `gate_relationship` rows to `output.gate_relationship` in the
   same database -- see Task 4 step 8. Both tables together are "the
   output" of this run; see `knowledge/ingest_gate_schema.md`.
3. Save the reproducible SQL to `./.scratch/{{SOURCE}}_pipeline.sql` --
   not a `.py` file.

### Summary

End with a report:
- Mode (`inception`/`incremental`) and, for `incremental`, the watermark range
  used per table
- Total records per source table (inception) or delta row counts per
  table, split new-insert vs. updated-existing (incremental)
- Verdict counts: LOAD / DEFER / REJECT
- Completeness failures: count
- Accuracy failures: count, by failure mode and severity
- Any uncatalogued accuracy anomalies flagged (`accuracy_failure_mode IS NULL`)
- `gate_relationship` rows written: count, by `relationship_type` and
  `verdict` (LOAD vs DEFER-pending-parent-resolution) -- `0` here is a red
  flag, not a clean result, if any parent/child pairs existed in scope
- For `incremental`: how many pulled-in parent/sibling rows were rescored vs.
  actually written (the diff-aware count) -- the gap between those two
  numbers is expected and healthy, not a bug

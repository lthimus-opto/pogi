# Ingest Gate — Schema Design

**Status**: implemented — `output.gate_verdict` exists in MotherDuck
(`data_agent_local`) and has been written to across real runs (Security
Master, Silver Lake, last-10-managers rescore; see `.scratch/*_pipeline.sql`
for the `CREATE TABLE IF NOT EXISTS` + `INSERT` statements each run
reproduces). This doc is both the design reference and the current schema
— any change here should be applied as a new migration against the live
table (see "Schema changes against a live table" below), not just a doc
edit.

**Storage**: MotherDuck, database `data_agent_local`, not a local DuckDB
file. Laid out by **schema**, not by table-name prefix: raw extracted
tables live under a schema named for the **source**
(e.g. `security_master.manager`, `security_master.fund`, no `raw_`
prefix); the single output table lives at `output.gate_verdict`. Atlas's
Postgres/Aurora cluster and Security Master remain **read-only** for this
agent, reached only via `connect.sh`/`postgres_scanner` — nothing the
agent produces is ever written back there. Writing straight to MotherDuck
(instead of a local `.duckdb` file promoted later) means a human can
inspect every verdict in the MotherDuck UI immediately, with no separate
promotion step. See `knowledge/tooling_process.md`.

## Revision history

**v1 → v2**: simplified from three tables mirroring Atlas's
`RESOLUTION_INPUT_SNAPSHOT` / `RESOLUTION_STAGING` / `RESOLUTION_INPUT_TARGET`
triad down to one `gate_verdict` table — the snapshot duplicated raw
tables as JSON blobs for no benefit, and the staging/state split added
history-tracking complexity nobody was reading.

**v2 → v3**: `ingest_correction_schema.md` (a fourth table, for
field-level value corrections) is **dropped**. And `gate_verdict` itself
changed shape: instead of one blended `verdict` computed from a mapped-field
count, the table now scores two independent QC dimensions —
**completeness** (enough fields filled) and **accuracy** (content doesn't
contradict itself) — with `verdict` derived from both. This closes a real
gap: a record can be completely filled in and still be wrong (e.g. name
contains "Credit," but the mapped strategy attribute says "Private
Equity") — counting mapped fields alone never catches that.

**v3 → v4**: added `source_type`/`as_of`/`org_id`/`group_key` --
the inputs Atlas's own `IngestionSourceCreate` needs -- after discovering
Security Master is genuinely multi-tenant (distinct `org_id`s per client,
some records explicitly cross-linked via `universal_id`). `org_id` is now
a per-record field, not a run-wide constant. `source_external_key` is
not this agent's concern -- the downstream pipe fills it in, same as
`pipe_type`/`pipe_run_id`/`uploaded_by`.

**v4 → v5**: renamed `anchor_id`/`anchor_name`/`type` to
`input_id`/`input_name`/`input_type` -- "anchor" read as if the table were
about Atlas's own resolved anchor (the entity/instrument a fact attaches
to once resolved); these columns are actually just naming the source
input record itself, before any resolution happens. Also reordered
columns into logical groups (identity → ingestion-source inputs →
completeness → accuracy → verdict → reason → payload → provenance) and
added `recorded_at`/`recorded_by` -- audit columns for when a row was
written and by what (an agent session, an interactive run, a human
correction), separate from `as_of` (the source record's own fact-date).

**v5 → v6**: changed the MotherDuck storage layout and added
`input_source_name`. Raw tables move from a `raw_`-prefixed name in the
default schema to a proper schema per source (`security_master.manager`,
not `raw_manager`) -- multiple sources stay cleanly separated without a
naming convention doing the work a schema should. The output table moves
from the default schema to `output.gate_verdict` -- one schema for every
source's verdicts, since a row's own `input_source_name` (new column,
right before `anchor_type`) plus `org_id` already say which source and
tenant it came from. `input_source_name` records that source name
(`'security_master'`) directly on the row so a query against
`output.gate_verdict` never needs to know which schema a row's raw table
lived in to answer "which source is this."

**v6 → v7 (current)**: no column changes -- codified an operating
convention that was previously implicit and got violated in a real
session (a wrong verdict was `UPDATE`d in place, destroying the record of
it ever being wrong). `gate_verdict` is now explicitly append-only: a
re-score always `INSERT`s a new row with its own `recorded_at`/
`recorded_by` rather than overwriting the old one, and "current state" is
a `QUALIFY row_number() ... ORDER BY recorded_at DESC = 1` query keyed on
`(input_source_name, input_id)`, not a new column or a persisted view. See
"Append-only" section below.

**v7 → v8 (current)**: added `parent_input_id` -- confirmed real gap: a
full-source Security Master run wrote 17,770 `gate_verdict` rows
(managers, funds, instruments) with no column linking a fund to its
manager or an instrument to its fund, and `gate_relationship` wasn't
written that run either, so the hierarchy was unrecoverable from
`output.gate_verdict` alone short of fragile `input_name` text-matching
or rejoining raw source tables by hand. `parent_input_id` is the parent
record's own `input_id`, one level up (manager for a fund, fund for an
instrument), `NULL` for a record with no parent (a manager). `input_id`
was already implicitly "this record's own id, as a child of
`parent_input_id`" -- this column makes that relationship explicit
without requiring a prefix on `input_id` itself. Existing pre-migration
rows have `parent_input_id = NULL` regardless of level -- not
distinguishable from a true top-of-hierarchy row until backfilled or
rescored; treat any row with `parent_input_id` unpopulated and
`recorded_at` before this migration as unknown, not "no parent."

## Dialect note

- `JSON` instead of `JSONB` — DuckDB doesn't distinguish the two. Only
  `payload` is JSON; every other column is a flat, typed value (booleans,
  strings, or native `VARCHAR[]` lists) so the table stays directly
  queryable without unpacking blobs.
- MotherDuck/DuckDB `UUID`-equivalent identifiers can just be the source's
  own IDs (`input_id`) — no need to mint a new synthetic key when the
  source's ID is already stable and unique per record.

## Schema changes against a live table

Now that `output.gate_verdict` is a real, populated MotherDuck table, a
schema edit here is a migration, not just a doc update. Each
`.scratch/*_pipeline.sql` currently re-issues its own
`CREATE TABLE IF NOT EXISTS output.gate_verdict (...)` with whatever
column set this doc had at the time it was written — `IF NOT EXISTS`
means that statement is a no-op against the live table today, so adding/
renaming a column here does **not** retroactively change existing rows
or get picked up by rerunning an old pipeline script. When this doc's
column set changes:

1. Run an explicit `ALTER TABLE output.gate_verdict ADD COLUMN ...` (or
   the rename/drop equivalent) against the live table directly —
   don't rely on a future `CREATE TABLE IF NOT EXISTS` to do it.
2. Backfill the new column on existing rows where derivable, or leave it
   `NULL` for pre-migration rows and say so in this doc's revision
   history entry — a reader comparing old vs. new rows needs to know
   which rows predate the column.
3. Update the `CREATE TABLE` block below (the one new pipeline runs copy)
   to match, so the next fresh run's `IF NOT EXISTS` is consistent with
   the live table rather than silently stale.

## `gate_verdict` — the only table

```sql
CREATE TABLE output.gate_verdict (
    -- identity: which source record this row is about
    input_source_name          VARCHAR,    -- the source this record came from, e.g. 'security_master' -- matches the raw table's schema name
    anchor_type                VARCHAR,    -- 'entity' or 'instrument'
    input_id                   VARCHAR,    -- source ID (SM manager_id, fund_id, security_id) -- the record's OWN id, see "Multi-tenant sources" below
    parent_input_id             VARCHAR,    -- the PARENT record's own input_id, one level up the hierarchy (manager's input_id for a fund, fund's input_id for an instrument); NULL for a record with no parent (e.g. a manager) -- see "Hierarchy: parent_input_id" below
    input_name                 VARCHAR,    -- human-readable name
    input_type                 VARCHAR,    -- 'management_company', 'fund_vehicle', 'lp_interest'

    -- ingestion source: inputs Atlas's IngestionSourceCreate needs (source_external_key excluded -- the downstream pipe fills it in)
    source_type                VARCHAR,    -- constant 'manual' for now (IngestionSourceType enum)
    as_of                      DATE,       -- the source record's own created_at
    org_id                     VARCHAR,    -- the source record's own org_id, per-record
    group_key                  VARCHAR,    -- constant 'data-agent'

    -- completeness check: are enough fields filled in?
    completeness_passed        BOOLEAN,    -- a core field is mapped AND the ratio clears the bar
    completeness_core_mapped   VARCHAR[],  -- which core fields mapped
    completeness_missing       VARCHAR[],  -- expected fields (core or supplementary) not mapped
    completeness_reason        VARCHAR,    -- "9 out of 12 expected fields mapped (75%), core fields present: ..."

    -- accuracy check: does the content contradict itself?
    accuracy_passed            BOOLEAN,    -- true if no accuracy issue found
    accuracy_failure_mode      VARCHAR,    -- catalog name from failure_modes.md; NULL if passed or uncatalogued
    accuracy_severity          VARCHAR,    -- 'block' | 'correct' | 'flag'; NULL if passed
    accuracy_reason            VARCHAR,    -- what's wrong, e.g. "name contains 'Credit', strategy=Private Equity"
    accuracy_proposed_value    VARCHAR,    -- proposed fix; only set when severity = 'correct'

    verdict                     VARCHAR,    -- 'LOAD' / 'DEFER' / 'REJECT' -- derived, see rule below

    reason                      VARCHAR,    -- plain-English summary combining both dimensions

    payload                     JSON,       -- full Atlas SDK payload (EntityCreateInputRecord / InstrumentCreateInputRecord)

    -- provenance: when this row was written, and by what
    recorded_at                 TIMESTAMP,  -- when the agent wrote this row (not the source's own fact-date -- that's as_of)
    recorded_by                 VARCHAR     -- what wrote it, e.g. an agent session/run id, or a human reviewer's identifier for a manually-edited row
)
```

## Append-only: never `UPDATE`, always `INSERT` a new row

`gate_verdict` is append-only. A re-score of a record that already has a
row -- a rule changed, a correction landed, the source re-pulled -- never
mutates the existing row. It inserts a **new** row for the same
`input_id`, with its own fresh `recorded_at`/`recorded_by`. The old row
stays exactly as it was written. This isn't a style preference: it's what
`recorded_at`/`recorded_by` are *for* -- a column that only ever holds one
value (because every write overwrites it) isn't provenance, it's just a
timestamp. Confirmed needed in practice: a real session `UPDATE`d a row
in place to fix a wrong verdict and silently destroyed the fact that the
wrong verdict had ever been written, or why it changed -- exactly the
traceability a human reviewing this table needs most.

`recorded_by` should say *why* a new row exists when it's a re-score
rather than a first pass, e.g. `'data-agent-session-<id>: rescore after
incomplete_for_lifecycle_stage removed from catalog'` -- not just which
session wrote it.

**"Which row is current" is a query, not a column.** The identity key for
"is this a re-score of the same record" is `(input_source_name, input_id)`
-- `input_id` is the source's own primary key (e.g. `manager.id`), which
already determines everything else about which record this is, including
its `org_id` (a record's `org_id` never changes across re-scores -- it's
just a column on the row, same as `input_name`, not a separate dimension
to key on). No new column, no persisted view -- query for current state
when you need it:

```sql
SELECT * FROM output.gate_verdict
QUALIFY row_number() OVER (PARTITION BY input_source_name, input_id ORDER BY recorded_at DESC) = 1
```

Two different `org_id`s are two different `input_id`s (two genuinely
different source rows, e.g. two orgs' separate copies of the same
real-world manager) -- each gets its own independent append-only history
under its own `input_id`. That's not a deduplication case; see
`knowledge/mapping_guide.md`'s "Correction: SM's own lineage fields are not Atlas's
concern" for how to decide which org's *copy* to actually map, which is a
separate judgment call from this one.

**Confirmed risk: don't trust `now()` to be monotonic across separate
sessions.** A real rescore pass hit a case where `now()` in one `duckdb
md:` CLI invocation returned a timestamp several hours behind `now()` in
a different invocation run minutes later -- the new rows were correct in
every column but their `recorded_at` was *older* than the rows they were
meant to supersede, so the `QUALIFY ... ORDER BY recorded_at DESC = 1`
query above silently kept serving the stale rows as "current." See
`knowledge/tooling_process.md`'s matching "Confirmed incident" entry. When writing
a rescore pass (not a first-pass run against a fresh extraction), pin
`recorded_at` to `(SELECT max(recorded_at) FROM output.gate_verdict) +
INTERVAL 1 SECOND` rather than `now()`, and verify after writing that the
new rows actually come back from the "latest" query -- don't assume the
write succeeded just because the `INSERT` didn't error.

## Hierarchy: `parent_input_id`

Added in v8. Every `gate_verdict` row carries `parent_input_id` --
the parent record's own `input_id`, one level up the source's hierarchy.
The `input_type` values below (`management_company`, `fund_vehicle`,
`lp_interest`) are Atlas's own fixed `EntityType`/`InstrumentType` enum
vocabulary (see `atlas-ontology` skill), not something Security Master
invented -- any source mapping onto a manager-like entity, a fund-like
entity, and an LP-interest-like instrument would use these same three
values. What *is* specific to Security Master here is just the concrete
worked instance below -- which of SM's own tables map to which Atlas
level, and in what order:

- management_company (manager): `parent_input_id = NULL` -- top of the
  hierarchy
- fund_vehicle (fund): `parent_input_id` = that fund's manager's
  `input_id`
- lp_interest (instrument/security): `parent_input_id` = that
  instrument's fund's `input_id`

`input_id` was already implicitly "this record's own id, as a child of
`parent_input_id`" -- this column just makes the other half of that
relationship explicit and queryable, directly on the row, with zero
rejoining of raw source tables required. **Every row populates this
column, including `NULL` for a top-of-hierarchy record** -- an unset
value is indistinguishable from "this is a manager" and defeats the
point; populate it in the same Task 4 pass as every other column.

This is in addition to, not instead of, `gate_relationship` (below) --
`parent_input_id`/`input_id` on a child's row are exactly
`parent_silver_id`/`child_silver_id` on that relationship's row, so
`gate_relationship` can be built directly from `gate_verdict` once it's
written, no extra lookup needed.

## Incremental scoring: how far rescoring reaches

See `knowledge/tooling_process.md`'s "Modes" section for the full
inception-vs-incremental mechanics (watermark, delta extraction, merge). This
section covers only what an **incremental run** does once it has a delta: which
other records, if any, get rescored alongside the ones that actually
changed.

Two mechanisms in the whole failure-mode catalog reach outside a
record's own row -- nothing else does, so the rescoring rule is bounded
to exactly these two, not an open-ended search:

1. **Child-corroboration** (`completeness_passed` can pass on the
   strength of a child that independently scores `LOAD` -- see the
   completeness rule above) -- reaches exactly one hop up: child to its
   immediate `parent_input_id`. Never further (a grandparent is never
   reconsidered directly; it would only move if the parent's own
   recomputed verdict changes, which is a separate rescore of the
   parent in its own right).
2. **`possible_misattributed_manager`** (`knowledge/failure_modes.md` #5)
   -- the discriminator is explicitly "does this mismatch happen
   consistently across every sibling fund in the family, or is it a
   one-off" -- so this reaches every record sharing the same
   `parent_input_id`, not just the one that changed.

Classify each delta row (per `knowledge/tooling_process.md`):

| Delta row | Rescore itself | Rescore parent | Rescore siblings |
|---|---|---|---|
| New insert (`created_at = updated_at`) | Always append | Only if the parent already has a prior `gate_verdict` row (new corroborating evidence for an existing judgment) | No |
| Updated existing record | Always append | Yes | Yes (same `parent_input_id`) |

**Two different append rules, not one:**

- The delta record itself: **always** `INSERT` a fresh row, no
  diff-check -- its source data changed, so a new judgment is always
  warranted, independent of whether that judgment happens to come out
  the same as before.
- A parent or sibling pulled in only because of the rule above (whose
  own source row did **not** change this run): **diff-aware** -- only
  `INSERT` if the recomputed `verdict`/`completeness_passed`/
  `accuracy_passed`/`accuracy_failure_mode` actually differs from its
  current latest row. This is what stops one new child from writing a
  redundant daily row onto a parent that didn't actually flip.

A new insert with a parent also gets a new `gate_relationship` row (the
edge didn't exist before). An updated existing record doesn't need a new
edge -- it already has one.

**What this deliberately does not do**: chase a dependency graph wider
than one hop, or re-verify every record every incremental run "to be
safe." This is a considered tradeoff, not an oversight -- see
`knowledge/tooling_process.md`'s "What an incremental does not try to catch" for
the backstop (occasional full rescore + Loop B's on-demand recheck). If
a future failure mode reaches further than "parent" or "same-parent
siblings" (nothing in the catalog does today), this table needs updating
to match -- don't assume today's two mechanisms are the ceiling forever.

## Multi-tenant sources: why `org_id` is per-record

Security Master is genuinely multi-tenant: the same real-world manager can
exist as separate rows under different SM `org_id`s (confirmed while
investigating "Zero Prime" -- 66 distinct `org_id` values in `manager`
alone, some explicitly linked via `universal_id` +
`extraction_copy_manager_data_result='LINKED_MANAGER'`). This lines up
directly with Atlas's own `INGESTION_SOURCE.org_id` ("organization that
owns or uploaded this source") -- so `gate_verdict.org_id` comes from
**the source record's own `org_id`**, not a run-wide constant. Two orgs'
copies of the same manager produce two `gate_verdict` rows.

**Deliberately kept simple**: `input_id` stays the record's own id
(e.g. that org's `manager.id`) -- no forcing two orgs onto one shared
identity, no trying to pre-resolve which Atlas `entity_id` they'll land
on. That's Atlas's own entity-resolution job (exact identifier -> exact
silver_id -> exact name -> fuzzy embedding/soundex/trigram -> LLM
tiebreaker), not this table's. The one mapping-time adjustment that
matters: when `universal_id` is set on a record, use the **linked/
canonical record's name**, not this org's own `name` field, when building
`EntityNameCreate` -- a cosmetic naming difference between two orgs'
copies ("Zero Prime" vs. "Zero Prime Ventures") can otherwise sabotage
Atlas's own name-matching for no reason.

**Correction, confirmed on real data**: `universal_id`/
`extraction_copy_manager_data_result` are SM's own internal copy-lineage
bookkeeping -- not an Atlas-relevant fact, and not something that should
drive `accuracy_passed`/`verdict` on its own. Silver Lake's manager record
had `extraction_copy_manager_data_result = 'LINKED_MANAGER'` with a blank
`universal_id`, while a second org's copy's `universal_id` pointed back at
it -- a real run flagged this and `DEFER`'d an otherwise 100%-complete,
fully-sourced record over it. That was wrong: this agent doesn't need to
know who copied from whom, only which copy is cleanest. When multiple
org-copies of the same manager/fund exist, compare them **on substance**
(completeness, value agreement) and map whichever copy is cleanest/most
complete as the source of truth. Real cross-org discrepancies in *content*
(e.g. one org's fund target size differing from another's) are the actual
signal worth a `flag`/`DEFER` when they can't be adjudicated -- disagreeing
lineage metadata alone is not. See `knowledge/failure_modes.md`'s "Known non-issues"
section and `knowledge/mapping_guide.md`'s matching correction.

## Verdict logic: Accept / Quarantine / Reject

Still the standard three-tier data-quality gate pattern (Kimball's ETL
"quality screens", Great Expectations' pass/fail, dbt's pass/warn/error) —
colloquially "good, bad, ugly" — now derived from **both** checks, with
accuracy able to override an otherwise-clean completeness result:

| `completeness_passed` | `accuracy_passed` | `accuracy_severity` | `verdict` |
|---|---|---|---|
| true | true | — | `LOAD` |
| true | false | `block` | `REJECT` — complete, but content is confidently wrong |
| true | false | `correct` / `flag` | `DEFER` — complete, but needs a human to confirm |
| false | true | — | `DEFER` (or `REJECT` if zero fields mapped / no identity) |
| false | false | `block` | `REJECT` |
| false | false | `correct` / `flag` | `DEFER` |

`accuracy_severity = block` always wins — completeness never excuses
content that confidently contradicts itself. See `ingest-schemas` skill
for the full completeness/accuracy rule, the core/supplementary field
split per type, and the failure-mode-to-severity mapping.

## Worked examples (translated to the new two-dimension shape)

```
-- 8VC Defense Tech Fund
output.gate_verdict:
  input_source_name=security_master, anchor_type=entity, input_id=<fund_id>, input_name="8VC Defense Tech Fund", input_type=fund_vehicle,
  completeness_passed=false,
  completeness_core_mapped=["vintage_year"],
  completeness_missing=["overview_text","target_fund_size","fund_size", ...],
  completeness_reason="2 out of 12 expected fields mapped (17%) — vintage_year (core), fund_family_label. No overview_text/fund_size mapped.",
  accuracy_passed=true, accuracy_failure_mode=NULL, accuracy_severity=NULL, accuracy_reason=NULL,
  verdict=DEFER,
  reason="Completeness: 2/12 fields mapped (17%), only one core field. Accuracy: passed. DEFER — status=Unknown, pre-diligence stage, too thin to load yet."

-- Cambium
output.gate_verdict:
  input_source_name=security_master, anchor_type=entity, input_id=<fund_id>, input_name="Cambium", input_type=fund_vehicle,
  completeness_passed=false,
  completeness_core_mapped=[],
  completeness_missing=["overview_text","vintage_year","target_fund_size", ...],
  completeness_reason="0 out of 10 expected fields mapped -- no core field, nothing to build an identity from.",
  accuracy_passed=true, accuracy_failure_mode=NULL, accuracy_severity=NULL, accuracy_reason=NULL,
  verdict=REJECT,
  reason="Completeness: 0/10 fields mapped, zero fields at all (core or supplementary) -- the hard-constraint case per the completeness rule, nothing to build from. Accuracy: passed -- status=Closed with zero security rows isn't treated as a content contradiction (lifecycle status is informational like any other field, not a special accuracy trigger; see failure_modes.md's note on removing incomplete_for_lifecycle_stage). REJECT -- driven entirely by completeness's own zero-fields rule, not by the status field."

-- Hypothetical: a fully-filled fund whose name and strategy disagree
output.gate_verdict:
  input_source_name=security_master, anchor_type=entity, input_id=<fund_id>, input_name="Meridian Credit Opportunities Fund III", input_type=fund_vehicle,
  completeness_passed=true,
  completeness_core_mapped=["overview_text","vintage_year","fund_size"],
  completeness_missing=["hard_cap"],
  completeness_reason="11 out of 12 expected fields mapped (92%), all core fields present.",
  accuracy_passed=false, accuracy_failure_mode="name_strategy_mismatch", accuracy_severity="block",
  accuracy_reason="Name contains 'Credit' but mapped strategy attribute = 'Private Equity'.",
  verdict=REJECT,
  reason="Completeness: 11/12 fields mapped (92%), fully substantive. Accuracy: FAILED (block) — name says Credit, strategy says Private Equity. REJECT — complete is not enough when the record contradicts itself."
```

(`name_strategy_mismatch` above is illustrative — not yet a catalogued
failure mode; a real instance would need to be confirmed and added to
`knowledge/failure_modes.md` before being treated as trusted.)

## What this doesn't cover

There is no separate correction-proposal table anymore. Field-level value
corrections (e.g. the `MANAGEMENT_FEE` rollup-vs-detail mismatch) are the
`accuracy_severity = 'correct'` case above — the proposed fix lives in
`accuracy_proposed_value` on the same `gate_verdict` row, not in a
separate table. `ingest_correction_schema.md` no longer exists.

## `gate_relationship` — relationships are a second, dedicated table

**Why not just another `gate_verdict` row.** A relationship
(`ENTITY_RELATIONSHIP`, e.g. `manages` from manager to fund) is a
structurally different kind of fact from an entity/instrument's own QC
state — it has **two** sides, not one, and its payload isn't the stable
`EntityCreateInputRecord`/`InstrumentCreateInputRecord` shape every other
row has. An earlier version of this design tried to fit a relationship
into `gate_verdict` via a synthetic composite `input_id` and a payload
shape that changed depending on state (`DEFER` vs `LOAD`) — confirmed
confusing on review, and exactly the kind of accidental complexity the
v1→v2 three-table collapse already killed once. This is a genuinely
different concept (an edge vs. a node), so a second, equally minimal
table is the right fit, not a reopening of the "one table" decision
above.

**The real constraint this table exists to handle**: `target_entity_id`
on `EntityRelationshipCreate` must be a real, already-resolved Atlas
UUID (see `atlas-ontology`) — never a silver_id. A `manages` relationship
can't be submitted until **both** the manager and the fund already exist
in Atlas. For a brand-new source pull, neither side may exist yet when
the fund itself is otherwise ready to `LOAD` on its own merits — that's
not a reason to hold the fund back (see "A fund/instrument's own verdict
never depends on its parent's verdict" below); it's a reason to track the
relationship separately until both sides resolve.

**Required output of every run, not optional.** Confirmed real gap: a
full-source Security Master run wrote 17,770 `gate_verdict` rows and
zero `gate_relationship` rows -- Task 4/5 are not complete until every
parent/child pair among the records just scored has a row here, even if
every one of them is `DEFER`. This table is **not** a new lookup to
build from scratch -- `parent_silver_id`/`child_silver_id` are exactly
`parent_input_id`/`input_id` read straight off the **child**'s own
`gate_verdict` row (see "Hierarchy: `parent_input_id`" above): for every
`gate_verdict` row with `parent_input_id IS NOT NULL`, emit one
`gate_relationship` row with `parent_silver_id = parent_input_id`,
`child_silver_id = input_id`.

```sql
CREATE TABLE output.gate_relationship (
    input_source_name   VARCHAR,   -- 'security_master'
    relationship_type   VARCHAR,   -- RelationshipType enum, e.g. 'manages'
    parent_silver_id     VARCHAR,   -- the source's own id for the parent-side record (e.g. manager.id)
    child_silver_id       VARCHAR,   -- the source's own id for the child-side record (e.g. fund.id)
    org_id                 VARCHAR,
    group_key                VARCHAR,
    source_type              VARCHAR,

    verdict                   VARCHAR,  -- 'LOAD' / 'DEFER' / 'REJECT' -- decided fresh each time this row is computed
    reason                     VARCHAR,  -- e.g. "Checked live against Atlas as of 2026-10-01: parent not yet resolved"

    payload                    JSON,     -- real EntityCreateInputRecord fragment; NULL until verdict='LOAD'

    recorded_at                 TIMESTAMP,
    recorded_by                   VARCHAR
)
```

**No cached `entity_id` columns — the pipe is one-directional.** This
agent's pipe only ever reads MotherDuck and writes Atlas; nothing writes a
resolved `entity_id` back into MotherDuck afterward. So "is the parent
resolved yet" is never a column to wait on — it's answered by a **live,
read-only check against Atlas** (`connect.sh .env.atlas.prod`) performed
fresh **at the moment this row is computed**, same append-only discipline
as `gate_verdict`: a re-score is a new row with a new `recorded_at`, never
an `UPDATE`. "Current state" is the same latest-per-key query:

```sql
SELECT * FROM output.gate_relationship
QUALIFY row_number() OVER (PARTITION BY input_source_name, relationship_type, parent_silver_id, child_silver_id ORDER BY recorded_at DESC) = 1
```

**`payload` is only ever the real, submission-ready shape — never a
placeholder.** While `DEFER`, `payload` is `NULL` (nothing fake to look
at; the two silver_ids are already in the row's own identity columns).
Once both sides resolve, a new row is appended with `verdict='LOAD'` and a
real payload, attached to the **parent's** `silver_id` (relationships
live on the entity being resubmitted) with the child's actual resolved
`entity_id` baked directly into the JSON, looked up live at that moment:

```json
{
  "silver_id": "<parent_silver_id>",
  "relationships": [
    { "relationship_type": "manages", "target_entity_id": "<child's real resolved entity_id, looked up live>", "target_entity_role": "child" }
  ]
}
```

## A fund/instrument's own verdict never depends on its parent's verdict

Confirmed wrong in a real run: Zero Prime Ventures Fund III scored `LOAD`
on its own merits while its manager, Zero Prime, sat at `DEFER` — and the
first instinct was to cap the fund at `DEFER` too, "because you can't
create a fund without its manager." That's the wrong fix, for the same
reason a single disputed field shouldn't sink a whole record (see the
Accuracy rule above): the thing that can't be built yet is narrowly the
**relationship**, not the fund's own attributes, strategies, or
analytics, which are independently correct and independently loadable.
Capping the fund's own verdict would hold back nine valid facts to
accommodate one pending edge.

The correct behavior: the fund's own `gate_verdict` row is scored and
loaded exactly as if the parent didn't matter, because for the fund's own
facts, it doesn't. The pending `manages` edge gets its own row in
`gate_relationship`, `DEFER`'d until the manager resolves, independent of
whatever the fund's own verdict says.

**The complementary direction: a rich child can pull a thin parent's own
verdict up, not just stay unaffected by it.** The rule above stops a thin
*parent* from holding back a *rich child*'s own verdict. It does not mean
the parent's own completeness check is computed in total isolation from
its children forever — if the parent's own fields never earn it a `LOAD`,
it never gets an `entity_id` in Atlas, which means the pending `manages`
row in `gate_relationship` above can never resolve either, no matter how
many of its children are sitting at `LOAD` waiting for it. Confirmed real
case: Audax Private Equity's manager row has zero core fields of its own,
while 7+ of its funds are rich, real, independently-loadable PE funds (4
already carrying a resolved `fund.atlas_entity_id` from a prior load) —
under the old rule the manager sat at `DEFER` forever, permanently
blocking every one of those funds' `manages` relationships from ever
resolving. The completeness rule's **child-corroboration** clause (see
`ingest-schemas` skill) fixes this: a parent's own `completeness_passed`
can now pass on the strength of a genuinely rich, independently-loadable
child, same spirit as letting strategies/relationships compensate for a
low ratio, just sourced from below instead of from the same row. The two
rules together mean verdicts flow in both directions along the hierarchy
as corroborating evidence, while accuracy problems never do (a thin
parent doesn't sink a rich child; a junk child doesn't sink a decent
parent either — each row's own accuracy stays its own).

## Reading these tables for a batch submission

Your pipe's job is: filter to latest + `LOAD`, group by the batch key
(`source_type`/`org_id`/`group_key` — the inputs `EntityCreateRequest`/
`InstrumentCreateRequest` need), collect `payload`s into a list, call the
endpoint once per group.

```sql
-- Ready-to-load entity batches
WITH latest AS (
  SELECT * FROM output.gate_verdict
  QUALIFY row_number() OVER (PARTITION BY input_source_name, input_id ORDER BY recorded_at DESC) = 1
)
SELECT source_type, org_id, group_key, list(payload) AS records
FROM latest
WHERE verdict = 'LOAD' AND anchor_type = 'entity'
GROUP BY source_type, org_id, group_key;
```

Same query with `anchor_type = 'instrument'` → `create_instruments`. Same
pattern against `gate_relationship` (`WHERE verdict = 'LOAD'`, same latest
filter) → another `create_entities` batch, just carrying relationship-only
records.

**Open question, not yet decided**: should `source_type`/`org_id`/
`group_key` also be duplicated *inside* `payload` itself, so a single row
is fully self-contained and a pipe reading row-by-row (e.g. in Python,
without the SQL-side `GROUP BY`) doesn't need a join? Tradeoff is
duplication vs. convenience — undecided, flag here until settled.

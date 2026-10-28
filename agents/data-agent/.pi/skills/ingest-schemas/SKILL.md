---
name: ingest-schemas
description: >
  The gate_verdict table schema — the single output table for the data agent.
  One row per entity or instrument, per source org, scored on two independent
  dimensions — completeness (enough fields filled) and accuracy (content
  doesn't contradict itself) — plus the final verdict, reasoning, the
  Atlas ingestion-source inputs (source_type/as_of/org_id/group_key), and
  the full Atlas SDK payload. Replaces the old four-table ingest_gate +
  ingest_correction design.
---

# Gate Verdict Schema

Why this is one table, not a snapshot/staging/state split plus a separate
corrections table — see `knowledge/ingest_gate_schema.md`'s revision history
(`v1 → v2`, `v2 → v3`) for the full rationale, tested against real data.

## `gate_verdict` — the only output table (`output.gate_verdict`)

Only `payload` is JSON. Every other column is a flat, typed value —
booleans, strings, or native lists (`VARCHAR[]`) — so the table stays
directly queryable/filterable without unpacking blobs. Lives at
`output.gate_verdict` in MotherDuck — one `output` schema for every
source's verdicts, since each row already carries its own
`input_source_name` (e.g. `'security_master'`) and `org_id`. Raw source
tables live under a schema named for the source instead
(`security_master.manager`, not `raw_manager`) — see `tooling-pipeline`.

```sql
CREATE TABLE output.gate_verdict (
    -- identity: which source record this row is about
    input_source_name          VARCHAR,    -- the source this record came from, e.g. 'security_master' -- matches the raw table's schema name
    anchor_type                VARCHAR,    -- 'entity' or 'instrument'
    input_id                   VARCHAR,    -- source ID (SM manager_id, fund_id, security_id) -- the record's OWN id, not a canonical/shared one, see "Multi-tenant sources" below
    parent_input_id             VARCHAR,    -- the PARENT record's own input_id, one level up the source hierarchy (manager's input_id for a fund, fund's input_id for an instrument); NULL for a record with no parent (e.g. a manager). `input_id` is implicitly "this record's own id as a child" -- this column is the other half of that relationship, stored directly on the row so the hierarchy is readable without rejoining raw source tables. See "Hierarchy: parent_input_id" below.
    input_name                 VARCHAR,    -- human-readable name
    input_type                 VARCHAR,    -- 'management_company', 'fund_vehicle', 'lp_interest'

    -- ingestion source: the inputs Atlas's IngestionSourceCreate needs (source_external_key excluded -- the downstream pipe fills it in)
    source_type                VARCHAR,    -- constant 'manual' for now (IngestionSourceType enum)
    as_of                      DATE,       -- the source record's own created_at (SM has no true fact-date)
    org_id                     VARCHAR,    -- the source record's own org_id, per-record -- SM is multi-tenant, see below
    group_key                  VARCHAR,    -- constant 'data-agent'

    -- completeness check: are enough fields filled in?
    completeness_passed        BOOLEAN,    -- a core field is mapped AND the ratio clears the bar
    completeness_core_mapped   VARCHAR[],  -- which core fields mapped
    completeness_missing       VARCHAR[],  -- expected fields (core or supplementary) not mapped
    completeness_reason        VARCHAR,    -- "9 out of 12 expected fields mapped (75%), core fields present: ..."

    -- accuracy check: does the content contradict itself?
    accuracy_passed            BOOLEAN,    -- true if no accuracy issue found
    accuracy_failure_mode      VARCHAR,    -- catalog name from knowledge/failure_modes.md; NULL if passed or uncatalogued
    accuracy_severity          VARCHAR,    -- 'block' | 'correct' | 'flag'; NULL if passed
    accuracy_reason            VARCHAR,    -- what's wrong, e.g. "name contains 'Credit', strategy=Private Equity"
    accuracy_proposed_value    VARCHAR,    -- proposed fix; only set when severity = 'correct'

    verdict                     VARCHAR,    -- 'LOAD' / 'DEFER' / 'REJECT' -- derived, see rule below

    reason                      VARCHAR,    -- plain-English summary combining both dimensions

    payload                     JSON,       -- full Atlas SDK payload (EntityCreateInputRecord or InstrumentCreateInputRecord)

    -- provenance: when this row was written, and by what
    recorded_at                  TIMESTAMP,  -- when the agent wrote this row (not the source's own fact-date -- that's as_of)
    recorded_by                  VARCHAR     -- what wrote it, e.g. an agent session/run id, or a human reviewer's identifier for a manually-edited row
)
```

## Hierarchy: `parent_input_id`

Every `gate_verdict` row carries `parent_input_id` -- the parent
record's own `input_id`, one level up whatever hierarchy this source's
Task 2 mapping produced (e.g. a manager-level entity for a fund-level
entity, a fund-level entity for an instrument) -- `NULL` for a row at the
top of that hierarchy. `input_id` was already implicitly "this record's
own id, as a child of `parent_input_id`" -- this column makes the other
half of that relationship explicit and queryable directly on the row,
with zero rejoining of raw source tables required. **Every row populates
this column, including `NULL` for a top-of-hierarchy record** -- an
unset value is indistinguishable from "no parent" and defeats the
point; populate it in the same Task 4 pass as every other column. The
specific `input_type` values involved (`management_company`,
`fund_vehicle`, `lp_interest`, ...) are Atlas's own fixed `EntityType`/
`InstrumentType` enum vocabulary (see `atlas-ontology` skill) — universal
across every source, not something Security Master invented — but
**which of those types sits above which** (i.e. the actual shape of the
hierarchy: does this source even have three levels, could an `spv` or
`co_investment` sit somewhere unexpected) is a per-source fact, decided
by that source's own Task 2 mapping, not something to assume carries
over from a prior source's worked example.

This is in addition to, not instead of, `gate_relationship` (below) --
`parent_input_id`/`input_id` on a child's row are exactly
`parent_silver_id`/`child_silver_id` on that relationship's row, so
`gate_relationship` can be built directly from `gate_verdict` once it's
written, no extra lookup needed. See `knowledge/ingest_gate_schema.md`'s
matching "Hierarchy" section for the confirmed incident this column was
added to fix (a real run with zero cross-level linkage) and the worked
Security Master example -- that's where the source-specific substance
belongs, not here.

## Incremental scoring: how far rescoring reaches

When an incremental run (vs. inception -- see `tooling-pipeline` skill) rescores
a changed record, two mechanisms in the failure-mode catalog reach
outside that record's own row: child-corroboration (reaches one hop up,
to `parent_input_id`) and `possible_misattributed_manager` (reaches
siblings sharing the same `parent_input_id`). A **new insert** only
rechecks its parent, and only if the parent already has prior history; an
**updated existing record** rechecks both parent and siblings. The
changed record itself always gets a fresh `INSERT`; a parent/sibling
pulled in only because of this rule is diff-aware -- only written if its
recomputed verdict actually differs. See
`knowledge/ingest_gate_schema.md`'s matching section for the full table
and the reasoning for why it's bounded to exactly these two mechanisms,
not a wider dependency search.

## Append-only: never `UPDATE`, always `INSERT` a new row

`gate_verdict` is append-only. A re-score of a record that already has a
row -- a rule changed, a correction landed, the source re-pulled -- never
mutates the existing row. It inserts a **new** row for the same
`input_id`, with its own fresh `recorded_at`/`recorded_by`. The old row
stays exactly as it was written. This is what `recorded_at`/`recorded_by`
are *for* -- a column that only ever holds one value (because every write
overwrites it) isn't provenance, it's just a timestamp. Confirmed needed
in practice: a real session `UPDATE`d a row in place to fix a wrong
verdict and silently destroyed the fact that the wrong verdict had ever
been written, or why it changed -- exactly the traceability a human
reviewing this table needs most.

`recorded_by` should say *why* a new row exists when it's a re-score
rather than a first pass (e.g. `'data-agent-session-<id>: rescore after
incomplete_for_lifecycle_stage removed from catalog'`), not just which
session wrote it.

**"Which row is current" is a query, not a column.** The identity key is
`(input_source_name, input_id)` -- `input_id` is the source's own primary
key, which already determines everything else about the record, including
its `org_id` (never changes across re-scores -- just a column on the row,
not a separate dimension to key on). No new column, no persisted view:

```sql
SELECT * FROM output.gate_verdict
QUALIFY row_number() OVER (PARTITION BY input_source_name, input_id ORDER BY recorded_at DESC) = 1
```

Two different `org_id`s are two different `input_id`s (two genuinely
different source rows) -- each gets its own independent append-only
history. Not a deduplication case; see `knowledge/mapping_guide.md`'s multi-tenant
correction for how to decide which org's *copy* to actually map, which is
a separate judgment call from this one.

## Multi-tenant sources: why `org_id` is per-record, not per-batch

Security Master is genuinely multi-tenant -- the same real-world manager can
exist as separate rows under different SM `org_id`s (confirmed: 66 distinct
`org_id` values just in `manager`, some explicitly linked via `universal_id`
+ `extraction_copy_manager_data_result='LINKED_MANAGER'` when one org's copy
was populated from another's). This maps directly onto Atlas's own
`INGESTION_SOURCE.org_id` ("organization that owns or uploaded this source"),
so `gate_verdict.org_id` is filled from **the source record's own `org_id`**,
not a constant for the whole run -- two orgs' copies of the same manager are
two separate `gate_verdict` rows, each carrying its own `org_id`.

**Keep this simple -- don't try to do Atlas's resolution work for it.**
`input_id` stays the record's own id (e.g. that org's `manager.id`), full
stop -- no canonical-identity substitution, no forcing two orgs' rows to
share an `input_id`. Atlas's own entity resolution (exact identifier ->
exact silver_id -> exact name -> fuzzy embedding/soundex/trigram -> LLM
tiebreaker) is what decides whether two submissions resolve to one entity
or two -- that's its job, not this table's. The **one** thing worth getting
right at mapping time: if a record has `universal_id` set (SM's own,
unverified "these are the same" assertion), use the **linked/canonical
record's name** for `EntityNameCreate`, not this org's own `name` field --
otherwise a cosmetic naming difference ("Zero Prime" vs. "Zero Prime
Ventures") can sabotage Atlas's own name-matching for no reason.

**`universal_id`/`extraction_copy_manager_data_result` are SM's own internal
copy-lineage bookkeeping -- not an Atlas-relevant fact, and not something
that should drive `accuracy_passed`/`verdict` on its own.** Confirmed real
case: Silver Lake's manager record had `extraction_copy_manager_data_result
= 'LINKED_MANAGER'` with a blank `universal_id`, while a second org's copy's
`universal_id` pointed back at it -- a real run flagged this inconsistency
and `DEFER`'d an otherwise 100%-complete, fully-sourced record over it. That
was wrong: this agent doesn't need to know who copied from whom, only which
copy is cleanest. When multiple org-copies of the same manager/fund exist,
compare them **on substance** (completeness, value agreement) and map
whichever copy is cleanest/most complete as the source of truth. Reserve
`accuracy_severity='flag'`/`DEFER` for when the copies **substantively
disagree in content** you can't adjudicate (e.g. one org's fund target size
differing from another's) -- not for disagreeing lineage metadata alone.
See `knowledge/failure_modes.md`'s "Known non-issues" section and `knowledge/mapping_guide.md`'s
matching correction.

## Two independent QC dimensions, not one blended score

Earlier versions of this schema blended "is there enough data" and "is the
data right" into a single verdict computed from field counts alone. That
can't express a real, common case: a record can be **completely filled in
and still be wrong** — e.g. a fund's name contains "Credit" but its
mapped `strategy` attribute says "Private Equity." Counting mapped fields
never catches that; only checking content against itself does. So the two
checks are independent, and both get a real row in the table:

- **Completeness** — does the mapped payload have enough substance,
  weighted by core vs. supplementary fields, expressed as a pass/fail plus
  a human-readable ratio (see "Completeness rule" below).
- **Accuracy** — does the source data or mapped payload contain an
  internal contradiction, checked against the catalogued failure modes in
  `knowledge/failure_modes.md` (see "Accuracy rule" below).

## Verdict logic: Accept / Quarantine / Reject

Still the standard three-tier data-quality gate pattern (Kimball's ETL
"quality screens", Great Expectations' pass/fail, dbt's pass/warn/error) —
colloquially "good, bad, ugly" — but now derived from **both** checks,
with accuracy able to override an otherwise-clean completeness result:

| `completeness_passed` | `accuracy_passed` | `accuracy_severity` | `verdict` |
|---|---|---|---|
| true | true | — | `LOAD` |
| true | false | `block` | `REJECT` — complete, but content is confidently wrong; don't load |
| true | false | `correct` / `flag` | `DEFER` — complete, but needs a human to confirm a fix or an anomaly |
| false | true | — | `DEFER` (or `REJECT` if zero fields mapped / no identity at all) |
| false | false | `block` | `REJECT` |
| false | false | `correct` / `flag` | `DEFER` |

`accuracy_severity = block` always wins — no amount of completeness
excuses content that confidently contradicts itself. Below that, a clean
accuracy check just lets completeness decide `LOAD` vs `DEFER`/`REJECT`
on its own.

### Completeness rule

1. **Fails** (`completeness_passed = false`) when either:
   - no **core** field is mapped — supplementary detail without a
     defining fact isn't useful on its own, or
   - completeness ratio (mapped / expected, per the per-type list below)
     is below **40%**, even if a core field is present.
2. **Passes** (`completeness_passed = true`) when:
   - at least one **core** field is mapped, AND
   - completeness ratio is **≥40%**, OR a core field plus strategies/
     relationships compensate for a lower ratio (strategies carry real
     signal — see `source-mapping` skill), OR
   - **child-corroboration**: regardless of the record's own core-field/
     ratio result (including zero core fields), it has at least one real
     child record one level down Atlas's hierarchy (manager → fund,
     fund → instrument) that **independently** scores
     `completeness_passed = true AND accuracy_passed = true` on its own
     row — i.e. would independently `LOAD` on its own merits. Set
     `completeness_reason` to name which child(ren) did the
     corroborating (e.g. `"0/10 fields mapped, no core field — passed via
     child-corroboration: 7 of 13 child funds (Audax Private Equity Fund
     I–VII) independently score LOAD"`), not just the bare ratio, so a
     human reviewing the row can tell this branch fired.

**Why child-corroboration exists**: a parent entity that never scores
`LOAD` never gets submitted to `create_entities`, which means it never
gets an Atlas `entity_id` — which means the `manages`
`gate_relationship` row between it and its own children can **never**
resolve, permanently, no matter how clean those children's own data is
(see `knowledge/ingest_gate_schema.md`'s `gate_relationship` section). A thin
manager row with several genuinely rich, independently-loadable funds
underneath it (confirmed real case: Audax Private Equity — manager row
itself has zero core fields, but 13 of its funds are well-described,
consistently named, real PE funds, 4 of which already carry a resolved
`fund.atlas_entity_id` from a prior load) is unambiguously a real,
load-bearing entity — the existence of rich children *is* identity
signal, every bit as real as a filled-in `description` field, even
though no completeness-ratio formula counts it that way. Blocking the
parent in this case doesn't protect data quality; it just orphans
otherwise-good child data's relationships indefinitely. This is the
direct complement of "a fund/instrument's own verdict never depends on
its parent's verdict" (`knowledge/ingest_gate_schema.md`) — that rule stops a thin
*parent* from holding back a rich *child*; this one stops a thin *parent*
from permanently blocking itself out of ever being created *for* that
rich child's sake.

**This is a corroboration signal, not a blank check** — it requires an
actual independently-loadable child, not just the presence of any child
row at all (a parent with one equally-thin, equally-unloadable child gets
no boost from this clause) and not a majority/ratio threshold across all
children (one genuinely good child is enough; a parent otherwise
surrounded by junk children isn't penalized for that junk here —
accuracy issues on the children are each children's own problem, scored
on their own rows).

Zero fields mapped at all (core or supplementary), or identity that can't
be constructed (no resolvable name/type), is the hard-constraint case that
forces `REJECT` outright regardless of the table above — there's nothing
to build from. Child-corroboration overrides this too: a parent with an
unresolvable identity can't be rescued this way (there's no name to
create `EntityCreateInputRecord.name` from), but a parent with a resolvable
name and literally nothing else still passes if a child corroborates it —
name + a real child is enough to build from.

Core-field lists are a first draft — human judgment can move a field
between core/supplementary as we learn what's actually load-bearing
downstream. Flag disagreement in `completeness_reason` rather than
silently changing the split mid-run.

### Accuracy rule

Run every catalogued predicate from `knowledge/failure_modes.md` against the raw
source and the mapped payload. Each catalog entry states its own
`severity`:

- **`block`** — confidently wrong, whole record shouldn't load as-is
  (e.g. `possible_misattributed_manager`).
- **`correct`** — confidently wrong, but with a proposed fix
  (e.g. `rollup_detail_mismatch` — propose the detail-column value).
  `accuracy_proposed_value` carries the fix; a human still confirms it
  before it's trusted (the agent never applies anything itself).
- **`flag`** — looks off but not confidently wrong or fixable
  (e.g. `mislabeled_grouping_construct` on a single instance).

**Never invent a new failure mode mid-run.** An anomaly that doesn't match
any catalogued predicate gets `accuracy_passed = false`,
`accuracy_failure_mode = NULL`, severity `flag`, and the anomaly described
in `accuracy_reason` — a human decides later whether it becomes a
catalogued rule.

**On multiple accuracy issues**: only the single worst issue (by
severity, `block` > `correct` > `flag`) gets the structured
`accuracy_*` columns — that's what decides `verdict`. Additional, lesser
issues on the same record get folded into the free-text `reason`, not
given their own columns. This means a query like
`WHERE accuracy_failure_mode = 'x'` only reliably finds records where `x`
was the *worst* issue found, not every record `x` fired on — accepted
tradeoff for staying a single table instead of a companion issues table.

### Reason column

Must be plain English a human can act on, and must say **which
dimension** drove the verdict — not just a field count. Examples:
- `"Completeness: 9/12 fields mapped (75%), core fields present. Accuracy: passed. LOAD."`
- `"Completeness: 0/10 fields mapped -- zero fields at all, nothing to build from (the hard-constraint case). Accuracy: passed -- a status field like manager_fundraising_status='Closed' is informational like any other field, not a special accuracy trigger on its own (see knowledge/failure_modes.md's note on why incomplete_for_lifecycle_stage was removed). REJECT -- driven by completeness's zero-fields rule, not by the status field."`
- `"Completeness: 1/12 fields mapped (8%) — fund_family_label only, no core field mapped. Accuracy: passed. DEFER — too thin to be useful even though nothing looks wrong."`
- `"Completeness: 9/12 fields mapped (75%). Accuracy: FAILED (correct) — top-level MANAGEMENT_FEE=0.2 contradicts MANAGEMENT_FEE_INVEST=0.02 and narrative description ('2% of committed capital'); proposed_value=0.02 (rollup_detail_mismatch). DEFER pending human confirmation of the correction."`

### Expected fields per type

**Status: provisional, known to be wrong in places, not yet rebuilt.**
This list was hand-guessed, not derived from Atlas's real schema -- and a
real session confirmed the guess was off in both directions: it invented
names that don't exist (`stepdown_rate`, `tier_2_rate` are not real
`ManagementFeeAttributeName`/`PerformanceFeeAttributeName` values), and it
omitted the real, correct home for fund-level target/track-record
performance entirely (those belong in `analytics[]`—`AnalyticsMetric.irr`/
`.tvpi`/`.moic`/`.dpi`/`.distribution_yield`—not as an entity attribute at
all, and not in this table's scope as currently scoped to `attributes`/`fees`).
The real fix, not yet done: rebuild this list from the actual
`opto_atlas_service` enums (`EntityAttributeName`, `ManagementFeeAttributeName`,
`PerformanceFeeAttributeName`, `InstrumentAttributeName`—see `atlas-ontology`
for how to introspect them), filtered to whatever subset the onboarding
pipe's mapping code actually targets for Security-Master-sourced records
(most of `EntityAttributeName`'s ~90 values are RIA/ADV-compliance fields
that don't apply to a typical SM-sourced manager at all). Until that
rebuild happens, treat every verdict this schema produces as provisional --
especially near the 40% threshold, where a record's real richness (e.g.
narrative-verified tier/catch-up facts with no attribute-name home yet) can
be invisible to a ratio computed against the wrong denominator.

Core fields (bolded) are the facts that define what the thing *is*;
supplementary fields add detail but don't stand alone.

**management_company**: **description**, **aum**, **year_founded**,
employee_count, headquarter_state, headquarter_country, reputation,
url_domain, logo, retail_distribution

**fund_vehicle**: **overview_text**, **vintage_year**, **fund_size**,
target_fund_size, gp_commitment_amount, hard_cap, fund_family_label,
product_structure, investment_period_years, fund_term_years,
gp_extension_years, extension_provisions

**lp_interest**: **management.investment_rate**, **performance.performance_rate**,
management.investment_basis, management.harvest_rate, management.harvest_basis,
performance.hurdle_rate, performance.hurdle_type, performance.waterfall_method,
eligible_investor_type, tax_status

## Relationships live in a separate table — `output.gate_relationship`

A relationship (e.g. `manages`, manager → fund) is a structurally
different kind of fact from an entity/instrument's own QC state — two
sides, not one, and `target_entity_id` on `EntityRelationshipCreate` must
already be a resolved Atlas UUID (never a silver_id, never a
placeholder). So it gets its own table, not a row shoehorned into
`gate_verdict`:

```sql
CREATE TABLE output.gate_relationship (
    input_source_name VARCHAR, relationship_type VARCHAR,
    parent_silver_id VARCHAR, child_silver_id VARCHAR,
    org_id VARCHAR, group_key VARCHAR, source_type VARCHAR,
    verdict VARCHAR, reason VARCHAR, payload JSON,
    recorded_at TIMESTAMP, recorded_by VARCHAR
)
```

**This table is a required output of every run that has any parent/child
pair in scope, not an optional extra.** Confirmed real gap: a full-source
run wrote 17,770 `gate_verdict` rows and zero `gate_relationship` rows —
Task 4/5 of a run are not done until every parent/child pair among the
records just scored has a row here, even if every one of them is
`DEFER`.

`parent_silver_id`/`child_silver_id` are not a new lookup — they're just
`parent_input_id`/`input_id` read straight off the **child**'s own
`gate_verdict` row (see "Hierarchy: `parent_input_id`" above). Build this
table directly from `gate_verdict` once it's written: for every row with
`parent_input_id IS NOT NULL`, emit one `gate_relationship` row with
`parent_silver_id = parent_input_id`, `child_silver_id = input_id`.

Same append-only discipline as `gate_verdict`, same latest-per-key query
(`PARTITION BY input_source_name, relationship_type, parent_silver_id,
child_silver_id`). `verdict`/`payload` are decided **fresh each time**,
via a live read-only check against Atlas (`connect.sh .env.atlas.prod`)
— never a cached `entity_id` column, since this pipe only ever reads
MotherDuck and writes Atlas, nothing writes back. `payload` is `NULL`
while `DEFER`; once both sides resolve, it's the real
`EntityCreateInputRecord` fragment (attached to the **parent's**
`silver_id`, carrying the child's real resolved `entity_id`).

**Critical rule: a fund/instrument's own verdict never depends on its
parent's.** Cap only the relationship at `DEFER` — not the whole child
record. See `knowledge/ingest_gate_schema.md`'s `gate_relationship` section for the
full design and the worked Zero Prime example of getting this wrong the
first time.

## Reading `gate_verdict`/`gate_relationship` for a batch submission

Filter to latest + `LOAD`, group by the batch key
(`source_type`/`org_id`/`group_key`), collect `payload`s into a list, call
the endpoint once per group:

```sql
WITH latest AS (
  SELECT * FROM output.gate_verdict
  QUALIFY row_number() OVER (PARTITION BY input_source_name, input_id ORDER BY recorded_at DESC) = 1
)
SELECT source_type, org_id, group_key, list(payload) AS records
FROM latest
WHERE verdict = 'LOAD' AND anchor_type = 'entity'
GROUP BY source_type, org_id, group_key;
```

Same query, `anchor_type = 'instrument'` → `create_instruments`. Same
pattern against `gate_relationship` → another `create_entities` batch.

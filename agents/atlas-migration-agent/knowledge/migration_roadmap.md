Status: Phase 3a — PR 176 (`input` table + backfill) merged and the backfill has finished in prod; the backfill code has been deleted (PR 184) and the write-path wiring PRs (180, 183, 185) are merged; **next up: build the rest of 3a (`anchor`, `input_resolution_attempt`, `input_resolution_candidate`, `input_anchor`, plus the `ingestion_source` -> `ingestion` rename); the design is locked and the design questions are closed (see the 3a "Locked design"); `ON DELETE` actions and the backfill are deferred; the `input_id` FK is deliberately last (see the 3a status block)**; Phase 1 functionally complete (see Phase 1 section's "Net" line) but the one lingering `resolution_correction` sign-off below is still genuinely open, not resolved by lapse of time

# Atlas Data Model Migration — Roadmap

Read this in full, alongside `backfill_pattern.md`, before touching any
migration or backfill code for this project. This file is the single
source of truth for **which phase we're in, what that phase changes,
what "verified" means for it, and which decisions are not this agent's
to make.** It replaces re-deriving the plan from scratch each
invocation.

**Current state vs. target state — two different sources, don't
conflate them:**

- **Current state** ("where are we actually at, right now, in
  `atlas-service`") is never read from prose docs. Use the skill agents/atlas-migration-agent/.pi/skills/atlas-ontology/SKILL.md
- **Target state** ("what we're migrating *to*") is the frozen snapshot under `target-schema/` (`README.md` + `schema-basic.sql` +
  `schema-basic.png`). Read `target-schema/README.md` and
  `target-schema/schema-basic.sql` before writing any migration —
  don't assume the shape from this roadmap's summaries alone.

**`target-schema/` is a copy, not a live link to the other repo.** If
someone edits the original files over there later, nothing here changes
automatically — this copy will just be out of date and nobody will be
told. That's fine; it's expected to be a point-in-time snapshot of the
original proposal.

**But `target-schema/` is kept up to date with every *confirmed* fix
found during this migration — see "The plan will change" section
above and `target-schema/CHANGELOG.md`.** Several fixes already went
through that confirmation step and are already applied directly in
`target-schema/schema-basic.sql` (not just noted here in prose):
`anchor.anchor_id` uses `uuidv7()`, `entity_name` no longer carries
embedding columns, and the old `ingestion_source.chain_group_key`
(a `GENERATED` hash) has been replaced entirely by a real dimension
table, `source_identity` (`source_id` surrogate PK, keyed by
`source_type`/`owner_id`), with `ingestion_source` itself renamed
`ingestion` and trimmed to per-run facts only; rerun-safety is now
`UNIQUE (source_id, pipe_run_id)` on `ingestion`. Check
`target-schema/CHANGELOG.md` for the full list and the reasoning behind
each, including the ones still open and *not yet* applied (don't assume
the "Resolved/Pending" lists per phase below are the only place these
live — `CHANGELOG.md` is the actual record of what changed in the file
itself).

## How to use this file

1. **Check the `Status:` line at the top before doing anything.** It
   names the current phase. Don't start work on a later phase until the
   current one's exit criterion (below) has actually passed on the
   replica — not "looks right," the literal query result.
2. Each phase below has: what it changes, its entry precondition, its
   QC check(s) (run against the replica, never prod), its exit
   criterion, and — where relevant — open decisions flagged for a human.
3. **When a phase's QC check fails, or an open decision is listed and
   not yet resolved, stop and report. Don't improvise a fix** — same
   rule as `AGENTS.md` already states for ambiguous schema decisions.
4. **When a phase's exit criterion passes on the replica**, update the
   `Status:` line at the top of this file as part of your output (it's
   tracked in git, so the next invocation — interactive or not — picks
   up where this one left off) and report what was verified. Advancing
   `Status:` is this agent's signal that a phase is ready for a human to
   actually run against prod — it is not itself running anything against
   prod (same boundary as everywhere else in this agent).
5. If a phase turns out to need a backfill (checked via real row counts
   on the replica, not guessed), follow `backfill_pattern.md` for that
   sub-piece — this roadmap sequences *which* migrations happen in what
   order; `backfill_pattern.md` is still the authority on *how* any one
   of them splits into schema-only + backfill endpoint if it has to.

## The plan will change — that's expected, not a failure

**Every phase starts with its own deep-dive**, not just "implement what
the last phase assumed." That's deliberate: this roadmap and
`target-schema/` were written from one point-in-time review, and each
phase's actual implementation work involves going back through the real
current `atlas-service` code and the relevant slice of `target-schema/`
in depth again, with fresh eyes, against whatever has actually changed
since. **Expect to find things that don't match what's written here.**
That is the deep-dive working as intended, not a sign something went
wrong earlier.

**The divergence protocol — follow this exactly, every time a deep-dive
turns up something that disagrees with this roadmap or with
`target-schema/`:**

1. **Stop before implementing it.** Do not silently build the new
   understanding and do not silently keep the old one either — both are
   guessing.
2. **Surface the divergence explicitly to a human**: what this roadmap
   or `target-schema/` currently says, what the deep-dive actually
   found, and why they disagree. Be concrete — quote the actual lines,
   don't paraphrase.
3. **Wait for an explicit yes or no.** No response, or an ambiguous
   response, is not a yes — treat it the same as the existing
   "ambiguous schema decision" rule in `AGENTS.md`: say so and stop.
4. **If the answer is yes**: update `target-schema/schema-basic.sql`
   (and `target-schema/README.md` if the prose there is affected) to
   match the confirmed decision, and add a row to
   `target-schema/CHANGELOG.md` recording the date, the change, why, and
   that it was confirmed. Then update this roadmap's own phase
   description if the confirmed change affects what a later phase needs
   to do. Only then proceed with implementation.
5. **If the answer is no**: leave `target-schema/` untouched, note the
   rejected proposal and the reason in this roadmap under that phase (so
   it isn't re-litigated from scratch next time), and proceed with the
   original plan.

The point of step 4 is that `target-schema/` should always reflect the
*current, confirmed* target — not the original one-time copy forever,
and not a second, competing "corrections" list living only in this
roadmap's prose that someone has to cross-reference by hand every time.
If this roadmap and `target-schema/` ever disagree and there's no
changelog entry explaining why, treat that as a bug in the process
itself — stop and report it rather than picking one side.

## Phase overview

| Phase | What changes | Risk | Depends on |
|---|---|---|---|
| 0 | Reconciliation only — no schema change | None (read-only against replica) | — |
| 1 | `source_identity` / `source_id` / `access_group` / `ownership_model` on fact tables (`ingestion_source` -> `ingestion` rename postponed, see Phase 1 section) | Low, self-contained | Phase 0 clean |
| 2 | `input_grant` table + read-path wiring | Low (additive), Medium once wired into reads | Phase 1 shipped |
| 3a | `anchor` / `input` / `input_resolution_attempt` / `input_resolution_candidate` / `input_anchor` — new tables, backfilled, dual-written; also where the postponed `ingestion_source` -> `ingestion` rename (table + every fact table's `ingestion_source_id` FK column -> `ingestion_id`) gets bundled in, since this sub-phase already touches every fact table's lineage columns | High (data reconstruction) | Phase 1 shipped |
| 3b | Cut over **entity** reads to new tables | High | 3a verified clean for a real bake-in window |
| 3c | Cut over **instrument** reads | High | 3b stable in prod |
| 3d | Cut over **position** reads | High | 3c stable in prod |
| 3e | Cut over corrections (`correction_service.py`, `resolution_engine.py`), per anchor type, same order; then drop legacy tables | Highest | 3b–3d each stable, full `correction_use_cases.md` parity suite passing |

---

## Phase 0 — Reconciliation (no schema change)

**Goal:** prove, against real replicated data, that the new derived
columns would agree with what's in production today — before writing
a single line of DDL.

**What to do:**
- Against the replica, compute what `source_id` *would* be for every
  existing `ingestion_source` row — i.e. the distinct `(source_type,
  org_id)` pairs that would each become one `source_identity` row — and
  diff the resulting grouping against the current free-text
  `ingestion_source_group_key` values actually in use on fact tables.
  (Earlier drafts of this roadmap framed this as reconciling a
  deterministic hash, `md5(source_type || ':' || org_id)`; the hash
  itself has since been dropped in favor of a real `source_identity`
  dimension table — see the Phase 1 deep-dive row in
  `target-schema/CHANGELOG.md` — but the grouping this step verifies is
  unchanged: same two inputs, same question of "do these two rows
  belong to the same writer.")
- Compute what `access_group` *would* be via the SQL port of
  `get_source_entitlement_group` (see `app/utils/entitlement_utils.py`
  in `atlas-service`) and diff against the existing
  `entitlement_group` column on every historical `ingestion_source` row.
- Check for existing constraint violations the *new* mechanism would
  introduce: are there currently two "open" (`valid_to IS NULL`) rows
  for the same `(entity_id, name_type)` (and identifier/other fact
  tables) that would collide once keyed by the new `source_id`
  instead of the old free-text key? This is the check that tells you
  whether Phase 1's unique index can even be added without first
  triaging bad data.

**Exit criterion:** 100% agreement on both diffs, and zero would-be
collisions. Any mismatch is a stop-and-report, not something to patch
around — a mismatch here means either the SQL port of the mapping logic
is wrong, or there's historical data written under different rules than
assumed, and a human needs to see that before Phase 1 writes any DDL.

**Verified clean against the live `atlas_prod` replica (2026-11-10):**
- `access_group` ported from `get_source_entitlement_group` vs. live
  `entitlement_group` on every `ingestion_source` row: 0 mismatches out
  of 2,331 rows.
- `ownership_model`/`owner_id` CHECK (`PRIVATE` iff `owner_id IS NOT
  NULL`), using the corrected mapping from the Phase 0 QC follow-up row
  in `target-schema/CHANGELOG.md` (ARCH moved to `PRIVATE`): 0
  violations across all 2,331 rows.
- Would-be `(entity_id/instrument_id, name_type/identifier_type,
  source_type, org_id)` open-slot collisions on `entity_name`,
  `entity_identifier`, `instrument_name`, `instrument_identifier`: 1
  found initially (a duplicate `Figment Inc.` `BRAND_NAME` row under
  `ARCH`, two open rows for the same slot), fixed directly in prod,
  re-verified clean: 0 collisions remaining across all four tables.

**Nothing in this phase touches schema.** It's pure verification.

---

## Phase 1 — `source_identity` / `ingestion` / `source_id` / `access_group` / `ownership_model`

**What changes — superseded design, confirmed during the Phase 1 deep-dive (see
`target-schema/CHANGELOG.md`, "Phase 1 deep-dive" and "source_identity alignment" rows, for
the full before/after and reasoning):**
- The old plan computed `chain_group_key` as a `GENERATED` hash
  (`md5(source_type || ':' || org_id)`) directly on `ingestion_source`.
  That's gone. Instead:
  - New table **`source_identity`**: one row per distinct
    `(source_type, owner_id)` writer slot, with a real random
    surrogate `source_id` PK (not derived from `source_type`/`owner_id`
    by any formula), plus `ownership_model` (three values: `PUBLIC`,
    `PRIVATE`, `LICENSED`) and `access_group` as plain `NOT NULL`
    columns — not `GENERATED`, not computed by a SQL function — set
    once in Python at the application service layer when the row is
    first created (`atlas-service`'s `OWNERSHIP_MODEL` dict and
    `get_source_entitlement_group`, respectively), both moved here
    from `ingestion_source` since there's nothing left on the renamed
    `ingestion` table to derive them from.
  - **`ingestion_source` is renamed `ingestion`**, trimmed to per-run
    facts only: `source_id` (FK into `source_identity`),
    `ingestion_subtype` (renamed from `source_subtype`, same free-text
    review/diff-metadata role, still no structural part in uniqueness),
    `pipe_type`, `pipe_run_id`. **Postponed, not done in Phase 1:** this
    table rename, and the wider question of whether every fact table's
    `ingestion_source_id` FK column also gets renamed to `ingestion_id`
    to match `input.ingestion_id` (40+ model files would be touched by
    the wide version — every current fact table in the schema, not just
    `entity_name`/`instrument_name`), is explicitly deferred to be
    bundled with Phase 3's `ingestion`/`input` split, not done as its
    own Phase 1 PR. Human, explicit: "actually let's postpone this
    change. We will bundle it with the logic that split the ingestion
    table." Don't start this rename on its own before Phase 3 begins.
  - `owner_id` is the renamed `org_id` on this new table only —
    `input_grant.org_id` (a list of *grantee* orgs, unrelated concept)
    is untouched.
- Each fact table (`entity_name`, `entity_identifier`, and their
  instrument/position equivalents once those exist) gains a
  `source_id` column — a real `FOREIGN KEY REFERENCES source_identity
  (source_id)`, not a bare `UUID` — populated by a backfill job joining
  through `input.ingestion_id -> ingestion.source_id`, then maintained
  going forward by the application service layer: resolved once per
  write request in Python (`IngestionSourceService.get_source_id_by_ingestion_source_id`,
  same convention as `get_source_entitlement_group` in
  `app/utils/entitlement_utils.py`) and threaded down as a plain
  parameter into the relevant `*_ingest_service.py`/`*_service.py`
  write paths — **not** a DB trigger. `target-schema/schema-basic.sql`
  originally had a `BEFORE INSERT OR UPDATE OF input_id` trigger
  (`set_source_id`) doing this same one-hop copy at the DB layer; that
  trigger has been removed from the target schema (confirmed, see
  `target-schema/CHANGELOG.md`'s "Phase 1 implementation deep-dive"
  row) — **no DB triggers anywhere in this migration, full stop**, not
  just no cascade triggers. This also applies to every other trigger
  `schema-basic.sql` still has for tables that don't exist yet
  (`input_set_derived_columns`, `check_input_anchor_reason`) — those
  need the same Python-at-service-layer redesign before Phase 2/3
  writes any migration for them; they are deliberately left as-is in
  the SQL file for now since rewriting a table that isn't being built
  yet isn't this phase's job, but don't copy their trigger-based shape
  forward when that phase starts.
- `source_identity` is deduped by a single `UNIQUE ... NULLS NOT
  DISTINCT` index on `(source_type, owner_id)`
  (`source_identity_source_type_owner_id_idx`) — not a plain `UNIQUE`
  constraint plus a second partial index for the `owner_id IS NULL`
  case; the actual shipped migration uses one index, confirmed no
  behavior difference, see `target-schema/CHANGELOG.md`'s
  "source_identity alignment" row.
- **Resolved — yes, each fact table should get a real partial
  `UNIQUE` index, `(entity_id, name_type, source_id) WHERE valid_to IS
  NULL` (and the equivalent per other fact table/slot), matching
  `target-schema/`'s original design. What was actually open wasn't
  whether to add it, but *when*: human, explicit — "should that not
  come after all the columns exist and the data migration is
  completed?" Yes. The index can't meaningfully protect anything while
  `source_id` is still nullable and not fully backfilled — every
  unbackfilled historical row has `source_id IS NULL`, and a plain
  unique index treats `NULL`s as distinct, so the index would only
  police *new* rows going forward while silently not covering
  historical data at all. Sequencing, per fact table (or per batch of
  fact tables sharing one migration):
  1. Schema-only migration: nullable `source_id` + FK (what's shipped
     so far for `entity_name`/`entity_identifier`/instrument
     equivalents).
  2. Manual or endpoint-driven backfill (per `backfill_pattern.md`'s
     sizing rule).
  3. Follow-up migration: `source_id` → `NOT NULL`.
  4. **Only then**, as part of that same follow-up or a later one: add
     the partial `UNIQUE` index — by this point every row has a real
     `source_id` to enforce against.
- **No cascade triggers, no triggers at all.** The old design needed two `AFTER UPDATE`
  triggers to retroactively push a corrected `org_id`'s derived values
  down three hops (`ingestion_source -> input -> fact tables`) whenever
  someone fixed a wrong `org_id` in place. `source_id` is a stable
  surrogate, never recomputed from mutable fields, so there is nothing
  to retroactively push — a wrong writer identity is fixed by
  superseding the old `input` row through the ordinary
  correction/resolution mechanism (Phase 3's `input_anchor`/correction
  path), same as every other wrong fact in this schema. Do not
  reintroduce an `AFTER UPDATE` cascade here, and do not reintroduce
  any other kind of DB trigger either (see above) — if a later
  deep-dive finds a case that seems to need one, that's a
  divergence-protocol stop, not something to build around this note.

**Backfill sizing:** two backfills now, not one — (1) populate
`source_identity` with the distinct `(source_type, owner_id)` pairs
implied by existing `ingestion_source` rows and backfill
`ingestion.source_id` to point at them, then (2) backfill each fact
table's `source_id` by joining through `input`/`ingestion`. Check real
row counts on the replica for both steps before deciding
inline-`UPDATE`-in-migration vs. the full backfill-endpoint pattern —
follow `backfill_pattern.md`'s decision rule exactly, don't assume
scale.

**Confirmed and applied — already reflected in `target-schema/schema-basic.sql`, see `target-schema/CHANGELOG.md`:**
- `pipe_run_id`'s rerun-safety uniqueness is `UNIQUE (source_id, pipe_run_id)` on `ingestion`, not
  `UNIQUE (source_type, pipe_run_id)` — the latter was missing `owner_id`
  and would have wrongly rejected two different orgs reusing the same
  deterministic `pipe_run_id` under one `source_type`. (Originally phrased as
  `UNIQUE (chain_group_key, pipe_run_id)` before the Phase 1 deep-dive — same
  reasoning, different column.)
- **Superseded during Phase 0 — `group_key` is not dropped, it's renamed
  and kept, just stripped of any structural role.** Earlier text here said
  `group_key` was "confirmed safe to drop" from `atlas-service`'s API
  request schemas, verified against every pipe in `data-factory` each
  defining exactly one static `group_key` constant per dataset with
  `org_id` doing the real tenant separation. That verification was correct
  as far as it went — no pipe needs `group_key` for *chaining* — but it
  missed that the same field is still needed for *review/diff* purposes
  (e.g. Form ADV's daily snapshot vs. monthly detailed filing, or a future
  second system feeding `system_migration` for the same org, both of which
  should still chain as one writer but need to stay distinguishable for
  review). Confirmed fix: what's now `ingestion` gains `ingestion_subtype`
  (`TEXT NOT NULL`, free text, one static value per pipe, renamed from
  `source_subtype` which was itself the renamed `group_key`) — deliberately
  excluded from `source_id`/uniqueness and not duplicated onto any fact
  table. The writer-grouping itself (`source_type` + `owner_id` only) needed
  no change from this. See the Phase 0 row in `target-schema/CHANGELOG.md`
  for the full reasoning.
- **Resolved during the Phase 1 deep-dive, then refined by the
  "source_identity alignment" confirmation — `ownership_model` is a
  plain, `NOT NULL` three-value column (`PUBLIC`/`PRIVATE`/`LICENSED`),
  not `GENERATED`.** It lives on `source_identity`, set once in Python
  at the application service layer when the row is first created
  (`atlas-service`'s `OWNERSHIP_MODEL` dict,
  `app/common_enums/ingestion_source_type.py`) — not an independently
  *re*-settable column after that, and not computed by a SQL function
  either. This still closes the gap the old open question used to
  flag: a mismatched `ownership_model`/`source_type` pair could
  otherwise produce a writer slot with no `owner_id` folded in,
  silently merging every org's private data under one `source_type`
  into one slot — enforced here by the `CHECK ((ownership_model =
  'PRIVATE') = (owner_id IS NOT NULL))` constraint, same as it always
  was, just off a real column, not a `GENERATED` one. See
  `target-schema/CHANGELOG.md`'s "source_identity alignment" row for
  why this is three values (`PUBLIC`/`PRIVATE`/`LICENSED`), not the two
  (`LICENSED`/`PRIVATE`) an earlier draft of this file had.

**Resolved — the `access_group` "pending confirmation" item below is
settled, not open:**
- `access_group` is also a plain, `NOT NULL` column on `source_identity`,
  not `GENERATED`, set once in Python via `get_source_entitlement_group`
  (`app/utils/entitlement_utils.py`) when the row is first created. That
  function's `case _: raise ValueError(...)` already answers the
  question below: an unhandled `source_type` is a hard Python exception
  at write time, not a silently-`NULL` column — there is no SQL `CASE`
  to add an `ELSE RAISE EXCEPTION` branch to, because there's no SQL
  function computing this value at all anymore.

**QC check before adding the unique index (run on replica):**
```sql
-- Must return 0 rows for every fact table before the index is added.
SELECT entity_id, name_type, source_id, count(*)
FROM entity_name
WHERE valid_to IS NULL
GROUP BY 1, 2, 3
HAVING count(*) > 1;
```

**QC check after backfill, before shipping (run on replica):**
```sql
-- Must return 0.
SELECT count(*) FROM source_identity WHERE access_group IS NULL;
SELECT count(*) FROM ingestion WHERE source_id IS NULL;
SELECT count(*) FROM entity_name WHERE source_id IS NULL;
-- (repeat the last for every fact table that got the column)
```

**Exit criterion:** both QC checks clean on the full replica, backfill
module (if needed) reports `is_done = true` with `remaining_rows = 0`
for every target table, legacy `ingestion_source_group_key` /
`entitlement_group` left in place and unused (don't drop them yet —
that's a later cleanup once Phase 1 has baked in production).

**Progress log (2026-11-11) — superseded by the end-of-session summary immediately below.
Kept for history; read the summary first.**

**End-of-session summary (2026-11-11, later same day) — here's where Phase 1 actually
stands, consolidated:**

**Merged and confirmed live on `atlas_prod`:**
- **#166** (`a0145b395569`) — `input_id` → `NOT NULL` on 20 fact tables, `source_id` →
  `NOT NULL` on `entity_attribute`/`entity_identifier`/`entity_name`.
  `resolution_correction.input_id` deliberately left nullable — documented in the
  migration itself: a correction with no `input_id` applies to the whole target (see
  `ingestion_source_service.get_resolutions`), not an oversight.
- **#168** (`787bd68a9b0d`) — the actual point of Phase 1: `UNIQUE (..., source_id)
  WHERE valid_to IS NULL` added to 9 tables (`entity_name`, `entity_identifier`,
  `instrument_name`, `instrument_identifier`, `entity_type`, `entity_strategy`,
  `entity_operational_phase`, `entity_relationship`, `instrument_type`), plus the
  write-path changes needed to keep the app consistent with it (supersession-key
  logic switched from `ingestion_source_group_key` to `source_id`, and a
  delete-before-update ordering bug fixed on every affected table to avoid a transient
  window with two open rows).
- **#170** (`33c5b71d139a`) — **a real production bug #168 introduced, caught and
  fixed same day.** Once #168 repointed `create_entity_strategies`/
  `create_entity_types`'s predecessor lookup to `source_id`, the *old*
  `group_key`-keyed indexes those write paths used to target became actively wrong
  wherever two different writers share one `group_key` (e.g. every diligence
  extraction uses the literal string `"diligence_extraction"`): `entity_strategy`
  threw a raw 500 on the second writer's insert, and `entity_type`'s `ON CONFLICT`
  arbiter being `group_key`-keyed silently discarded the second writer's claim
  entirely — no exception, no row, just a lost write. Fixed by dropping both stale
  `group_key`-keyed indexes (redundant with #168's `source_id` ones anyway) and adding
  a `source_id`-keyed arbiter index for `entity_type`'s `ON CONFLICT`. **Lesson for any
  future table doing this same swap: check every index the table's own write path
  targets, not just the ones this roadmap's audit was checking for collisions** — this
  bug wasn't a data problem, it was a write-path index that nobody re-pointed.

**Open, not yet merged:**
- **#171** (`79ff084e109f`) — the same `source_id` open-slot index for
  `instrument_coupon_attribute` and `instrument_fee_attribute`, held back from #168
  because both had real duplicate rows on prod. Found, fixed, and **re-verified across
  all four environments, not just prod**: `instrument_coupon_attribute` was already
  clean everywhere; `instrument_fee_attribute` had 79 collisions on prod (fixed), 107
  on dev (106 fixed mechanically + 1 genuine value disagreement — `Invested` vs.
  `Committed` on the same fee, resolved by hand: most-recent-write wins, confirmed
  with the user), 21 on demo (fixed, same-day ties handled via a `recorded_at`
  tiebreak in the ordering), 0 on stage (already clean, no action needed). All fixed
  via `scripts/fix_instrument_fee_attribute_duplicates.sql`-style chaining
  (idempotent, skips any group that doesn't unanimously agree on value rather than
  guessing). **All four environments now clean**; #171 is safe to merge/deploy
  whenever.

**Resolved, not a lingering risk — `analytics`/`valuation`/`operating_cash_flow`
dedup keys:** considered and explicitly rejected extending the `source_id`-keyed
open-slot pattern here. These three use a structurally different mechanism (`INSERT
... ON CONFLICT (..., group_key) DO UPDATE`, not an open/close temporal chain) where
`group_key`'s whole job is telling two sub-feeds from the same writer apart (e.g. a
daily snapshot pipe vs. a monthly detailed-filing pipe); swapping to `source_id` would
silently collapse those into one row, overwriting one sub-feed's value with another's
with no error. Confirmed this doesn't collide with `group_key`'s planned retirement
either: what's actually going away is the FK constraint tying
`ingestion_source_group_key` to `ingestion_source.group_key`, not the column/value
itself sitting on fact tables — so dedup keeps working exactly as today indefinitely.
`operating_cash_flow` has no write path implemented at all yet, so nothing to decide
there until it does. No action needed, and no follow-up to schedule.

**Side fix, unrelated to `source_id` — PR #173, "Time Series table need a boost" (not yet
merged):** a schema/read-path review of `valuation`/`analytics`/`operating_cash_flow`
(prompted by a human asking about these tables generally, not a Phase 1 task) turned up
and fixed three independent issues, none of which touch the `source_id`/dedup mechanism
above:
- `operating_cash_flow` was missing `input_id` (every other fact table has it per the
  Atlas column rules in `app/db_schema/README.md`) — added as `NOT NULL` directly, safe
  because the table has zero rows (confirmed on replica, consistent with "no write path
  yet" above).
- Added a `CHECK` on all three tables tying `scoped_to` to the one anchor column that must
  be populated (`CASE scoped_to WHEN 'ENTITY' THEN entity_id ... END IS NOT NULL`) — closes
  a real gap where nothing previously enforced that `scoped_to` agrees with which of
  `entity_id`/`instrument_id`/`position_id` is set, which the four partial dedup unique
  indexes rely on to pick the right row set.
- Dropped `valuation`/`analytics`' generic `(entity_id, scoped_to, as_of)` index after
  fixing `_entity_ids_filter`/`_instrument_ids_filter` in both stores to state
  `scoped_to = ...` explicitly per `OR` branch (previously implied, never written in the
  query) — confirmed via `EXPLAIN` on 20k seeded rows that this was necessary and
  sufficient: without the explicit predicate, Postgres silently falls back to a sequential
  scan instead of the partial dedup index, CHECK constraint notwithstanding (Postgres does
  not use table `CHECK` constraints to prove a partial index's `WHERE` clause is satisfied).
  This also means `instrument_id`/`position_id` never needed their own generic index either
  — the query fix covers all three anchor types, not just `entity_id`.

**Still genuinely open, unresolved, needs a human decision:**
- **`resolution_correction` has no `source_id` column at all.** Raised, then walked
  back as "probably out of scope" (it's an audit/log table, not a fact table readers
  see under entitlement rules) — but never got an explicit yes/no. Still sitting
  open. Low urgency, but shouldn't be silently dropped from tracking either.

**Net: once #171 merges and deploys, Phase 1's actual mechanism (column + backfill +
NOT NULL + real open-slot uniqueness) is complete and verified on every fact table
that needed it, across every environment.** The only thing stopping `Status:` at the
top of this file from advancing is `resolution_correction`'s open question above —
worth a final human call before marking Phase 1 done, not a blocker on its own merits.

---

## Phase 2 — `input_grant`

**What changes:**
- New table `input_grant` (versioned, full-snapshot `org_id[]` per
  `input_id`) — purely additive, no existing read path touches it yet
  when this lands.
- Separately, once the table exists: wire the read-time entitlement
  recipe into **entity reads first**, verified in staging with a known
  test org pair, then instrument, then position — one domain at a time,
  each with its own bake-in, per `AGENTS.md`'s "no human to ask mid-run,
  stop rather than guess" rule applied here specifically to the exact
  read recipe (see below).

**Open decision requiring explicit human sign-off before wiring reads:**
the exact entitlement read recipe for `CLIENT`-bucket rows is not yet
finalized. The working hypothesis discussed is:
```
access_group ∈ allowed_groups
AND (access_group != 'CLIENT'
     OR requesting_org = owning_org   -- via ingestion.source_id -> source_identity.owner_id
     OR requesting_org = ANY(latest input_grant.org_id for this input))
```
**This agent does not get to finalize this recipe on its own.** Confirm
it's been explicitly reviewed/signed off (same bar as any entitlement
change) before writing the query into `entity_store.py`/etc. If no
sign-off is on record, stop and report rather than picking a reasonable
default.

**QC check (round-trip, on replica or local test data):**
```sql
-- Grant org B access to an input owned by org A, confirm the recipe
-- above returns that input for org B, and confirms it does NOT return
-- it for an unrelated org C with no grant. Automate both assertions
-- as an actual query/test, not a manual read.
```

**Exit criterion:** read recipe explicitly signed off, wired into entity
reads, verified clean in staging for both the "own data" and "granted
to me" and "neither — must not see it" cases, before moving to
instrument/position.

---

## Phase 3 — `anchor` / `input` / `input_anchor`

This is the big one. **Sub-phase strictly in this order: entity, then
instrument, then position.** Do not attempt more than one anchor type
at a time.

### 3a — Build + backfill (no cutover yet)

**What changes:** new tables `anchor`, `input`,
`input_resolution_attempt`, `input_resolution_candidate`, `input_anchor`
exist alongside the legacy `resolution_staging` /
`resolution_input_snapshot` / `resolution_input_target` /
`entity_ingestion_source`. Both are written to (dual-write) through the
existing code paths — **no application read-path logic changes in this
sub-phase.**

**Known hard part, flag explicitly if attempted non-interactively:**
`resolution_input_target` is documented in `atlas-service` as *not
reliably kept in sync* by the legacy correction code. Do not trust it as
the source for reconstructing "current belief" when backfilling
`input_anchor`. Reconstruct by replaying `resolution_staging` +
`resolution_correction` in chronological order per `input_id` instead.
If the replica data makes this ambiguous for any `input_id` (e.g.
conflicting timestamps, a correction with no traceable prior staging
row), **stop and report the specific `input_id`s** rather than guessing
which belief should end up at `version = 0`.

**Locked design (confirmed with the human) — resolution, correction, replay.** Do not re-derive. Anything not listed here is not decided: stop and ask.

*Flow.*
1. A pipeline hits Atlas. Atlas creates one `ingestion`. It creates one `input` per submitted item.
2. If the input needs resolution, the resolver writes one `input_resolution_attempt`, its `input_resolution_candidate` rows, and an `input_silver_identifier` row when the input has a `silver_id`.
3. The outcome gives an anchor: ATTACH uses an existing one, INSERT creates an `ACTIVE` one, AMBIGUOUS creates a `TEMPORARY` one. `input_anchor` gets its first row at `version = 0`, with `attempt_id` set and no reason.
4. The entity (or instrument) and its rich data are written, as today.

*Write order changes.* Today the attempt log and `resolution_input_target` are written last. In the new flow: attempt, then anchor and entity, then `input_anchor`, then rich data. The anchor must exist before `input_anchor` points at it.

*One `input_id` for life.* A correction or replay never creates a new `input` or a new `ingestion`. The current `replay` creates a new ingestion source and new inputs by calling `create_entities`. That breaks the one-input-per-item granularity. It goes away.

*One operation, `apply(input_id, target_anchor_id)`.* Replay and the ATTACH correction are the same operation. The caller always supplies the anchor. The target must differ from the current anchor (`reattach` already fails with 400 when they match). Steps:
1. Lock the `input` row (`SELECT ... FOR UPDATE`).
2. Unwind: delete the rich data of this `input_id` (`delete_<anchor>_rich_data_for_input`).
3. Re-ingest the stored `input.payload` into the target anchor.
4. Retire the current `input_anchor` row to `MAX(version) + 1`. Insert the new row at `version = 0` with `correction_operation` and `reason`.
INSERT is the same call, with a newly created anchor as the target. The resolver is not involved: no attempt, no candidates, `attempt_id` is NULL. The resolver runs only on first ingest.

*Single writer.* Exactly one function writes `input_anchor`: `apply`, plus the first-ingest write. No other code path inserts, updates, or deletes in that table.

*No DB trigger for the reason rule.* The first belief has no `correction_operation` and no `reason`. Every later version has both. `apply` enforces this in Python. `check_input_anchor_reason` in `schema-basic.sql` is removed. This follows the project rule already recorded in `target-schema/CHANGELOG.md`: no DB triggers, no SQL functions for derived values.

*Status flips.* MARK_AS_TEST, MANUALLY_DELETE and MARK_AS_ACTIVE do not touch `input_anchor`. They go to `anchor_status_correction`.

*Position cascade.* A position has no resolution step. It moves only as a cascade of an entity or instrument correction. Outcomes are REPOINT, CREATE_NEW, MERGE (`docs/correction_use_cases.md`).
- Today the cascade writes no `resolution_correction` row and records no reason. It only moves the `position_ingestion_source` links.
- REPOINT keeps the same `position_id`. The position input's `input_anchor` row does not change.
- CREATE_NEW and MERGE change the position anchor of the position's inputs. Each such input gets a new `input_anchor` version with `correction_operation` and `reason` set to the system value `cascade`.

*`correction_id`.* `input_anchor` gets a `correction_id UUID` column. `apply` generates one value per correction request. Every `input_anchor` row written by that request carries it: the corrected input and every cascaded position input. With `batch_by_source`, all inputs of the request share one value. To find everything that moved together, query `WHERE correction_id = ...`. The column has no foreign key, on purpose: version numbers are renumbered on every retire, so a reference by `(input_id, version)` would go stale. The first-ingest row has `correction_id` NULL.

*Candidates.* `input_resolution_candidate` has its own `candidate_id` primary key (not `(attempt_id, anchor_id)`). `anchor_id` is nullable. This keeps legacy behavior: one row per strategy hit, so the same anchor can appear twice in one attempt, and a `NO_MATCH` row ("this strategy found nobody") is kept with its strategy and comment. The attempt itself is never empty. On no match the resolver creates the anchor (INSERT) and the attempt's `resolution_target_id` points at it.

*Silver identifier.* `input_silver_identifier` supports legacy scoping. It has an `anchor_type` column, a composite foreign key `(input_id, anchor_type)` to `input`, and `UNIQUE (source_id, silver_id, anchor_type)`. `source_id` takes the place of legacy `group_key`. The row is keyed by input and has no anchor pointer, so a remap does not touch it and re-ingesting the same input does not collide. The lookup is: silver row, then `input_anchor` at `version = 0`, then the anchor.

*Payload expiry.* `input` carries nullable `expired_at`, `expiry_reason` and `validation_error`. When a create schema changes, an Alembic-style step marks the inputs whose payload no longer validates. Replay and `apply` refuse an expired input. Legacy `resolution_input_snapshot` expiry fields were never set by any code.

*Reason vocabulary.* `cascade` is added as an allowed correction reason.

*Deferred.*
- `ON DELETE` actions for the new foreign keys to `input` and `anchor`: decided after everything is migrated. The `input_id` FK step below stays last.
- Backfill of `anchor`, attempts, candidates and `input_anchor` (including how attempts are grouped and how `resolution_correction` rows rebuild the version history): discussed when the data moves, not before.

**Status update (after PR 176 merged) — what shipped, what the prod backfill found, and what is still open.**

- **PR 176 is merged.** Three things changed in review. (1) `item_index` is no longer supplied by the caller: `InputItem` has no such field, `InputService` numbers items by position in the batch, and `InputStore.create_inputs` adds `max(item_index) + 1` for that `ingestion_source_id` under a row lock on `ingestion_source`. The offset exists because an `ingestion_source_id` can be reused: the old two-call flow (resolve, then ingest) shared one `ingestion_source_id` per Dagster run. As long as the V2 flow still resolves separately, this reuse stays. Rethinking it is a separate PR. (2) `WritePath` has a docstring that defines each value by the endpoint that produces it. (3) The migration (`1ca2b7e56a61`) was re-parented onto `b7d3e91a4c20` after `main` gained a second head.
- **The backfill ran in prod and finished.** Dry run against prod first (read-only role, same SQL as the backfill): 278,078 distinct `input_id` across 1,889 ingestion sources. 26,647 had a `resolution_input_snapshot` (written as `CREATE` with the real payload). 251,431 had none (written as `BACKFILL` with payload `{}`). 238 `input_id` had more than one snapshot row, with identical payloads in every case. No `source_id` was missing from `source_identity`. No vote ties.
- **Two pre-existing ambiguities, both resolved by rule.** (a) 150 `input_id` appeared under more than one `anchor_type` across tables; the resolution tables' `target_type` decides, and all 150 had one. (b) 5 `input_id` appeared under more than one `ingestion_source_id`; the backfill takes a majority vote. In all 5 the minority was `instrument_fee` (4 cases, 2 rows each) or `instrument_coupon` (1 case, 1 row) written against a different ingestion source of the same `source_id` and `group_key`. **These 9 rows were fixed by hand in prod** (direct `UPDATE` of `ingestion_source_id` to the ingestion source the rest of the input points to, in a transaction). Re-running the dry run afterwards showed 0 inputs with more than one ingestion source. The writer that produced the mismatch was not investigated.
- **Final prod state:** 0 rows missing from `input` across all 27 driving tables. `input` held 278,187 rows at the last check (109 more than the dry-run count, from rows written while the backfill was still running).
- **Why this matters for the Tier-3 FK below:** if the FK is ever made composite (`input_id` plus `ingestion_source_id`), the 9 hand-fixed rows would have violated it. They are fixed now. A plain `FOREIGN KEY (input_id)` is not affected.
- **PR 184 deleted the backfill code** (merged). The backfill module, its endpoints, and the startup task are gone.
- **Write-path wiring is merged.** PR 180 (entity tag), PR 183 (create entity, instrument, position) and PR 185 (seed + analytics) are on `main`. Every former `uuid4()` `input_id` call site goes through `InputService`.
- **Next, in this order (decided with the human):**
  1. **Build the rest of 3a:** `anchor`, `input_resolution_attempt`, `input_resolution_candidate`, `input_anchor`, and the bundled `ingestion_source` -> `ingestion` rename, following the "Locked design" above. Read `target-schema/README.md` and `target-schema/schema-basic.sql` first. 
  2. **Phase 2, `input_grant`.** It does not depend on the FK.
  3. **Last: the `input_id` FK on the fact tables, plus `delete_input`.** Do it last on purpose. A FK forces every writer and every test to have a real `input` row, so it is costly to redo if `input` or the new tables still change. Its cascade rules also depend on how `input_anchor` and corrections end up. The human must decide whether deleting an `input` cascades into `resolution_staging`, `resolution_correction`, `resolution_input_snapshot` and `resolution_input_target`. Today those four are `RESTRICT` from `ingestion_source`, and `IngestionSourceStore.delete_ingestion_source` clears them by hand. Also decide plain `FOREIGN KEY (input_id)` versus composite `(input_id, ingestion_source_id)`.
- **Facts for the FK step, checked in code, not yet acted on:** 29 tables carry `input_id`, not about 20. `operating_cash_flow` and `resolution_correction` were never backfilled (`resolution_correction.input_id` is probably optional). `resolution_correction` appeared to have no index on `input_id`. A cascade delete needs one on every child table. Many test helpers insert facts with a random `uuid4()` `input_id`; they all need a real `input` row once the FK exists.
- **Rollout for the FK, when its turn comes:** (1) read-only gap check on prod, with the same `NOT EXISTS` query per table; close any gap with a one-off fill (the deleted backfill is in git history, `47c8902`); (2) add any missing `input_id` indexes with `CREATE INDEX CONCURRENTLY`; (3) per table, `ADD CONSTRAINT ... NOT VALID` then `VALIDATE CONSTRAINT`, with `lock_timeout` set, and time `entity_attribute` (5.5M rows) on the replica first, because migrations run in the Helm init container and the halfvec migration already timed out there.

**QC check — dual-write agreement (run continuously against replica
during this sub-phase, or against a copy with replayed traffic):**
```sql
-- For every input_id, input_anchor version=0 must agree with the live
-- entity_ingestion_source state (and its instrument/position equivalents).
-- Do not use resolution_input_target as the comparison side: it is not
-- kept in sync by the legacy correction code. Build this as an actual
-- comparison job, not a one-time check — it needs to hold up over a
-- real window of live corrections happening during the bake-in period.
```

**Exit criterion:** comparison job clean over a real bake-in window
(not a single point-in-time check) before 3b starts.

**Confirmed design direction (2026-11-13), the actual point of minting `input` as a real table — not just a PR 176 implementation detail, write it down here so it isn't re-derived or second-guessed later:** deletion is meant to cascade at every granularity of this lineage chain, all the way down, by construction:

- Delete a `source_identity.source_id` → every `ingestion_source` row under that writer slot goes, and everything downstream of each of those.
- Delete an `ingestion_source.ingestion_source_id` → every fact row and every `input` row tied to that one batch goes.
- Delete an `input.input_id` → everything tied to that one submitted item goes.

Human, explicit, re: why `input` exists at all: "that's exactly why we are creating the input_id as a stable id! and yes it will become a FK to all the tables (which already have the input_id)."

**Verified against the real `atlas-service` code (PR 176, `cde3b2a`) — where this actually stands right now:**

- **Tier 1 (`source_identity` → `ingestion_source`) — already true.** `ingestion_source.source_id` is a plain `foreign_key(SourceIdentityRecord.source_id)` with no override, so it inherits `opto_python_helpers`' default `ON DELETE CASCADE`.
- **Tier 2 (`ingestion_source` → fact tables, including `input`) — already true, by two different mechanisms that both land in the same place.** Most fact tables (`entity_name`, `entity_attribute`, ..., and now `input` per PR 176's `input_ingestion_source_id_source_id_fkey`) cascade by the same helper default. Four tables — `resolution_staging`, `resolution_correction`, `resolution_input_snapshot`, `resolution_input_target` — are deliberately `RESTRICT` instead, and `IngestionSourceStore.delete_ingestion_source` explicitly clears each of them by hand before deleting the parent row. Either way, deleting an `ingestion_source` row today already takes everything under it with it.
- **Tier 3 (`input` → every fact table that carries `input_id`) — not true yet, and structurally can't be.** Checked `entity_name_db_schema.py`/`entity_attribute_db_schema.py` directly: `input_id: Mapped[UUID] = mapped_column()` — a bare column, no `FOREIGN KEY` at all, on every one of the ~20 fact tables that have carried `input_id` since Phase 1 (the same table list `input_backfill_internal_api.py`'s `KEYSET_DRIVING_TABLES` already walks). That's expected, not a bug in PR 176 — `input_id` was minted ad hoc in Python in five different places before this PR, so there was never a real row to point an FK at. PR 176 itself also adds no `delete_input` operation at all (`InputService`/`InputStore` only have `create_inputs`).

**Explicit next step this unblocks — not in scope for PR 176 itself, flagged here so it isn't lost:** once `input` has real write-path adoption (the "wiring real write paths to use InputService" step this roadmap already calls out as deferred), add `FOREIGN KEY (input_id) REFERENCES input (input_id) ON DELETE CASCADE ON UPDATE CASCADE` to every fact table in that same ~20-table list, replacing today's bare `input_id` column, plus a real `delete_input` service/store method (and internal API route) to actually exercise it. Until that migration ships, `input_id` on fact tables remains referential-integrity-free, same as it's always been — PR 176 only stood up `input` as a real row to eventually point at, it didn't yet wire the pointing.

Also applies to `target-schema/schema-basic.sql`: every `... REFERENCES input (input_id)` line there (`input_resolution_attempt`, `input_resolution_candidate`, `input_silver_identifier`, `input_anchor`, etc.) currently has no explicit `ON DELETE` action, which defaults to `RESTRICT` in plain SQL — that default disagrees with the cascade-all-the-way-down direction confirmed above and needs the same explicit `ON DELETE CASCADE` added once this is actually implemented, not left to the SQL default. Flagging here rather than editing `schema-basic.sql` now, since no table in that file is implemented yet for this agent to attach the change to.

### 3b / 3c / 3d — Cut over reads, entity → instrument → position

Rewrite the relevant `*Service`/`*Store` to read from the new tables,
**one anchor type at a time**. Keep dual-write running underneath so
rollback is instant (flip reads back, no data loss, since the old write
path never stopped). Each sub-phase gets its own bake-in before the
next starts.

### 3e — Cut over corrections, then retire legacy tables

Rewrite `correction_service.py` / `resolution_engine.py` last, same
entity → instrument → position order. **Every scenario in
`correction_use_cases.md` needs a passing equivalent test against the
new mechanism before this ships** — not just new unit tests on
`input_anchor` in isolation.

**Known fragility to carry forward, not fix silently:** the
`input_anchor` version-retire step requires locking the owning `input`
row (`SELECT ... FOR UPDATE`) before computing `next_version`, to avoid
a race between two concurrent corrections on the same `input_id`.
Confirm this lock is actually present in whatever function performs the
retire+insert, and that there is exactly **one** code path that can ever
write to `input_anchor` (not a second ad hoc script bypassing it) before
calling this sub-phase done.

**Also confirm before dropping legacy tables:** every fact table that
carries a `source_id` column actually has it populated correctly on
every write through the application service layer (not a DB trigger —
see this roadmap's Phase 1 section and `target-schema/CHANGELOG.md`'s
"Phase 1 implementation deep-dive" row for why), and that every write
path for that fact table resolves `source_id` the same way
(`IngestionSourceService.get_source_id_by_ingestion_source_id`,
threaded down as a plain parameter) rather than setting it some other
way — there's no cascade function or trigger here to hardcode a table
list in, but nothing stops a new fact table being added later without
this wiring either. Write the integration test this needs (write a
fact row through the normal path, assert its `source_id` matches the
owning `input`'s) rather than trusting a manual review of each write
path.

Only after all three anchor types are fully cut over (reads *and*
corrections) and baked in for a real production window: drop
`resolution_staging`, `resolution_input_snapshot`,
`resolution_input_target`, `entity_ingestion_source`,
`ingestion_source_group_key`/`entitlement_group` columns. This is a
one-way door — do not do it as part of the same change that cuts over
reads/corrections.

---

## Cross-phase rules (reiterating `AGENTS.md`, don't relax these)

- This agent verifies against the **local replica only**. It never
  executes any of the above against real `atlas_prod` — a human/deploy
  pipeline does that, using the migration + backfill module this agent
  produces.
- Every "Resolved open decision" above is settled — don't re-derive or
  second-guess it. Every "Open decision requiring human sign-off" is
  explicitly *not* settled — don't pick a default for it.
- When a QC check fails, report the actual query result, not a
  paraphrase — the next person (human or agent) needs the real numbers
  to decide what happened.

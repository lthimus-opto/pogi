Status: Phase 0

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
| 1 | `source_identity` / `ingestion` (renamed from `ingestion_source`) / `source_id` / `access_group` / `source_visibility` on fact tables | Low, self-contained | Phase 0 clean |
| 2 | `input_grant` table + read-path wiring | Low (additive), Medium once wired into reads | Phase 1 shipped |
| 3a | `anchor` / `input` / `input_resolution_attempt` / `input_resolution_candidate` / `input_anchor` — new tables, backfilled, dual-written | High (data reconstruction) | Phase 1 shipped |
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

**Nothing in this phase touches schema.** It's pure verification.

---

## Phase 1 — `source_identity` / `ingestion` / `source_id` / `access_group` / `source_visibility`

**What changes — superseded design, confirmed during the Phase 1 deep-dive (see
`target-schema/CHANGELOG.md`, "Phase 1 deep-dive" row, for the full before/after and reasoning):**
- The old plan computed `chain_group_key` as a `GENERATED` hash
  (`md5(source_type || ':' || org_id)`) directly on `ingestion_source`.
  That's gone. Instead:
  - New table **`source_identity`**: one row per distinct
    `(source_type, owner_id)` writer slot, with a real random
    surrogate `source_id` PK (not derived from `source_type`/`owner_id`
    by any formula), plus `source_visibility` and `access_group` as
    `GENERATED` columns off those same two inputs — both moved here
    from `ingestion_source` since there's nothing left on the renamed
    `ingestion` table to derive them from.
  - **`ingestion_source` is renamed `ingestion`**, trimmed to per-run
    facts only: `source_id` (FK into `source_identity`),
    `ingestion_subtype` (renamed from `source_subtype`, same free-text
    review/diff-metadata role, still no structural part in uniqueness),
    `pipe_type`, `pipe_run_id`.
  - `owner_id` is the renamed `org_id` on this new table only —
    `input_grant.org_id` (a list of *grantee* orgs, unrelated concept)
    is untouched.
- Each fact table (`entity_name`, `entity_identifier`, and their
  instrument/position equivalents once those exist) gains a
  `source_id` column — a real `FOREIGN KEY REFERENCES source_identity
  (source_id)`, not a bare `UUID` — populated by a backfill job joining
  through `input.ingestion_id -> ingestion.source_id`, then maintained
  going forward by a `BEFORE INSERT OR UPDATE OF input_id` trigger
  (`set_source_id`).
- A real partial `UNIQUE` index per fact table:
  `(entity_id, name_type, source_id) WHERE valid_to IS NULL`
  (and the equivalent for each other fact table/slot).
- **No cascade triggers.** The old design needed two `AFTER UPDATE`
  triggers to retroactively push a corrected `org_id`'s derived values
  down three hops (`ingestion_source -> input -> fact tables`) whenever
  someone fixed a wrong `org_id` in place. `source_id` is a stable
  surrogate, never recomputed from mutable fields, so there is nothing
  to retroactively push — a wrong writer identity is fixed by
  superseding the old `input` row through the ordinary
  correction/resolution mechanism (Phase 3's `input_anchor`/correction
  path), same as every other wrong fact in this schema. Do not
  reintroduce an `AFTER UPDATE` cascade here; if a later deep-dive finds
  a case that seems to need one, that's a divergence-protocol stop, not
  something to build around this note.

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
- **Resolved during the Phase 1 deep-dive — `source_visibility` is
  `GENERATED` off `source_type`, settling what was previously an open
  question.** It now lives on `source_identity`
  (`source_type_to_source_visibility(source_type)`), not as an
  independently-settable column — closing exactly the gap the open question
  below used to flag: a mismatched `source_visibility`/`source_type` pair
  could otherwise produce a writer slot with no `owner_id` folded in,
  silently merging every org's private data under one `source_type` into
  one slot.

**Pending confirmation — raised during review, not yet confirmed either
way, nothing in `target-schema/` has been changed for this. Run the
divergence protocol above before Phase 1 implementation starts, don't
assume an answer:**
- Should the `source_type → access_group` SQL function
  (`source_type_to_access_group`, now on `source_identity`) have an
  `ELSE RAISE EXCEPTION` branch, instead of the bare `CASE` it currently
  has in `target-schema/schema-basic.sql` that can fall through to
  `NULL`? (The concern: a `NULL` `access_group` is invisible to every
  entitlement filter, including internal/admin, with no error anywhere.)

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

**QC check — dual-write agreement (run continuously against replica
during this sub-phase, or against a copy with replayed traffic):**
```sql
-- For every input_id, input_anchor version=0 must agree with whatever
-- resolution_input_target + the live entity_ingestion_source state
-- currently says is the resolved target. Build this as an actual
-- comparison job, not a one-time check — it needs to hold up over a
-- real window of live corrections happening during the bake-in period.
```

**Exit criterion:** comparison job clean over a real bake-in window
(not a single point-in-time check) before 3b starts.

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
carries a `source_id` column actually has its `set_source_id` trigger
wired up (`BEFORE INSERT OR UPDATE OF input_id`), and that every write
path for that fact table goes through it rather than setting `source_id`
directly — there's no cascade function here to hardcode a table list in
(Phase 1 deliberately removed that mechanism, see
`target-schema/CHANGELOG.md`'s "Phase 1 deep-dive" row), but nothing
stops a new fact table being added later without the trigger attached
either. Write the integration test this needs (write a fact row through
the normal path, assert its `source_id` matches the owning `input`'s)
rather than trusting a manual review of each `CREATE TRIGGER` statement.

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

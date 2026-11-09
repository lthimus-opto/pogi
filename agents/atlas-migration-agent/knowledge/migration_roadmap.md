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
above and `target-schema/CHANGELOG.md`.** Three fixes already went
through that confirmation step and are already applied directly in
`target-schema/schema-basic.sql` (not just noted here in prose):
`anchor.anchor_id` uses `uuidv7()`, `ingestion_source`'s rerun-safety
constraint is keyed on `chain_group_key` not bare `source_type`, and
`entity_name` no longer carries embedding columns. Check
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
| 1 | `chain_group_key` / `access_group` / `source_visibility` on `ingestion_source` + fact tables | Low, self-contained | Phase 0 clean |
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
- Against the replica, compute what `chain_group_key` *would* be for
  every existing `ingestion_source` row
  (`md5(source_type || ':' || org_id)` for rows with `org_id`,
  `md5(source_type)` otherwise) and diff against the current free-text
  `ingestion_source_group_key` values actually in use on fact tables.
- Compute what `access_group` *would* be via the SQL port of
  `get_source_entitlement_group` (see `app/utils/entitlement_utils.py`
  in `atlas-service`) and diff against the existing
  `entitlement_group` column on every historical `ingestion_source` row.
- Check for existing constraint violations the *new* mechanism would
  introduce: are there currently two "open" (`valid_to IS NULL`) rows
  for the same `(entity_id, name_type)` (and identifier/other fact
  tables) that would collide once keyed by the new `chain_group_key`
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

## Phase 1 — `chain_group_key` / `access_group` / `source_visibility`

**What changes:**
- `ingestion_source` gains `source_visibility`, `chain_group_key`,
  `access_group`, and `source_subtype` as described in `schema-basic.sql`
  — **except**: `source_visibility` must be `GENERATED ALWAYS AS (...) STORED` off
  `source_type`, **not** a free column. (Open decision, resolved below
  — do not implement it as a plain column.) `source_subtype` (`TEXT NOT NULL`,
  the renamed `group_key`) is a plain column, not generated, and deliberately
  plays no part in `chain_group_key` or any uniqueness — pure review/diff
  metadata, confirmed during Phase 0, see `target-schema/CHANGELOG.md`.
- Each fact table (`entity_name`, `entity_identifier`, and their
  instrument/position equivalents once those exist) gains a
  `chain_group_key` column, populated by a backfill job joining through
  `ingestion_source_id`, then maintained going forward by a
  `BEFORE INSERT OR UPDATE OF input_id` trigger.
- A real partial `UNIQUE` index per fact table:
  `(entity_id, name_type, chain_group_key) WHERE valid_to IS NULL`
  (and the equivalent for each other fact table/slot).

**Backfill sizing:** check real row counts on the replica for every
affected fact table before deciding inline-`UPDATE`-in-migration vs. the
full backfill-endpoint pattern — follow `backfill_pattern.md`'s decision
rule exactly, don't assume scale.

**Confirmed and applied — already reflected in `target-schema/schema-basic.sql`, see `target-schema/CHANGELOG.md`:**
- `pipe_run_id`'s rerun-safety uniqueness is `UNIQUE (chain_group_key, pipe_run_id)`, not
  `UNIQUE (source_type, pipe_run_id)` — the latter was missing `org_id`
  and would have wrongly rejected two different orgs reusing the same
  deterministic `pipe_run_id` under one `source_type`.
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
  should still chain as one writer under `chain_group_key` but need to stay
  distinguishable for review). Confirmed fix: `ingestion_source` gains
  `source_subtype` (`TEXT NOT NULL`, free text, one static value per pipe
  same as `group_key` was) — deliberately excluded from `chain_group_key`'s
  formula and not duplicated onto any fact table. `chain_group_key` itself
  needed no change; it was already `source_type` + `org_id` only. See the
  Phase 0 row in `target-schema/CHANGELOG.md` for the full reasoning.

**Pending confirmation — raised during review, not yet confirmed either
way, nothing in `target-schema/` has been changed for these. Run the
divergence protocol above on each before Phase 1 implementation starts,
don't assume an answer:**
- Should `source_visibility` be `GENERATED` from `source_type` instead
  of the independently-settable column it currently is in
  `target-schema/schema-basic.sql`? (The concern: a mismatched
  `source_visibility`/`source_type` pair could produce a
  `chain_group_key` with no `org_id` folded in, silently merging every
  org's private data under one source_type into one writer slot.)
- Should the `source_type → access_group` SQL function have an
  `ELSE RAISE EXCEPTION` branch, instead of the bare `CASE` it currently
  has in `target-schema/schema-basic.sql` that can fall through to
  `NULL`? (The concern: a `NULL` `access_group` is invisible to every
  entitlement filter, including internal/admin, with no error anywhere.)

**QC check before adding the unique index (run on replica):**
```sql
-- Must return 0 rows for every fact table before the index is added.
SELECT entity_id, name_type, chain_group_key, count(*)
FROM entity_name
WHERE valid_to IS NULL
GROUP BY 1, 2, 3
HAVING count(*) > 1;
```

**QC check after backfill, before shipping (run on replica):**
```sql
-- Must return 0.
SELECT count(*) FROM ingestion_source WHERE access_group IS NULL;
SELECT count(*) FROM entity_name WHERE chain_group_key IS NULL;
-- (repeat the second for every fact table that got the column)
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
     OR requesting_org = owning_org   -- via ingestion_source.org_id
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
needs to participate in the `chain_group_key` correction cascade has
actually been added to the cascade function
(`cascade_input_chain_group_key`-equivalent) — this function hardcodes
the fact-table list, nothing enforces it stays complete as tables are
added. Write the integration test this needs (correct an `org_id`,
assert every single fact table type reflects the new key) rather than
trusting a manual review of the function body.

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

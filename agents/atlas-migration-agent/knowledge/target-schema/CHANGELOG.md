# Changelog — `target-schema/`

This file tracks every confirmed edit made to `schema-basic.sql`/`README.md`
in this folder, since they're a frozen copy from another repo, not a live
sync. Per `../migration_roadmap.md`'s divergence protocol: nothing in this
folder gets edited without an explicit human "yes" first. Every row below
corresponds to a real confirmation that happened during review or during a
phase's deep-dive, not a judgment call made unilaterally.

| Date | File | Change | Why | Confirmed by |
|---|---|---|---|---|
| 2024 review | `schema-basic.sql` | `ingestion_source.pipe_run_id` rerun-safety constraint changed from `UNIQUE (source_type, pipe_run_id)` to `UNIQUE (chain_group_key, pipe_run_id)` | The original was missing `org_id` — two different orgs reusing the same deterministic `pipe_run_id` under one `source_type` would have been wrongly rejected as a collision | Human, explicit "yeah you're right" |
| 2024 review | `schema-basic.sql` | `anchor.anchor_id` default changed from `uuidv4()` to `uuidv7()` | Consistency with every other PK in the file, which already uses `uuidv7()` for insert locality; no justification was ever written down for `anchor_id` being the one exception | Human, explicit "yes we should use uuidv7()" |
| 2024 review | `schema-basic.sql` | Removed `embedding_model`/`embedding` columns and their `CHECK (num_nonnulls(...) IN (0, 2))` constraint from `entity_name` | `entity_name` should only change for the lineage columns (`input_id`, `chain_group_key`, `provenance_id`); embeddings belong exclusively on `entity_embedding`, mirroring how `entity_fuzzy_match` already stays separate and lineage-free. The two-places-for-one-fact duplication this fixes could otherwise let an entity's "live" embedding and its audited embedding history silently drift apart | Human, explicit "this is wrong ... should not change except for the lineage piece" |

## Confirmed, but no `schema-basic.sql` edit needed

These went through the same confirmation step and are just as settled as
the table above — they just don't correspond to a line in this SQL file,
so there's nothing to change here. Listed separately so they don't get
mistaken for still-undecided items below.

- `group_key` is confirmed safe to drop from `atlas-service`'s API
  request schemas — verified empirically against every pipe in
  `data-factory`: each defines exactly one static `group_key` constant
  per dataset, and `org_id` is what already does the real tenant
  separation. `schema-basic.sql` never had a `group_key` column, so
  there's no SQL to change; the actual work for this one is in
  `atlas-service`'s Python request schemas, not here.

## Still open — raised, not yet confirmed either way

These were raised during review but never got an explicit per-item yes/no,
so **nothing in `schema-basic.sql` has been changed for them yet**. They
need to go through the same confirmation step before any edit lands here —
see `../migration_roadmap.md`'s "Pending confirmation" list in Phase 1/2/3
for the current status of each.

- `source_visibility` should probably be `GENERATED` from `source_type`
  instead of a free column (currently still a free `NOT NULL` column in
  `schema-basic.sql`).
- `source_type_to_access_group()` should probably have an
  `ELSE RAISE EXCEPTION` instead of falling through to `NULL` on an
  unhandled `source_type` (currently still has no `ELSE` in
  `schema-basic.sql`).

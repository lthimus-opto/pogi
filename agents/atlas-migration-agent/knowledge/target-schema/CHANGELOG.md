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
| Phase 0 (this migration) | `schema-basic.sql` + `README.md` | Reversed the "`group_key` confirmed safe to drop" item below: re-added as `ingestion_source.source_subtype` (`TEXT NOT NULL`), free text, deliberately excluded from `chain_group_key` and not duplicated onto any fact table | Raised during Phase 0: `source_type`/`org_id` alone can't distinguish real review-relevant subcategories that should still chain together as one writer — e.g. Form ADV's daily snapshot vs. monthly detailed filing, or a future second legacy system feeding `system_migration` for the same org. `chain_group_key`'s formula (`source_type` + `org_id` only) was already correct and needed no change; only the earlier "drop `group_key` entirely" call was wrong — it should have been "drop it from chaining/uniqueness, keep it renamed as pure metadata." Not nullable: every pipe already sets exactly one static value today, so there's no real case for omitting it | Human, explicit "should not be nullable and free text is fine" |
| Phase 1 deep-dive | `schema-basic.sql` + `README.md` | Replaced `ingestion_source.chain_group_key` (a `GENERATED` hash of `source_type`+`org_id`) with a real dimension table `source_identity` (`source_id` surrogate PK, `source_type`, `owner_id`, plus `source_visibility`/`access_group`, which also moved here from `ingestion_source`). `ingestion_source` renamed to `ingestion`, trimmed to per-run facts only (`source_id` FK, `pipe_type`, `pipe_run_id`, `ingestion_subtype` — the renamed `source_subtype`). Every fact table's `chain_group_key` column renamed to `source_id` and converted to a real `FOREIGN KEY REFERENCES source_identity (source_id)` instead of a bare `UUID`. `source_identity` gets a second partial unique index, `UNIQUE INDEX ... (source_type) WHERE owner_id IS NULL`, alongside `UNIQUE (source_type, owner_id)`, since `owner_id` is `NULL` for every `LICENSED` source and plain `UNIQUE` doesn't dedupe `NULL`s. Both `AFTER UPDATE` cascade triggers (`cascade_ingestion_source_derived_columns`, `cascade_input_chain_group_key`) removed entirely. Also resolves the Phase 1 "pending confirmation" item on whether `source_visibility` should be `GENERATED` off `source_type`: yes, now that it lives on `source_identity` — `source_type_to_source_visibility(source_type)`. | A `GENERATED` hash is reversible — `source_type` is a 7-value enum and `org_id` is enumerable from user_service, so `chain_group_key` was one dictionary attack away from leaking which org owned which private data, despite the comment calling opacity "the whole point." A random surrogate `source_id` has no such formula to invert, and being a real FK means two writer rows can never silently drift out of agreement with the mapping logic the way a hash ported to multiple places could. The `AFTER UPDATE` cascades existed only to retroactively fix `chain_group_key`/`access_group` after an `org_id` correction — with `source_id` stable and never recomputed, that entire retroactive-push mechanism has nothing left to do: a wrong writer identity is fixed the same way every other wrong fact in this schema is, by superseding the old `INPUT` row through the ordinary correction/resolution path, not by a bespoke `UPDATE`-driven cascade. | Human, explicit: "MUCH better idea ... then source_id becomes our UUID = chain group key today so we dont have any DB trigger", confirmed table name `source_identity`, `owner_id` naming, `ingestion`/`ingestion_subtype` naming, `access_group`/`source_visibility` moving to `source_identity`, and "there is not trigger anymore! that's the whole point" |
| Phase 0 QC follow-up | `schema-basic.sql` | `source_type_to_source_visibility()` no longer classifies `ARCH` as `LICENSED` — moved to the `ELSE` (`PRIVATE`) branch, alongside `MANUAL`/`PITCH_DECK`/`SYSTEM_MIGRATION`. Only `SEC_ADV`/`SEC_EDGAR`/`MSCI` remain `LICENSED` | Raised during Phase 0 QC against real prod data: every live `ARCH` `ingestion_source` row already carries a real, non-null `owner_id` (currently always OPTO's own org), which would have violated `source_identity`'s planned `CHECK ((source_visibility = 'PRIVATE') = (owner_id IS NOT NULL))` under the old `LICENSED` classification. Confirmed this isn't a data bug — `atlas-service` PR #148 ("Flip ARCH source_visibility to PRIVATE, backfill org_id", commit `21e976a`, merged to main) already made this exact change at the app-code level and backfilled `org_id` accordingly. The rule is now cleanly OWNER_ID-shaped: anything that carries a real `OWNER_ID` is `PRIVATE` (`ARCH`, `MANUAL`, `PITCH_DECK`, `SYSTEM_MIGRATION`); `MSCI`/`SEC_ADV`/`SEC_EDGAR` never carry one and stay `LICENSED`. Note: the live app code (`app/common_enums/ingestion_source_type.py`) actually has a third value, `PUBLIC`, applied to `SEC_ADV`/`SEC_EDGAR` specifically (`LICENSED` reserved for `MSCI` only) — explicitly not ported here; confirmed with a human that this schema's `source_visibility` stays the simpler two-value `LICENSED`/`PRIVATE` split, since `PUBLIC` vs `LICENSED` doesn't change `OWNER_ID` nullability, the only thing this column's CHECK constraint cares about | Human, explicit: "it should be PRIVATE anything with the org_id provided.. (arch, manual, pitch deck, system migration) then licensed for msci, sec" |

## Confirmed, but no `schema-basic.sql` edit needed

These went through the same confirmation step and are just as settled as
the table above — they just don't correspond to a line in this SQL file,
so there's nothing to change here. Listed separately so they don't get
mistaken for still-undecided items below.

- ~~`group_key` is confirmed safe to drop from `atlas-service`'s API
  request schemas~~ — **superseded, see the Phase 0 row above.** Still true
  that no pipe needs `group_key`/`source_subtype` for *chaining* purposes
  (verified empirically against every pipe in `data-factory`, `org_id`
  already does real tenant separation) — but it turned out to still be
  needed for *review/diff* purposes, so it comes back as
  `ingestion_source.source_subtype`, not dropped outright. Do not re-flag
  this as closed-and-done again without reading the Phase 0 row above
  first.

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

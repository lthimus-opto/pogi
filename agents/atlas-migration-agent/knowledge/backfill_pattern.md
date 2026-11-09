# Backfill Pattern — Schema Change + Short-Lived Backfill Endpoint

**Status:** confirmed pattern — already shipped once in `atlas-service`
(`embedding_backfill`, PR #116, removed in PR #126 once done). This doc
generalizes that precedent so the next backfill doesn't get re-derived
from scratch.

## When this applies

Any Alembic migration that would need to touch **existing row data at a
scale that risks a long transaction / lock contention / timeout** inside
the migration itself (confirmed real incident: the halfvec embedding
migration timed out doing exactly this). If the affected table is small
enough that an inline `UPDATE` in the migration finishes in a few
seconds, just do it in the migration — this pattern is for when it
can't.

Rule of thumb from the precedent: anything that touches every row of a
real production table, where "real" means not a handful of rows, gets
split. Check actual row count on the replica (see
`../replicate_prod.sh`) before deciding — don't guess.

## The split

1. **Migration — schema only, always safe and instant.**
   - Add the new column(s) **nullable**, no default (a default on an
     `ADD COLUMN` over existing rows forces a full table rewrite in
     older Postgres; even on versions where it doesn't, keep it out of
     scope for the migration — the backfill endpoint is what sets real
     values).
   - Add any index needed on the new column `CONCURRENTLY` if the table
     is large enough for that to matter.
   - Never touches existing data.

2. **Backfill — a short-lived internal API module**, deleted once done.
   Confirmed shape from `embedding_backfill_internal_api.py`:
   - `POST /internal/<thing>/<name>-backfill` — tries a
     `pg_try_advisory_lock` keyed to a constant derived from the
     migration revision hash (e.g. `0x2221A237` for revision
     `2221a237e355`). Lock held = `409 Conflict`, so only one backfill
     run is ever in flight, across all pods, no separate run-state table
     needed.
   - Runs as a `BackgroundTasks` job holding that connection+lock for the
     whole run; pages through the target table(s) in batches using
     keyset pagination (`WHERE id > :last_id AND col IS NULL ORDER BY id
     LIMIT :batch_size`), committing after every batch, with a short
     `sleep()` between batches for backpressure. This *is* the
     checkpoint — resumable by construction, because "what's left to do"
     is just re-querying `WHERE col IS NULL`, not a separately persisted
     cursor.
   - `conn.invalidate()` in a `finally` to drop the pooled connection
     (and the session-level advisory lock with it) on completion or
     crash — this is what makes it safe to just retry.
   - `GET /internal/<thing>/<name>-backfill` — reports `is_running`
     (derived from `pg_locks`, not app state), `remaining_rows` (`COUNT(*)
     WHERE col IS NULL` per table), `is_done`.
   - Also wired into `app/main.py`'s `lifespan`, firing-and-forgetting the
     same job on every startup (same advisory lock prevents duplicate
     runs across pods) — self-healing after a restart, in addition to
     being callable by hand.
   - Gated by the existing `/internal` JWT auth dependency
     (`INTERNAL_ENTITY_WRITE` or equivalent) — no new auth mechanism.
   - Marked with an `# AIDEV:` comment naming the migration it belongs to
     and when to delete it, e.g.:
     `# one-off backfill for migration <revision>; delete with the NOT
     NULL follow-up migration.`

3. **Follow-up migration + deletion**, once `is_done` is confirmed true in
   every environment (check row counts directly, don't trust vibes —
   precedent: `SELECT COUNT(*) FROM <table> WHERE <col> IS NULL` run
   against the real env before removing anything):
   - Flip the column to `NOT NULL` (or whatever the real invariant is).
   - Delete the entire backfill module (API file + router wiring +
     `main.py` lifespan hook + its tests) — it's dead weight once done,
     not a permanent surface.

## Lineage note

If the backfilled value represents a *fact*, not just a type/format
conversion of an existing column (the halfvec case was the latter — same
value, different encoding), write it through an `ingestion_source` row
with `source_type = SYSTEM_MIGRATION` (enum already added for exactly
this in `821f14ffb798_add_system_migration_to_ingestionsourcetype`), so
the backfilled data stays attributable like every other source instead
of silently appearing with no lineage.

## What to decide per new backfill

- Lock key: derive from the new migration's own revision hash, don't
  reuse another backfill's key.
- Batch size + sleep: tune to the table's real row count/width (checked
  against the replica, not guessed) — `10_000` rows / `2s` sleep was
  right for the embedding case specifically because of vector payload
  size, not a universal default.
- Backfill source: same-row column transform (simple, as above) vs.
  needs a join/lookup elsewhere (more care on the batching query — keyset
  pagination still works, but the `WHERE ... IS NULL` completeness check
  needs to match whatever the real "still needs backfill" predicate is).

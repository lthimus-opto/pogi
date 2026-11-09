---
name: backfill-pattern
description: >
  How to split an Alembic migration that would need to touch too much
  existing data into a schema-only migration plus a short-lived,
  advisory-lock-gated internal backfill endpoint. Use when writing a
  migration that adds a column needing values computed/copied across
  many existing rows, or when asked about backfill design.
---

# Backfill Pattern

Read `../../knowledge/backfill_pattern.md` in full before writing a
migration or backfill endpoint — it's the generalized template derived
from the real precedent already shipped in `atlas-service`
(`embedding_backfill`, PR #116, removed in #126). This skill only points
at it; the substance lives there so it can be extended with new
precedents over time without rewriting this file.

## Quick decision rule

Check the real row count on the affected table via the replicated local
DB (`replicate-prod` skill) before deciding — don't guess:

- Small enough to `UPDATE` inline in the migration in a few seconds →
  just do it in the migration. No backfill endpoint needed.
- Touches a real production-scale number of rows → split: schema-only
  migration (nullable column, no default) + short-lived backfill
  endpoint per `../../knowledge/backfill_pattern.md`.

## Where the actual code goes

The migration file and the backfill endpoint module both live in the
`atlas-service` repo (`app/db_schema/migrations/versions/`,
`app/app/<name>_backfill/`), not in this agent's own directory — this
agent only has read-only access to prod and local write access to the
replicated DB; it proposes/writes code into `atlas-service` directly,
following that repo's own conventions (file naming, router wiring in
`app/api_router/internal_api_router.py`, `main.py` lifespan hook,
matching test file under `tests/app/<name>_backfill/`).

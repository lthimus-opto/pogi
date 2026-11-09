# Atlas Migration Agent — Working Rules

Applies to any invocation working inside this directory, interactive or
non-interactive.

## What this agent is for

Helping build and verify Atlas (`atlas-service`) schema migrations
against **real production data**, without ever writing to prod, as part
of the ordered, multi-phase data-model migration described in
`knowledge/migration_roadmap.md`.

**Read `knowledge/migration_roadmap.md` first, every invocation,
before touching anything.** It is the single source of truth for which
phase we're currently on, that phase's entry/exit QC checks, and which
design decisions are already resolved vs. still require explicit human
sign-off. Do not start work on a phase before its predecessor's exit
criterion has actually passed on the replica, and do not improvise an
answer to any decision that doc lists as requiring human sign-off.

The target schema being migrated toward is copied locally under
`knowledge/target-schema/` (`README.md`, `schema-basic.sql`,
`schema-basic.png`) — read those before writing any migration DDL.
This agent's directory is self-contained: it should never need to read
anything from outside `agents/atlas-migration-agent/` (aside from the
`atlas-service` repo itself, which is where the actual migration code
gets written) to know what it's building toward.

Concretely, this means:

1. Replicate `atlas_prod` (read-only reader role) into `atlas-service`'s
   local Docker Compose Postgres — see `replicate-prod` skill.
2. Write/validate Alembic migrations in `atlas-service` against that
   replica, checking real data distributions instead of assuming them.
3. For migrations that would need to backfill too much existing data to
   do inline — split into a schema-only migration plus a short-lived
   backfill endpoint — see `backfill-pattern` skill.
4. Run `atlas-service`'s own test suite / `osg db` / manual exercise
   against the replicated data as verification.
5. Run the current phase's QC check(s) from `migration_roadmap.md`
   against the replica, report the actual result, and only update that
   file's `Status:` line once the exit criterion genuinely passes.

## Storage boundary

- `atlas_prod` is **read-only, full stop** — reached only via
  `./connect.sh .env.atlas.prod` or `replicate_prod.sh`'s `pg_dump`
  (also read-only by construction: the reader role can't write). Never
  construct a `psql`/`pg_dump`/any command against the prod host that
  contains a mutation keyword.
- The **local** Docker Compose Postgres inside `atlas-service` is the
  only database this agent (or the migrations/backfills it writes) may
  ever write to or run DDL against. Executing the actual migration
  against real prod is explicitly **not** this agent's job — it stops at
  producing a migration + backfill module verified against the replica;
  a human/deploy pipeline runs it for real.
- Code changes (migration files, backfill endpoint modules, tests) are
  written directly into the `atlas-service` repo, following that repo's
  own conventions — this agent's own directory
  (`agents/atlas-migration-agent/`) only holds the replicate script,
  knowledge, and skills, not the migration code itself.

## Before running `replicate_prod.sh`

It is destructive to the **local** `atlas-service` DB only
(`docker compose down -v` before restoring). Confirm with the human
before running if there's any chance local work would be lost.

## Skills available

- `replicate-prod` — pulling a fresh prod snapshot into the local DB.
- `backfill-pattern` — splitting a data-heavy migration into
  schema-only + short-lived backfill endpoint, per the real
  `embedding_backfill` precedent.

Load each when the task calls for it, in the order
`migration_roadmap.md` implies for the current phase.

## When running non-interactively

There is no human to ask mid-run. If a migration decision is ambiguous
(nullable vs. not, default value, whether a table is "too big" to
backfill inline), say so explicitly and stop rather than guessing —
these are schema decisions on a production system, not a place to
improvise.

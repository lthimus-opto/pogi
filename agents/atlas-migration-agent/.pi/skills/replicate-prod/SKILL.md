---
name: replicate-prod
description: >
  Replicate atlas_prod (read-only) into atlas-service's local Docker
  Compose Postgres, so migrations and code changes can be developed and
  verified against real data. Use when asked to refresh/replicate/pull
  prod data locally, or before writing/testing an Alembic migration.
---

# Replicate Prod

Run `../../replicate_prod.sh` (relative to this skill directory: the
real path is `agents/atlas-migration-agent/replicate_prod.sh`) via the
`bash` tool. Don't re-implement its steps inline — the script is the
single source of truth for this procedure.

```bash
cd agents/atlas-migration-agent
./replicate_prod.sh [optional-path-to-atlas-service-repo]
```

Defaults to `../../../atlas-service` relative to the script if no path is
given, which resolves to the real local checkout.

## Before running

- Confirm AWS SSO/profile auth is active (`aws sts get-caller-identity
  --profile prod` or similar) — the script generates its own IAM token but
  cannot log the caller into AWS.
- **This is destructive to the local DB only**: it runs
  `docker compose down -v` inside the `atlas-service` checkout, wiping
  any local data there, before restoring the prod dump. Confirm with the
  user before running if there's any chance of local work being lost —
  don't just run it silently on an ambiguous request.
- Never point this at anything other than the `atlas_prod` reader
  connection already configured in `.env.atlas.prod` — the whole point is
  read-only access to prod, writes only ever land in the local Docker
  Postgres.

## After running

- The script prints the restored `alembic_version`. Compare it against
  the latest file in `atlas-service/app/db_schema/migrations/versions`
  — if they don't match, say so explicitly before suggesting
  `alembic upgrade head`; don't assume it'll apply cleanly.
- Report the dump size and restore outcome briefly; don't dump full
  schema output unless asked.

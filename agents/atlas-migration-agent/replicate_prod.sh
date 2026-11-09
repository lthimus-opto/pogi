#!/usr/bin/env bash
# Replicate atlas_prod (read-only reader role) into atlas-service's local
# Docker Compose Postgres, so migrations/backfills/code changes can be
# developed and verified against real data, never against prod directly.
#
# Usage: ./replicate_prod.sh [path-to-atlas-service-repo]
#
# What it does:
#   1. Generates a fresh IAM auth token (tokens are AWS-fixed at 15 min,
#      never reused -- same discipline as data-agent/connect.sh).
#   2. pg_dump's the *entire* prod DB (schema + data, --no-owner
#      --no-privileges so it restores cleanly into the local `postgres`
#      superuser) via the read-only reader role. Safe: pg_dump against a
#      read-only role can't write anything, same risk profile as the psql
#      reads this repo already does.
#   3. Brings up atlas-service's local Docker Compose Postgres fresh
#      (`docker compose down -v && up --wait`) and restores the dump into
#      it with `-c` (clean/drop existing objects first).
#
# Afterwards, the local DB's `alembic_version` is whatever prod's actually
# is -- confirm it matches the latest file in
# app/db_schema/migrations/versions before trusting `alembic upgrade head`
# to apply cleanly on top.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ATLAS_SERVICE_DIR="${1:-$SCRIPT_DIR/../../../atlas-service}"
DUMP_FILE="/tmp/atlas_prod_$(date +%Y%m%dT%H%M%S).dump"

if [[ ! -d "$ATLAS_SERVICE_DIR" ]]; then
  echo "atlas-service repo not found at $ATLAS_SERVICE_DIR" >&2
  echo "Usage: $0 [path-to-atlas-service-repo]" >&2
  exit 1
fi

echo "== Loading prod connection env =="
set -a
# shellcheck disable=SC1090
source "$SCRIPT_DIR/.env.atlas.prod"
set +a

echo "== Generating fresh IAM auth token =="
TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$POSTGRES_HOST" \
  --port "$POSTGRES_PORT" \
  --username "$POSTGRES_USER" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE")

echo "== Dumping atlas_prod (schema + data, read-only reader role) =="
EXCLUDED_TABLES=(attachment attachment_grant attachment_version contact contact_fund contact_fund_family rich_data_correction tag_definition)
EXCLUDE_ARGS=()
for t in "${EXCLUDED_TABLES[@]}"; do
  EXCLUDE_ARGS+=(--exclude-table="public.$t")
done
PGPASSWORD="$TOKEN" PGSSLMODE=require pg_dump \
  -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  --no-owner --no-privileges -Fc \
  "${EXCLUDE_ARGS[@]}" \
  -f "$DUMP_FILE"
echo "   dump written to $DUMP_FILE ($(du -h "$DUMP_FILE" | cut -f1))"
echo "   excluded (reader role lacks SELECT, see migration_roadmap.md Phase 0 notes): ${EXCLUDED_TABLES[*]}"

echo "== Resetting local atlas-service Postgres (Docker Compose) =="
( cd "$ATLAS_SERVICE_DIR" && docker compose down -v && docker compose up -d db --wait )

echo "== Restoring prod dump into local DB =="
PGPASSWORD=postgres pg_restore \
  -h localhost -p "${DB_PORT:-5432}" -U postgres -d atlas_service \
  --no-owner --no-privileges -c --if-exists \
  "$DUMP_FILE"

echo "== Done. Local alembic_version: =="
PGPASSWORD=postgres psql -h localhost -p "${DB_PORT:-5432}" -U postgres -d atlas_service \
  -c "SELECT version_num FROM alembic_version;"

echo "Compare against the latest file in app/db_schema/migrations/versions"
echo "in $ATLAS_SERVICE_DIR before running 'uv run alembic upgrade head'."

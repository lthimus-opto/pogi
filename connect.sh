#!/usr/bin/env bash
# Usage: ./connect.sh .env.<database>.prod [psql args...]
# Example: ./connect.sh .env.atlas.prod -c "SELECT datname FROM pg_database;"
# Example: ./connect.sh .env.security_master.prod -f queries/some_query.sql
#
# Generates a fresh IAM auth token on every call (tokens expire in 15 min,
# fixed by AWS) so the expiry window is never something you have to think
# about -- each invocation is self-contained.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 .env.<database>.prod [psql args...]" >&2
  exit 1
fi

ENV_FILE="$1"
shift

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Env file not found: $ENV_FILE" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

TOKEN=$(aws rds generate-db-auth-token \
  --hostname "$POSTGRES_HOST" \
  --port "$POSTGRES_PORT" \
  --username "$POSTGRES_USER" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE")

PGPASSWORD="$TOKEN" PGSSLMODE=require psql \
  -h "$POSTGRES_HOST" -p "$POSTGRES_PORT" \
  -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
  "$@"

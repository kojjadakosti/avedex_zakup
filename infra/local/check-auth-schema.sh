#!/usr/bin/env bash
# Read-only contract for the Auth image and schema before importing cloud data.
# Never prints passwords, row values or private migration contents.
set -Eeuo pipefail

ROOT="$(cd "$(dirname -- "$0")/../.." && pwd -P)"
cd "$ROOT"
blocked() { echo "BLOCKED: $*" >&2; exit 78; }

command -v docker >/dev/null || blocked "Missing Docker"

image="$(docker inspect supabase-auth --format '{{.Config.Image}}' 2>/dev/null)" ||
  blocked "Local Auth container is missing"
[[ "$image" == "supabase/gotrue:v2.198.0" ]] ||
  blocked "Local Auth must run pinned v2.198.0 before restoration"

# The expected migration rows must be present, not merely their columns.
# The link token index is required as part of the official OTP migration.
sql_result="$(docker compose -f compose.local.yaml --env-file .env.docker \
  exec -T db psql -X -U postgres -d postgres -Atq -v ON_ERROR_STOP=1 \
  -c "
WITH required_columns AS (
  SELECT count(*) AS found
  FROM information_schema.columns
  WHERE table_schema = 'auth' AND (
    (table_name = 'one_time_tokens' AND column_name = 'link_token_hash'
      AND data_type = 'text' AND is_nullable = 'YES') OR
    (table_name = 'saml_providers' AND column_name = 'dedicated_scope'
      AND data_type = 'boolean' AND is_nullable = 'YES')
  )
), required_migrations AS (
  SELECT count(*) AS found FROM auth.schema_migrations
  WHERE version IN ('20260911120000', '20261030120000')
)
SELECT CASE WHEN
  (SELECT found FROM required_columns) = 2 AND
  (SELECT found FROM required_migrations) = 2 AND
  EXISTS (
    SELECT 1 FROM pg_indexes
    WHERE schemaname = 'auth' AND tablename = 'one_time_tokens'
      AND indexname = 'one_time_tokens_link_token_hash_hash_idx'
  )
THEN 'ready' ELSE 'incompatible' END;
")" || blocked "Cannot inspect local Auth schema"

[[ "$sql_result" == ready ]] ||
  blocked "Auth schema or migration history does not match v2.198.0"

echo "PASS: Auth v2.198.0, both required migrations and index verified"

#!/usr/bin/env bash
# Read-only local preflight. This is NOT a schema restore or a full parity test.
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$root"
blocked() { echo "BLOCKED: $*" >&2; exit 78; }

[[ -f .env.docker && -f .panda-local/supabase/.env ]] ||
  blocked "Run local initialization before checking business schema"
command -v docker >/dev/null || blocked "Docker is unavailable"
expected="${PANDA_EXPECT_PUBLIC_TABLES:-}"
if [[ -n "$expected" && ! "$expected" =~ ^[1-9][0-9]*$ ]]; then
  blocked "PANDA_EXPECT_PUBLIC_TABLES must be a positive integer"
fi

# Never output user rows, credentials, Vault contents or cron commands.
# The required tables are confirmed dependencies of existing migrations.
stats="$(docker compose -f compose.local.yaml --env-file .env.docker exec -T db \
  psql -X -q -At -v ON_ERROR_STOP=1 -U postgres -d postgres <<'SQL'
WITH required(name) AS (
  VALUES ('app_profiles'), ('app_user_access'),
    ('workspace_tasks'), ('workspace_task_notes'),
    ('ozon_fbo_replenishment_runs'), ('ozon_fbo_supply_runs')
),
actual AS (
  SELECT c.relname, c.relrowsecurity
  FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE n.nspname='public' AND c.relkind IN ('r','p')
),
totals AS (
  SELECT count(*) AS table_count,
    count(*) FILTER (WHERE relrowsecurity) AS rls_count
  FROM actual
)
SELECT t.table_count, t.rls_count,
  (SELECT count(*) FROM required r
   WHERE to_regclass('public.' || r.name) IS NULL),
  (SELECT count(*) FROM auth.users),
  (SELECT count(*) FROM storage.buckets)
FROM totals t;
SQL
)" || blocked "Could not perform read-only PostgreSQL schema preflight"

IFS='|' read -r table_count rls_count missing_count auth_count bucket_count <<< "$stats"
for n in "$table_count" "$rls_count" "$missing_count" "$auth_count" "$bucket_count"; do
  [[ "$n" =~ ^[0-9]+$ ]] || blocked "Unexpected PostgreSQL preflight result"
done

echo "Public tables: $table_count; RLS-enabled: $rls_count; missing core tables: $missing_count; Auth users: $auth_count; Storage buckets: $bucket_count"

(( table_count > 0 )) || blocked "Business schema is absent; repository migrations are deltas, not a baseline"
(( missing_count == 0 )) || blocked "Core application tables are absent; import a protected full schema baseline"
(( rls_count == table_count )) || blocked "At least one public table lacks row-level security"
if [[ -n "$expected" && "$table_count" != "$expected" ]]; then
  blocked "Public table count differs from the freshly recorded source inventory"
fi
echo "PASS: preliminary business schema structure present (not full data/permissions parity)"
echo "NEXT: verify fingerprints, employees, private files and application flows before cutover"

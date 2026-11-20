#!/usr/bin/env bash
# Real PostgreSQL 17 transaction check using ONLY synthetic CI fixtures.
# Never touches cloud projects, production data or volumes.
set -Eeuo pipefail
umask 077
[[ "${GITHUB_ACTIONS:-}" == "true" && "${PANDA_CI_DISPOSABLE:-}" == "yes" ]] ||
  { echo "CI disposable test only" >&2; exit 78; }
[[ "$(id -u)" == "0" ]] || { echo "Requires root CI runner" >&2; exit 78; }

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
tmp="$(mktemp -d)"
db="panda-restore-smoke-$$"
cleanup() {
  docker rm -f -v "$db" >/dev/null 2>&1 || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

command -v docker >/dev/null || { echo "Docker missing" >&2; exit 1; }
command -v openssl >/dev/null || { echo "OpenSSL missing" >&2; exit 1; }
mkdir -m 700 "$tmp/dumps" "$tmp/bin"
password="$(openssl rand -hex 24)"
cat > "$tmp/pgservice.conf" <<CONF
[panda_test]
host=127.0.0.1
port=55432
dbname=postgres
user=postgres
passfile=$tmp/pgpass
CONF
printf '127.0.0.1:55432:postgres:postgres:%s\n' "$password" > "$tmp/pgpass"
chmod 600 "$tmp/pgservice.conf" "$tmp/pgpass"
cat > "$tmp/bin/psql" <<'WRAPPER'
#!/usr/bin/env bash
exec docker run --rm --network host --user 0 \
  --mount "type=bind,src=$PANDA_CI_RESTORE_TEMP,dst=$PANDA_CI_RESTORE_TEMP,readonly" \
  --env "PGSERVICEFILE=$PGSERVICEFILE" \
  --entrypoint psql postgres:17-alpine "$@"
WRAPPER
chmod 700 "$tmp/bin/psql"

cat > "$tmp/dumps/roles.sql" <<'SQL'
CREATE ROLE panda_ci_restore_role;
SQL
cat > "$tmp/dumps/schema.sql" <<'SQL'
CREATE TABLE public.panda_ci_restore_table (id integer PRIMARY KEY);
ALTER TABLE public.panda_ci_restore_table ENABLE ROW LEVEL SECURITY;
SQL
cat > "$tmp/dumps/data.sql" <<'SQL'
COPY auth.users (id) FROM stdin;
1
\.
SQL
chmod 600 "$tmp/dumps/"*.sql

docker run --detach --name "$db" \
  --publish 127.0.0.1:55432:5432 \
  --env "POSTGRES_PASSWORD=$password" \
  postgres:17-alpine >/dev/null
ready=no
for _ in $(seq 1 60); do
  if docker exec "$db" pg_isready -h 127.0.0.1 -p 5432 -U postgres -d postgres >/dev/null 2>&1; then
    ready=yes
    break
  fi
  sleep 1
done
[[ "$ready" == yes ]] || { echo "Disposable PostgreSQL never became ready" >&2; exit 1; }

docker exec -i "$db" psql -U postgres -d postgres -v ON_ERROR_STOP=1 >/dev/null <<'SQL'
CREATE ROLE anon; CREATE ROLE authenticated;
CREATE SCHEMA auth; CREATE TABLE auth.users (id bigint PRIMARY KEY);
CREATE SCHEMA storage; CREATE TABLE storage.objects (id bigint);
CREATE SCHEMA vault; CREATE TABLE vault.secrets (id bigint);
CREATE SCHEMA cron; CREATE TABLE cron.job (id bigint);
INSERT INTO cron.job(id) VALUES (1);
SQL

export PANDA_CI_RESTORE_TEMP="$tmp"
export PATH="$tmp/bin:$PATH"
export PGSERVICEFILE="$tmp/pgservice.conf"
export PANDA_TEST_DUMP_DIR="$tmp/dumps"
export PANDA_TARGET_PGSERVICE=panda_test
export PANDA_TARGET_DISPOSABLE=CONFIRMED_EMPTY_TEST_DATABASE
export PANDA_SCHEDULER_DISABLED=YES
export PANDA_EXPECT_AUTH_USERS=1

# Existing cron jobs must block restore before any SQL changes.
export PANDA_EXPECT_TABLES=2
cron_status=0
bash "$root/infra/migration/restore-platform-test.sh" > "$tmp/out" 2>"$tmp/err" || cron_status=$?
[[ "$cron_status" == 78 ]] || {
  echo "Nonempty cron jobs must block restore before import" >&2; exit 1;
}
docker exec "$db" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "DELETE FROM cron.job;" >/dev/null
echo "PASS: existing cron jobs block protected restore"

# Empty cron.job is allowed; a wrong postflight count must still roll back
# all changes. This uses real PostgreSQL, not a mocked SQL engine.
export PANDA_EXPECT_TABLES=2
if bash "$root/infra/migration/restore-platform-test.sh" > "$tmp/out" 2>"$tmp/err"; then
  echo "Incorrect table count unexpectedly committed" >&2
  exit 1
fi
query="SELECT (SELECT count(*) FROM pg_tables WHERE schemaname='public'),
              (SELECT count(*) FROM auth.users),
              (SELECT count(*) FROM pg_roles WHERE rolname='panda_ci_restore_role');"
state="$(docker exec "$db" psql -U postgres -d postgres -Atq -c "$query")"
[[ "$state" == "0|0|0" ]] || {
  echo "A rejected SQL import left partially committed data" >&2; exit 1;
}
private_failure_log="$(find "$tmp/dumps" -maxdepth 1 -type f -name '.restore-result.*' -print -quit)"
[[ -n "$private_failure_log" ]] ||
  { echo "Failed restore did not retain a private SQL error log" >&2; exit 1; }
if ! grep -q "Protected restore postflight mismatch" "$private_failure_log"; then
  echo "First rejected import did not reach its transactional postflight" >&2
  cat "$tmp/err" >&2
  exit 1
fi
echo "PASS: bad postflight rolled back roles, schema and synthetic user"

# The first SQL failure log is private. Remove it before testing success.
find "$tmp/dumps" -maxdepth 1 -type f -name '.restore-result.*' -delete
# Fresh self-hosted Supabase can omit pg_cron entirely. Prove the positive
# restore succeeds even when cron.job does not exist.
docker exec "$db" psql -U postgres -d postgres -v ON_ERROR_STOP=1 \
  -c "DROP TABLE cron.job;" >/dev/null
export PANDA_EXPECT_TABLES=1
if ! bash "$root/infra/migration/restore-platform-test.sh" > "$tmp/out" 2>"$tmp/err"; then
  echo "Synthetic approved restore failed" >&2
  cat "$tmp/err" >&2
  exit 1
fi
state="$(docker exec "$db" psql -U postgres -d postgres -Atq -c "$query")"
[[ "$state" == "1|1|1" ]] || {
  echo "Accepted SQL import did not contain all synthetic objects" >&2; exit 1;
}
echo "PASS: correct postflight committed roles, schema and synthetic user without cron.job"

# Never overwrite a restored target, even on a second identical invocation.
status=0
bash "$root/infra/migration/restore-platform-test.sh" > "$tmp/out" 2>"$tmp/err" || status=$?
[[ "$status" == 78 ]] || {
  echo "Duplicate restore did not fail closed" >&2; exit 1;
}
echo "PASS: repeated restore refused without touching existing data"

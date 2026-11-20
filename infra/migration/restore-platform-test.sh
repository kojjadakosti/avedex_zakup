#!/usr/bin/env bash
# Restore managed Supabase CLI dumps to a NEW empty local PostgreSQL 17.
# This script NEVER connects to a cloud source and never starts cron jobs.
set -Eeuo pipefail
umask 077
die() { echo "RESTORE BLOCKED: $*" >&2; exit 78; }
[[ "$(id -u)" == "0" ]] || die "Requires root on the isolated test machine"
[[ "${PANDA_TARGET_DISPOSABLE:-}" == "CONFIRMED_EMPTY_TEST_DATABASE" ]] ||
  die "Explicit approval of empty disposable target required"
[[ "${PANDA_SCHEDULER_DISABLED:-}" == "YES" ]] ||
  die "Background jobs and external writes must be disabled"
[[ "${PANDA_TEST_DUMP_DIR:-}" == /* && -d "$PANDA_TEST_DUMP_DIR" &&
   ! -L "$PANDA_TEST_DUMP_DIR" ]] || die "Absolute protected dump directory required"
[[ "$(stat -c %a "$PANDA_TEST_DUMP_DIR")" == "700" &&
   "$(stat -c %u "$PANDA_TEST_DUMP_DIR")" == "0" ]] ||
  die "Sensitive dump directory must be owned by root and mode 0700"
if git -C "$PANDA_TEST_DUMP_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  die "Sensitive source dump cannot be located inside a Git repository"
fi
[[ "${PGSERVICEFILE:-}" == /* && -s "$PGSERVICEFILE" && ! -L "$PGSERVICEFILE" ]] ||
  die "Provide local libpq service file, not a database URL with password"
[[ "$(stat -c %a "$PGSERVICEFILE")" == "600" ]] || die "PGSERVICEFILE requires mode 600"
[[ "${PANDA_TARGET_PGSERVICE:-}" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid local service name"
[[ "${PANDA_EXPECT_AUTH_USERS:-}" =~ ^[1-9][0-9]*$ ]] || die "Source staff count required"
[[ "${PANDA_EXPECT_TABLES:-}" =~ ^[1-9][0-9]*$ ]] || die "Source table count required"
for t in psql node grep stat git; do command -v "$t" >/dev/null || die "Missing $t"; done
for name in roles schema data; do
  [[ -s "$PANDA_TEST_DUMP_DIR/$name.sql" && -f "$PANDA_TEST_DUMP_DIR/$name.sql" &&
     ! -L "$PANDA_TEST_DUMP_DIR/$name.sql" ]] ||
    die "Missing or unsafe $name.sql"
  [[ "$(stat -c %u "$PANDA_TEST_DUMP_DIR/$name.sql")" == "0" &&
     "$(stat -c %a "$PANDA_TEST_DUMP_DIR/$name.sql")" == "600" ]] ||
    die "Private SQL dumps must be root-owned with mode 0600"
done
repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# SQL outside COPY is executable, but historical URLs inside COPY are data.
# Fail closed on malformed COPY framing or obsolete runnable SQL.
for name in roles schema data; do
  node "$repo_dir/scripts/restore-sql-safety-preflight.mjs" "$name" \
    "$PANDA_TEST_DUMP_DIR/$name.sql" >/dev/null ||
    die "Unsafe or malformed SQL dump: $name.sql"
done
node "$repo_dir/infra/migration/validate-pgservice.mjs" \
  "$PGSERVICEFILE" "$PANDA_TARGET_PGSERVICE" >/dev/null ||
  die "Privileged PostgreSQL connection is not safely restricted to localhost"
node "$repo_dir/scripts/storage-dump-preflight.mjs" "$PANDA_TEST_DUMP_DIR/data.sql" >/dev/null ||
  die "Unsafe data dump (Auth/Storage/Vault/cron guard failed)"

conn="service=$PANDA_TARGET_PGSERVICE"
psqltest() { psql -X -w -q -At -v ON_ERROR_STOP=1 -d "$conn" "$@"; }
before="$(psqltest -c "
SELECT current_setting('server_version_num')::integer/10000,
 (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON c.relnamespace=n.oid
  WHERE n.nspname='public' AND c.relkind IN('r','p')),
 (SELECT count(*) FROM auth.users),(SELECT count(*) FROM storage.objects),
 (SELECT count(*) FROM vault.secrets);")"
IFS='|' read -r major tables users objects secrets <<< "$before"
[[ "$major" == "17" &&
  "$tables" == "0" && "$users" == "0" && "$objects" == "0" &&
  "$secrets" == "0" ]] ||
  die "Refusing to modify nonempty/non-local/non-PG17 database"
# pg_cron is optional in a fresh self-hosted installation. If its job
# relation exists, insist on zero rows; if absent, there are no jobs to run.
# Use dynamic SQL: a static FROM cron.job would fail at parse time.
if ! psqltest -c "$(cat <<'SQL'
DO $panda_cron_guard$
DECLARE has_jobs boolean;
BEGIN
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM cron.job)' INTO has_jobs;
    IF has_jobs THEN
      RAISE EXCEPTION 'Refusing nonempty local cron jobs';
    END IF;
  END IF;
END
$panda_cron_guard$;
SQL
)" >/dev/null; then
  die "Refusing database with existing cron jobs"
fi
echo "CHECK: new private localhost PostgreSQL 17 target is empty"

# Concurrent runs of this script serialize via a transaction-scoped lock.
# Recheck the target after BEGIN to close the preflight/write race.
preflight_sql="$(cat <<'SQL'
SELECT pg_advisory_xact_lock(7180226, 1);
DO $panda_preflight$
DECLARE cron_has_jobs boolean;
BEGIN
  IF current_setting('server_version_num')::integer/10000 <> 17
    OR current_database() <> 'postgres'
    OR EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
               WHERE n.nspname='public' AND c.relkind IN ('r','p'))
    OR EXISTS (SELECT 1 FROM auth.users)
    OR EXISTS (SELECT 1 FROM storage.objects)
    OR EXISTS (SELECT 1 FROM vault.secrets) THEN
    RAISE EXCEPTION 'Protected restore preflight failed within transaction';
  END IF;
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE 'SELECT EXISTS (SELECT 1 FROM cron.job)' INTO cron_has_jobs;
    IF cron_has_jobs THEN
      RAISE EXCEPTION 'Protected restore preflight failed within transaction';
    END IF;
  END IF;
END
$panda_preflight$;
SQL
)"

# Expectations have already been checked as positive decimal integers.
# The validation must be part of the same transaction, BEFORE COMMIT.
postflight_sql="$(cat <<SQL
DO \$panda_postflight\$
DECLARE
  actual_tables bigint;
  actual_users bigint;
  actual_objects bigint;
  actual_cron bigint := 0;
  actual_vault bigint;
BEGIN
  SELECT count(*) INTO actual_tables FROM pg_class c JOIN pg_namespace n
    ON n.oid=c.relnamespace WHERE n.nspname='public' AND c.relkind IN ('r','p');
  SELECT count(*) INTO actual_users FROM auth.users;
  SELECT count(*) INTO actual_objects FROM storage.objects;
  IF to_regclass('cron.job') IS NOT NULL THEN
    EXECUTE 'SELECT count(*) FROM cron.job' INTO actual_cron;
  END IF;
  SELECT count(*) INTO actual_vault FROM vault.secrets;
  IF actual_tables <> ${PANDA_EXPECT_TABLES}
     OR actual_users <> ${PANDA_EXPECT_AUTH_USERS}
     OR actual_objects <> 0 OR actual_cron <> 0 OR actual_vault <> 0 THEN
    RAISE EXCEPTION 'Protected restore postflight mismatch; transaction will roll back';
  END IF;
END
\$panda_postflight\$;
SQL
)"

# PostgreSQL errors can include SQL source rows. Keep their diagnostics
# inside a root-only file rather than emitting sensitive lines in CI output.
private_log="$(mktemp "$PANDA_TEST_DUMP_DIR/.restore-result.XXXXXXXX")"
chmod 600 "$private_log"
if ! psql -X -w -q --single-transaction --set ON_ERROR_STOP=1 \
 --dbname "$conn" \
 --command "$preflight_sql" \
 --file "$PANDA_TEST_DUMP_DIR/roles.sql" \
 --command 'ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon, authenticated;' \
 --file "$PANDA_TEST_DUMP_DIR/schema.sql" \
 --command 'SET session_replication_role = replica;' \
 --file "$PANDA_TEST_DUMP_DIR/data.sql" \
 --command 'SET session_replication_role = origin;' \
 --command "$postflight_sql" >"$private_log" 2>&1; then
  echo "RESTORE FAILED: transaction rolled back; inspect private root-only log: $private_log" >&2
  exit 1
fi
rm -f -- "$private_log"
echo "PASS: roles, schema, staff and empty Storage/Vault/cron verified before COMMIT"
echo "STOP: private files, external integration keys and application parity remain unverified"

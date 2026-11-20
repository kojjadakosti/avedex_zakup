#!/usr/bin/env bash
# Unit tests for RESTORE fail-closed controls. Uses fake psql/rclone ONLY.
# Never connects to any database and never copies any real file.
set -Eeuo pipefail
[[ "${GITHUB_ACTIONS:-}" == "true" ]] || { echo "CI-only guard test"; exit 78; }
[[ "$(id -u)" == "0" ]] || { echo "Guard tests require root in CI"; exit 78; }
repo="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
mkdir -p "$temp/bin" "$temp/dumps"
chmod 700 "$temp/dumps"
printf 'SELECT 1;\n' > "$temp/dumps/roles.sql"
printf 'CREATE TABLE public.example(id integer);\n' > "$temp/dumps/schema.sql"
printf 'COPY auth.users (id) FROM stdin;\n1\n\\.\nCOPY public.example (notes) FROM stdin;\nhttps://old.vercel.app/archived\n\\.\n' > "$temp/dumps/data.sql"
chmod 600 "$temp/dumps/"{roles,schema,data}.sql
cat > "$temp/pgservice.conf" <<SERVICE
[panda_test]
host=127.0.0.1
port=5432
dbname=postgres
user=postgres
passfile=$temp/pgpass
SERVICE
printf '127.0.0.1:5432:postgres:postgres:synthetic\n' > "$temp/pgpass"
chmod 600 "$temp/pgservice.conf" "$temp/pgpass"
export PGSERVICEFILE="$temp/pgservice.conf"
export PANDA_TEST_DUMP_DIR="$temp/dumps"
export PANDA_TARGET_PGSERVICE=panda_test
export PANDA_SCHEDULER_DISABLED=YES
export PANDA_EXPECT_AUTH_USERS=3
export PANDA_EXPECT_TABLES=123

# fake psql strictly records calls, never opens a network socket
cat > "$temp/bin/psql" <<'MOCK'
#!/usr/bin/env bash
set -e
printf '%s\n' "psql" >> "$PANDA_TEST_CALL_LOG"
if [[ "$*" == *"--single-transaction"* ]]; then
  [[ "$*" == *"pg_advisory_xact_lock"* &&
     "$*" == *"Protected restore postflight mismatch"* &&
     "$*" == *"SET session_replication_role = origin"* ]] || exit 43
  if [[ "${PANDA_TEST_FAIL_RESTORE:-}" == "YES" ]]; then
    printf 'PRIVATE_MOCK_ERROR_ROW_SHOULD_NEVER_BE_PUBLIC\n' >&2
    exit 3
  fi
  touch "$PANDA_TEST_RESTORED"
else
  printf '17|0|0|0|0\n'
fi
MOCK
chmod 700 "$temp/bin/psql"
export PATH="$temp/bin:$PATH"
export PANDA_TEST_CALL_LOG="$temp/calls"
export PANDA_TEST_RESTORED="$temp/did-restore"

assert_blocked() {
  rm -f "$PANDA_TEST_RESTORED" "$PANDA_TEST_CALL_LOG"
  local status=0
  bash "$repo/infra/migration/restore-platform-test.sh" >"$temp/out" 2>"$temp/err" || status=$?
  [[ "$status" -eq 78 ]] || {
    echo "Expected safe restore refusal (78); got $status" >&2; exit 1;
  }
  [[ ! -e "$PANDA_TEST_RESTORED" ]] || {
    echo "Blocked restore still wrote to DB" >&2; exit 1;
  }
}

unset PANDA_TARGET_DISPOSABLE
assert_blocked
export PANDA_TARGET_DISPOSABLE=CONFIRMED_EMPTY_TEST_DATABASE
sed -i 's/host=127.0.0.1/host=203.0.113.5/' "$temp/pgservice.conf"
assert_blocked
sed -i 's/host=203.0.113.5/host=127.0.0.1/' "$temp/pgservice.conf"
chmod 644 "$temp/dumps/schema.sql"
assert_blocked
chmod 600 "$temp/dumps/schema.sql"
printf 'SELECT cron.schedule(1,2,3);\n' >> "$temp/dumps/schema.sql"
assert_blocked
printf 'CREATE TABLE public.example(id integer);\n' > "$temp/dumps/schema.sql"
printf 'SELECT cron.schedule(1,2,3);\n' >> "$temp/dumps/data.sql"
assert_blocked
printf 'COPY auth.users (id) FROM stdin;\n1\n\\.\nCOPY public.example (notes) FROM stdin;\nhttps://old.vercel.app/archived\n\\.\n' > "$temp/dumps/data.sql"
printf "SELECT 'https://old.vercel.app';\n" >> "$temp/dumps/data.sql"
assert_blocked
printf 'COPY auth.users (id) FROM stdin;\n1\n\\.\nCOPY public.example (notes) FROM stdin;\nhttps://old.vercel.app/archived\n\\.\n' > "$temp/dumps/data.sql"
export PANDA_TARGET_PGSERVICE=invalid/target
assert_blocked
export PANDA_TARGET_PGSERVICE=panda_test

rm -f "$PANDA_TEST_RESTORED" "$PANDA_TEST_CALL_LOG"
export PANDA_TEST_FAIL_RESTORE=YES
status=0
bash "$repo/infra/migration/restore-platform-test.sh" >"$temp/out" 2>"$temp/err" || status=$?
[[ "$status" -eq 1 && ! -e "$PANDA_TEST_RESTORED" ]] ||
  { echo "Failing SQL restore must abort" >&2; exit 1; }
! grep -q PRIVATE_MOCK_ERROR_ROW_SHOULD_NEVER_BE_PUBLIC "$temp/out" "$temp/err" ||
  { echo "SQL error details leaked to shared output" >&2; exit 1; }
private_log="$(find "$temp/dumps" -maxdepth 1 -type f -name '.restore-result.*' -print -quit)"
[[ -n "$private_log" && "$(stat -c %a "$private_log")" == "600" ]] ||
  { echo "Protected SQL error log missing" >&2; exit 1; }
grep -q PRIVATE_MOCK_ERROR_ROW_SHOULD_NEVER_BE_PUBLIC "$private_log" ||
  { echo "Expected error missing from private SQL log" >&2; exit 1; }
rm -f "$private_log"
unset PANDA_TEST_FAIL_RESTORE

rm -f "$PANDA_TEST_RESTORED" "$PANDA_TEST_CALL_LOG"
bash "$repo/infra/migration/restore-platform-test.sh" >"$temp/out" 2>"$temp/err"
[[ -f "$PANDA_TEST_RESTORED" ]] || { echo "Safe mocked restore was not invoked" >&2; exit 1; }
[[ -z "$(find "$temp/dumps" -maxdepth 1 -type f -name '.restore-result.*' -print -quit)" ]] ||
  { echo "Successful restore must not retain temporary SQL logs" >&2; exit 1; }
echo "PASS: guarded restore checks target, verifies counts before COMMIT and protects SQL errors"

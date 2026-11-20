#!/usr/bin/env bash
# One command for fresh or existing local infrastructure, with fail-closed state.
# Never overwrites generated keys, restores data or enables background jobs.
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$ROOT"
die() { echo "LOCAL START BLOCKED: $*" >&2; exit 78; }

mode=start
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  *) echo "Usage: bash infra/local/start.sh [--check]" >&2; exit 64 ;;
esac
(( $# <= 1 )) || { echo "Usage: bash infra/local/start.sh [--check]" >&2; exit 64; }

for cmd in bash docker stat grep sed; do
  command -v "$cmd" >/dev/null 2>&1 || die "Missing dependency: $cmd"
done
[[ "${COMPOSE_PROFILES:-}" == "" ]] ||
  die "COMPOSE_PROFILES must be unset; the restore profile is manual only"
[[ "${PANDA_BIND_ADDRESS:-127.0.0.1}" == "127.0.0.1" ]] ||
  die "The local proxy must bind only to 127.0.0.1"
[[ "${SCHEDULER_ENABLED:-false}" == "false" ]] ||
  die "Background scheduler must remain disabled"

if [[ "$mode" == start ]]; then
  command -v flock >/dev/null 2>&1 || die "Missing dependency: flock"
  # The lock prevents two parallel first-start commands from generating
  # incompatible keys or racing during Docker project initialization.
  exec 9>"$ROOT/.panda-local.lock"
  flock -n 9 || die "Another local startup is already in progress"
fi

ENV_FILE="$ROOT/.env.docker"
UPSTREAM="$ROOT/.panda-local/supabase"
SECRETS="$ROOT/.panda-local/secrets"

exists() { [[ -e "$1" || -L "$1" ]]; }
if ! exists "$ENV_FILE" && ! exists "$UPSTREAM" && ! exists "$SECRETS"; then
  [[ "$mode" == start ]] || die "Local stack has not been initialized"
  echo "First local installation: generating isolated Supabase credentials"
  bash "$ROOT/infra/local/init.sh"
elif exists "$ENV_FILE" && exists "$UPSTREAM" && exists "$SECRETS"; then
  : # Existing configuration; never regenerate keys.
else
  die "Partial initialization detected; inspect .panda-local privately. Never regenerate keys blindly"
fi

secure_file() {
  local path="$1" mode_required="$2"
  [[ -f "$path" && ! -L "$path" && -s "$path" ]] ||
    die "Missing or unsafe local configuration/secret file"
  [[ "$(stat -c %a "$path")" == "$mode_required" ]] ||
    die "Incorrect permissions on local configuration/secret file"
}
read_env() {
  local path="$1" key="$2" count
  count="$(grep -c "^$key=" "$path" || true)"
  [[ "$count" == 1 ]] || die "Missing or duplicated key in local configuration"
  sed -n "s/^$key=//p" "$path"
}

secure_file "$ENV_FILE" 600
secure_file "$UPSTREAM/.env" 600
secure_file "$SECRETS/supabase-secret-key" 640
secure_file "$SECRETS/cron-secret" 640

[[ "$(read_env "$ENV_FILE" PANDA_SECRETS_DIR)" == "$SECRETS" ]] ||
  die "Secret directory differs from initial setup"
[[ "$(read_env "$ENV_FILE" SCHEDULER_ENABLED)" == false ]] ||
  die "Scheduler must not run before migration cutover"
[[ "$(read_env "$UPSTREAM/.env" DISABLE_SIGNUP)" == true ]] ||
  die "Self-registration must stay disabled"
[[ "$(read_env "$ENV_FILE" NEXT_PUBLIC_SUPABASE_URL)" ==    "$(read_env "$UPSTREAM/.env" SUPABASE_PUBLIC_URL)" ]] ||
  die "Browser and Supabase public URLs do not match"

[[ "${PANDA_SECRETS_DIR:-$SECRETS}" == "$SECRETS" ]] ||
  die "PANDA_SECRETS_DIR environment override would change the secret mount"
docker info >/dev/null 2>&1 || die "Docker daemon is unavailable"

if [[ "$mode" == check ]]; then
  docker compose -f compose.local.yaml --env-file .env.docker config --quiet ||
    die "Invalid combined Compose configuration"
  echo "PASS: local credentials, safe Compose configuration and Docker access"
  exit 0
fi

docker network inspect panda_shared >/dev/null 2>&1 ||
  docker network create panda_shared >/dev/null ||
  die "Could not create required private Docker network"
docker compose -f compose.local.yaml --env-file .env.docker config --quiet ||
  die "Invalid combined Compose configuration"

echo "Starting local infrastructure (application data are restored separately)"
exec docker compose -f compose.local.yaml --env-file .env.docker up -d --build --wait

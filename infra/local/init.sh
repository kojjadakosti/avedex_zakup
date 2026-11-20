#!/usr/bin/env bash
# One-time, fail-closed local setup. It never starts containers or restores data.
set -Eeuo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
for bin in docker git openssl sed grep mktemp; do
  command -v "$bin" >/dev/null || { echo "Missing required command: $bin" >&2; exit 1; }
done
docker compose version >/dev/null
# The official upstream overlay uses Compose !override (>=2.24.4).
docker compose version --short | awk -F. '{ if ($1 < 2 || ($1 == 2 && ($2 < 24 || ($2 == 24 && $3 < 4)))) exit 1 }' || {
  echo "Docker Compose 2.24.4 or newer is required" >&2; exit 1;
}

PUBLIC_ORIGIN="${PANDA_PUBLIC_ORIGIN:-http://localhost:8080}"
# HTTP is intentionally permitted only for loopback development.
case "$PUBLIC_ORIGIN" in
  http://localhost:*|http://127.0.0.1:*|https://*) ;;
  *) echo "Use a loopback HTTP URL or an HTTPS URL for PANDA_PUBLIC_ORIGIN" >&2; exit 1 ;;
esac
case "$PUBLIC_ORIGIN" in */) PUBLIC_ORIGIN="${PUBLIC_ORIGIN%/}";; esac

UPSTREAM="$ROOT/.panda-local/supabase"
SECRETS="$ROOT/.panda-local/secrets"
if [[ -e "$ROOT/.env.docker" || -e "$UPSTREAM" || -e "$SECRETS" ]]; then
  echo "Existing local state found; refusing to overwrite keys, data or configuration." >&2
  echo "For an existing installation, use docker compose -f compose.local.yaml --env-file .env.docker up -d --build" >&2
  exit 1
fi

bash "$ROOT/infra/supabase/prepare.sh" "$UPSTREAM"
cleanup() {
  # Preserve partial state for inspection; never delete generated credentials.
  echo "Initialization interrupted. Inspect .panda-local privately before retrying." >&2
}
trap cleanup ERR
(
  cd "$UPSTREAM"
  sh utils/generate-keys.sh --update-env >/dev/null
  sh utils/add-new-auth-keys.sh --update-env >/dev/null
  rm -f .env.old docker-compose.yml.old
  sed -i "s|^SUPABASE_PUBLIC_URL=.*|SUPABASE_PUBLIC_URL=$PUBLIC_ORIGIN|" .env
  sed -i "s|^API_EXTERNAL_URL=.*|API_EXTERNAL_URL=$PUBLIC_ORIGIN/auth/v1|" .env
  sed -i "s|^SITE_URL=.*|SITE_URL=$PUBLIC_ORIGIN|" .env
  sed -i 's|^DISABLE_SIGNUP=.*|DISABLE_SIGNUP=true|' .env
  sed -i 's|^ENABLE_PHONE_SIGNUP=.*|ENABLE_PHONE_SIGNUP=false|' .env
  chmod 600 .env
)
mkdir -p "$SECRETS"
chmod 750 "$SECRETS"
publishable="$(sed -n 's/^SUPABASE_PUBLISHABLE_KEY=//p' "$UPSTREAM/.env" | tail -1)"
secret="$(sed -n 's/^SUPABASE_SECRET_KEY=//p' "$UPSTREAM/.env" | tail -1)"
[[ -n "$publishable" && -n "$secret" ]] || { echo "Upstream key generation failed" >&2; exit 1; }
printf '%s\n' "$secret" > "$SECRETS/supabase-secret-key"
openssl rand -hex 32 > "$SECRETS/cron-secret"
# Compose file-based secrets keep host ownership and permissions (no UID remap).
# The Next.js runtime runs as UID/GID 1000; grant it read-only access.
if [[ "$(id -u)" != 1000 ]]; then
  chgrp 1000 "$SECRETS" "$SECRETS/supabase-secret-key" "$SECRETS/cron-secret" || {
    echo "Unable to grant container GID 1000 access to secret files" >&2; exit 1;
  }
fi
chmod 640 "$SECRETS/"*
cat > "$ROOT/.env.docker" <<EOF
NEXT_PUBLIC_SUPABASE_URL=$PUBLIC_ORIGIN
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY=$publishable
PANDA_SECRETS_DIR=$SECRETS
SCHEDULER_ENABLED=false
EOF
chmod 600 "$ROOT/.env.docker"
# The official stack and app use the same privately named Docker network.
docker network inspect panda_shared >/dev/null 2>&1 || docker network create panda_shared >/dev/null
docker compose -f compose.local.yaml --env-file .env.docker config --quiet
trap - ERR
echo "Local configuration prepared. No containers were started."
echo "Run: docker compose -f compose.local.yaml --env-file .env.docker up -d --build"
echo "Open $PUBLIC_ORIGIN/login"
echo "NOTE: The database is empty. Application schema/data must be restored separately."

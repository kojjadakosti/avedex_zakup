#!/usr/bin/env bash
# Prepare a pinned official Supabase self-hosted stack; DO NOT start it.
set -Eeuo pipefail
IFS=$'\n\t'
readonly UPSTREAM_REF="self-hosted/v0.8.4"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly DESTINATION="${1:-$PWD/.panda-local/supabase}"

for tool in git cp mktemp sed; do
  command -v "$tool" >/dev/null 2>&1 || { echo "Missing dependency: $tool" >&2; exit 1; }
done
if [[ -e "$DESTINATION" ]]; then
  echo "Destination already exists; refusing to overwrite: $DESTINATION" >&2
  exit 1
fi

temp_dir="$(mktemp -d)"
trap 'rm -rf "$temp_dir"' EXIT
# Keep the temporary checkout private (mktemp -d is 0700), while
# checkout files mounted into containers need to be readable by non-root UIDs.
# Do not relax the umask for generated .env or any credentials.
(
  umask 022
  git clone --filter=blob:none --no-checkout --depth=1 --quiet \
    --branch "$UPSTREAM_REF" https://github.com/supabase/supabase "$temp_dir/upstream"
  git -C "$temp_dir/upstream" sparse-checkout init --cone
  git -C "$temp_dir/upstream" sparse-checkout set docker
  git -C "$temp_dir/upstream" checkout --quiet
)

mkdir -p "$DESTINATION"
cp -a "$temp_dir/upstream/docker/." "$DESTINATION/"
cp "$SCRIPT_DIR/docker-compose.panda.yml" "$DESTINATION/docker-compose.panda.yml"
cp "$DESTINATION/.env.example" "$DESTINATION/.env"
chmod 600 "$DESTINATION/.env"
printf 'ref=%s\n' "$UPSTREAM_REF" > "$DESTINATION/.supabase-version"

# Compose sees all the upstream components while the overlay binds
# externally reachable services only to 127.0.0.1.
sed -i 's|^COMPOSE_FILE=.*|COMPOSE_FILE=docker-compose.yml:docker-compose.panda.yml|' "$DESTINATION/.env"

echo "Prepared official Supabase $UPSTREAM_REF at $DESTINATION"
echo "No containers started. Configuration contains UNSECURE PLACEHOLDERS."
echo "Generate keys, set URLs, verify Compose version and security before startup."

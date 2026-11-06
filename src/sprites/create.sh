#!/usr/bin/env bash
# Recipe `create` phase (Orca-server mode). Builds a new Sprite, starts
# `orca serve` as a Sprite service and prints one recipe-result JSON object.
set -euo pipefail
. "$(dirname "$0")/lib.sh"  # inlined by scripts/build.mjs

# Sprite names are at most 55 characters, and Orca's ORCA_VM_INSTANCE_ID is a UUID, so the
# name carries a 12-character hash of the instance id rather than the id itself.
ensure_org
resolve_repo
recipe_id="$(sanitize_name "${ORCA_RECIPE_ID:-sprites}")"
instance_hash="$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(process.argv[1]).digest("hex").slice(0, 12))' "${ORCA_VM_INSTANCE_ID:-$(date +%s)-$RANDOM}")"
max=$((55 - ${#instance_hash} - 1))
name="$(sanitize_name "$(printf '%s' "$name_prefix-$recipe_id" | cut -c1-"$max")-$instance_hash")"
[ "${#name}" -le 55 ] || die "Sprite name too long: $name"

new_sprite "$name"
# Armed only once this script has created the Sprite, so cleanup never touches one it did not make.
ok=0
cleanup() {
  [ "$ok" = 1 ] && return 0
  log "create failed; destroying $name"
  destroy_sprite "$name" || true
}
trap cleanup EXIT

build_sprite "$name"
recipe_json="$(serve_sprite "$name")"
emit_result "$recipe_json" "$name"
ok=1

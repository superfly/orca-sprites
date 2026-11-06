#!/usr/bin/env bash
# Orca recipe `create` for Sprites (Orca-server mode). Builds a new Sprite, starts
# `orca serve` as a Sprite service and prints one recipe-result JSON object.
set -euo pipefail
. "$(dirname "$0")/sprites-lib.sh"

recipe_id="$(sanitize_name "${ORCA_RECIPE_ID:-sprites}")"
instance_id="$(sanitize_name "${ORCA_VM_INSTANCE_ID:-$(date +%s)-$RANDOM}")"
max=$((63 - ${#name_prefix} - ${#instance_id} - 2))
[ "$max" -gt 0 ] || die "ORCA_VM_INSTANCE_ID is too long for a Sprite name"
name="$(sanitize_name "$name_prefix-${recipe_id:0:max}-$instance_id")"

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

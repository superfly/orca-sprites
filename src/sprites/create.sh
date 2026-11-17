#!/usr/bin/env bash
# Recipe `create` phase (Orca-server mode). Builds a new Sprite, starts
# `orca serve` as a Sprite service and prints one recipe-result JSON object.
set -euo pipefail
. "$(dirname "$0")/lib.sh"  # inlined by scripts/build.mjs

create_started="$(date +%s)"
check_create_settings
ensure_org
resolve_repo
name="$(sprite_name_for "${ORCA_VM_INSTANCE_ID:-$(date +%s)-$RANDOM}")"

name_is_free "$name"
# Armed before `sprite create`, which can fail after the Sprite exists. The name was free a
# moment ago, so any Sprite with it is ours; destroy_sprite tolerates "not found". On cancel,
# Orca stops this process group and kills it 5 s later, so cleanup may not finish; find
# leftovers with: sprite list --prefix orca-
ok=0
cleanup() {
  [ "$ok" = 1 ] && return 0
  log "create failed; destroying $name"
  destroy_sprite "$name" || true
}
trap cleanup EXIT
new_sprite "$name"
# Record it now, with this instance id, so destroy can find it even if create never returns.
record_sprite "$name" "" created

build_sprite "$name"
recipe_json="$(serve_sprite "$name")"
emit_result "$recipe_json" "$name"
ok=1

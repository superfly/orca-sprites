#!/usr/bin/env bash
# Recipe `create` phase (Orca-server mode). Builds a new Sprite, starts
# `orca serve` as a Sprite service and prints one recipe-result JSON object.
set -euo pipefail
. "$(dirname "$0")/lib.sh"  # inlined by scripts/build.mjs

# Sprite names are at most 55 characters, and Orca's ORCA_VM_INSTANCE_ID is a UUID, so the
# name carries a 12-character hash of the instance id rather than the id itself.
create_started="$(date +%s)"
ensure_org
resolve_repo
recipe_id="$(sanitize_name "${ORCA_RECIPE_ID:-sprites}")"
instance_hash="$(node -e 'process.stdout.write(require("node:crypto").createHash("sha256").update(process.argv[1]).digest("hex").slice(0, 12))' "${ORCA_VM_INSTANCE_ID:-$(date +%s)-$RANDOM}")"
max=$((55 - ${#instance_hash} - 1))
name="$(sanitize_name "$(printf '%s' "$name_prefix-$recipe_id" | cut -c1-"$max")-$instance_hash")"
[ "${#name}" -le 55 ] || die "Sprite name too long: $name"

name_is_free "$name"
# Armed before `sprite create`, which can fail after the Sprite exists. The name was free a
# moment ago, so any Sprite with it is ours; destroy_sprite tolerates "not found". On cancel,
# Orca stops this process group and kills it 5 s later, so cleanup may not finish; find
# leftovers with: sprite list --prefix orca-
ok=0
cleanup() {
  [ -z "$checkout_tmp" ] || rm -rf "$checkout_tmp"
  [ "$ok" = 1 ] && return 0
  log "create failed; destroying $name"
  destroy_sprite "$name" || true
}
trap cleanup EXIT
new_sprite "$name"

build_sprite "$name"
recipe_json="$(serve_sprite "$name")"
emit_result "$recipe_json" "$name"
ok=1

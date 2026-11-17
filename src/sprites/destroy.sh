#!/usr/bin/env bash
# Orca recipe `destroy` for Sprites. Destroys the Sprite; succeeds if it is already gone.
set -euo pipefail
. "$(dirname "$0")/lib.sh"  # inlined by scripts/build.mjs
payload="$(cat)"
name="$(payload_value "$payload" resourceId)"
use_payload_org "$payload"
if [ -z "$name" ]; then
  # No recipe result: create failed, timed out or Orca quit before it returned, and Orca kept
  # the VM listed so it can be removed. Find the Sprite by the name create gives this instance.
  instance_id="$(payload_top "$payload" instanceId)"; instance_id="${instance_id:-${ORCA_VM_INSTANCE_ID:-}}"
  [ -n "$instance_id" ] || die "the lifecycle payload has neither userData.resourceId nor an instance id, so there is no way to tell which Sprite to destroy"
  name="$(sprite_name_for "$instance_id" "$(payload_top "$payload" recipeId)")"
  log "create never returned a result for this VM; destroying the Sprite create names after it: $name in $org"
  log "if the Sprite was made with another SPRITES_NAME_PREFIX or organization, look there for a name that ends in -${name##*-}"
fi
destroy_sprite "$name"
printf '{"ok":true}\n'

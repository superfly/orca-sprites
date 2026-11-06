#!/usr/bin/env bash
# Orca recipe `resume` for Sprites. Wakes the Sprite, starts the orca service again and
# prints the recipe JSON. The URL and the pairing identity do not change.
set -euo pipefail
. "$(dirname "$0")/sprites-lib.sh"
payload="$(cat)"
name="$(payload_value "$payload" resourceId)"
[ -n "$name" ] || die "no userData.resourceId in the lifecycle payload"
use_payload_org "$payload"
url="$(sprite_url "$name")"; [ -n "$url" ] || die "Sprite $name no longer exists"
recipe_json="$(rexec "$name" --env "$(remote_env "$url")" -- bash -lc "$remote_resume")"
emit_result "$recipe_json" "$name"

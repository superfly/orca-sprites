#!/usr/bin/env bash
# Orca recipe `destroy` for Sprites. Destroys the Sprite; succeeds if it is already gone.
set -euo pipefail
. "$(dirname "$0")/sprites-lib.sh"
payload="$(cat)"
name="$(payload_value "$payload" resourceId)"
[ -n "$name" ] || die "no userData.resourceId in the lifecycle payload"
use_payload_org "$payload"
destroy_sprite "$name"
printf '{"ok":true}\n'

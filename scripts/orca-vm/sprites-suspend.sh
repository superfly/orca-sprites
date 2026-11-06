#!/usr/bin/env bash
# Orca recipe `suspend` for Sprites. Stops orca serve so no connection keeps the Sprite
# awake; the Sprite then sleeps on its own and costs nothing for compute.
set -euo pipefail
. "$(dirname "$0")/sprites-lib.sh"
payload="$(cat)"
name="$(payload_value "$payload" resourceId)"
[ -n "$name" ] || die "no userData.resourceId in the lifecycle payload"
rexec "$name" -- sprite-env services stop "$service_name" >&2
log "stopped orca serve on $name; the Sprite sleeps when idle"
printf '{"ok":true}\n'

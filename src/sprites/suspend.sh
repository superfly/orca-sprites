#!/usr/bin/env bash
# Orca recipe `suspend` for Sprites. Stops orca serve and the keep-awake service, and drops
# any keep-awake lease, so the Sprite sleeps on its own and costs nothing for compute.
set -euo pipefail
. "$(dirname "$0")/lib.sh"  # inlined by scripts/build.mjs
payload="$(cat)"
name="$(payload_value "$payload" resourceId)"
[ -n "$name" ] || die "no userData.resourceId in the lifecycle payload"
use_payload_org "$payload"
rexec "$name" --env "SERVICE=$service_name" -- bash -lc 'sprite-env services stop "$SERVICE-awake" >/dev/null 2>&1 || true
sprite-env keep-awake --release >/dev/null 2>&1 || true
sprite-env services stop "$SERVICE"' >&2
log "stopped orca serve on $name; the Sprite sleeps when idle"
printf '{"ok":true}\n'

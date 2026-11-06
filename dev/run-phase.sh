#!/usr/bin/env bash
# run-phase.sh <create|suspend|resume|destroy> [repo-dir]
# Runs one phase of recipes/sprites.json the way Orca does: `sh -c <command>` in the repo's
# root, with Orca's ORCA_* variables, the lifecycle payload on stdin and the JSON on stdout.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
phase="${1:?phase}"; repo="$(cd "${2:-$PWD}" && pwd)"
cmd="$(node -e 'const r=require(process.argv[1]); const c=r[process.argv[2]]; if(!c) process.exit(2); process.stdout.write(c)' "$here/recipes/sprites.json" "$phase")"
cd "$repo"
export ORCA_VM_MODE="$phase" ORCA_RECIPE_ID=sprites ORCA_REPO_PATH="$repo" \
  ORCA_VM_INSTANCE_ID="${ORCA_VM_INSTANCE_ID:-orca-$(node -e 'process.stdout.write(require("node:crypto").randomUUID())')}" \
  ORCA_REPO_REF="${ORCA_REPO_REF:-origin/$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##' || echo main)}" \
  ORCA_VERSION="${ORCA_VERSION:-1.4.246}" ORCA_RECIPE_RESULT_SCHEMA_VERSION=1
exec /bin/sh -c "$cmd"

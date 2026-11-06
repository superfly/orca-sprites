# shellcheck shell=bash
# Shared helpers for the Sprites recipe scripts. Sourced, not executed.
#
# Every script keeps stdout for its one JSON result. Everything else goes to stderr.

orca_vm_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state_file="${ORCA_SPRITES_STATE:-$orca_vm_dir/sprites-state.json}"

log() { printf '[sprites] %s\n' "$*" >&2; }
die() { printf '[sprites] error: %s\n' "$*" >&2; exit 1; }

command -v sprite >/dev/null 2>&1 || die "the sprite CLI is not on PATH (install: curl -fsSL https://sprites.dev/install.sh | bash)"
command -v node >/dev/null 2>&1 || die "node is not on PATH; the recipe scripts use it to read and write JSON"

# json_value <key> [fallback]: a top-level value from the state file.
json_value() {
  node -e '
    const fs = require("node:fs");
    let s = {};
    try { s = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); } catch {}
    const v = s[process.argv[2]];
    process.stdout.write(v === undefined || v === null || v === "" ? (process.argv[3] ?? "") : String(v));
  ' "$state_file" "$1" "${2:-}"
}

# setting <ENV_NAME> <stateKey> [fallback]: env var, then state, then fallback.
setting() {
  local env_name="$1" key="$2" fallback="${3:-}"
  if [ -n "${!env_name:-}" ]; then printf '%s' "${!env_name}"; else json_value "$key" "$fallback"; fi
}

org="$(setting ORCA_SPRITES_ORG org)"
repo_url="$(setting ORCA_REPO_URL repoUrl)"
repo_ref="$(setting ORCA_REPO_REF repoRef main)"
project_root="$(setting ORCA_PROJECT_ROOT projectRoot /home/sprite/project)"
orca_version="$(setting ORCA_SPRITES_ORCA_VERSION orcaVersion 1.4.246)"
name_prefix="$(setting ORCA_SPRITES_PREFIX namePrefix orca)"
# The Sprite URL routes to port 8080.
port=8080
service_name="orca"
recipe_file="/home/sprite/.orca-recipe.json"
agent_env_file="/home/sprite/.orca-agent.env"

[ -n "$org" ] || die "no Sprites org: set ORCA_SPRITES_ORG or \"org\" in $state_file"
[ -n "$repo_url" ] || die "no repository: set ORCA_REPO_URL or \"repoUrl\" in $state_file"
case "$project_root" in /*) ;; *) die "projectRoot must be an absolute path on the Sprite: $project_root" ;; esac

sp() { sprite -o "$org" "$@"; }

# rexec <sprite> [--env K=V,...] -- <cmd...>: run on the Sprite. Returns the remote exit code.
rexec() { local name="$1"; shift; sp exec -s "$name" --no-stdin "$@"; }

# Git token for private repositories. Never written into state or JSON.
git_token() {
  if [ -n "${GH_TOKEN:-}" ]; then printf '%s' "$GH_TOKEN"
  elif [ -n "${GITHUB_TOKEN:-}" ]; then printf '%s' "$GITHUB_TOKEN"
  elif command -v gh >/dev/null 2>&1; then gh auth token 2>/dev/null || true
  fi
}

# Sprite names: lowercase letters, digits and hyphens.
sanitize_name() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-//; s/-$//'
}

sprite_url() {
  sp --json list --prefix "$1" | node -e '
    let d = ""; process.stdin.on("data", c => d += c).on("end", () => {
      const s = (JSON.parse(d).sprites || []).find(x => x.name === process.argv[1]);
      process.stdout.write(s?.url ?? "");
    });' "$1"
}

destroy_sprite() {
  local name="$1"
  if [ -n "$(sprite_url "$name")" ]; then sp destroy --force "$name" >&2; else log "$name is already gone"; fi
}

# Remote fragments run under `bash -lc` on the Sprite. They never call `exit`: in a login
# shell with `set -e`, `exit` runs ~/.bash_logout, whose clear_console fails without a TTY
# and turns every exit status into 1. They end on the status of their last command.

remote_askpass='if [ -n "${GH_TOKEN:-}" ]; then
  printf "%s\n" "#!/usr/bin/env bash" "case \"\$1\" in *Username*) echo x-access-token;; *Password*) echo \"\$GH_TOKEN\";; esac" > /tmp/orca-askpass.sh
  chmod 700 /tmp/orca-askpass.sh; export GIT_ASKPASS=/tmp/orca-askpass.sh
fi'

# Installs Orca and checks out the repository.
remote_build='set -euo pipefail
export DEBIAN_FRONTEND=noninteractive GIT_TERMINAL_PROMPT=0
echo "installing orca-ide $ORCA_VERSION" >&2
curl -fsSL -o /tmp/orca.deb "https://github.com/stablyai/orca/releases/download/v$ORCA_VERSION/orca-ide_${ORCA_VERSION}_amd64.deb"
# Without the update, libgtk-3-0 does not resolve on the Sprite image.
sudo apt-get update -qq >/tmp/orca-apt.log 2>&1
sudo -E apt-get install -y -qq /tmp/orca.deb >>/tmp/orca-apt.log 2>&1 || { tail -n 30 /tmp/orca-apt.log >&2; false; }
rm -f /tmp/orca.deb
'"$remote_askpass"'
mkdir -p "$(dirname "$ORCA_PROJECT_ROOT")"
git clone --quiet "$ORCA_REPO_URL" "$ORCA_PROJECT_ROOT"
cd "$ORCA_PROJECT_ROOT"
git fetch --quiet origin "$ORCA_REPO_REF"
git checkout --quiet -B "$ORCA_REPO_REF" FETCH_HEAD
rm -f /tmp/orca-askpass.sh
# Claude Code: skip the first-run screens. Its credential arrives with the serve step.
node -e "
  const fs = require(\"node:fs\"), p = process.env.HOME + \"/.claude.json\";
  let c = {}; try { c = JSON.parse(fs.readFileSync(p, \"utf8\")); } catch {}
  c.hasCompletedOnboarding = true; fs.writeFileSync(p, JSON.stringify(c, null, 2));
"
echo "build ok: orca-ide $(dpkg-query -W -f="\${Version}" orca-ide), $(git rev-parse --short HEAD)" >&2'

# Waits until something answers on the serve port.
remote_wait_port='wait_port() {
  for _ in $(seq 1 240); do
    [ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ORCA_PORT/" 2>/dev/null)" != 000 ] && return 0
    sleep 0.25
  done
  sprite-env services logs "$SERVICE" --lines 40 >&2 || true
  echo "orca serve did not listen on port $ORCA_PORT within 60 s" >&2
  return 1
}'

# Mints the pairing code, then hands the server to a Sprite service.
#
# `orca serve --recipe-json` starts a detached server, prints the recipe JSON and returns.
# A detached server does not come back after the Sprite sleeps, and `--recipe-json` cannot
# be combined with `--supervise`. So: run it once for the JSON, stop that server by the PIDs
# in its own lock files, then run `orca serve --supervise` as a service with
# `--restart always`. The pairing identity lives in ~/.config/orca, so the code from the
# first run keeps working against the supervised server, and after every wake.
remote_serve='set -euo pipefail
umask 077
: > "$AGENT_ENV_FILE"
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || printf "export CLAUDE_CODE_OAUTH_TOKEN=%q\n" "$CLAUDE_CODE_OAUTH_TOKEN" >> "$AGENT_ENV_FILE"
[ -z "${ANTHROPIC_API_KEY:-}" ] || printf "export ANTHROPIC_API_KEY=%q\n" "$ANTHROPIC_API_KEY" >> "$AGENT_ENV_FILE"
grep -q "orca-agent.env" "$HOME/.bashrc" 2>/dev/null || printf "%s\n" "[ -f \"$AGENT_ENV_FILE\" ] && . \"$AGENT_ENV_FILE\"" >> "$HOME/.bashrc"
'"$remote_askpass"'
export GIT_TERMINAL_PROMPT=0
cd "$ORCA_PROJECT_ROOT"; git fetch --quiet origin "$ORCA_REPO_REF"; git checkout --quiet -B "$ORCA_REPO_REF" FETCH_HEAD
rm -f /tmp/orca-askpass.sh
serve_args=(--port "$ORCA_PORT" --project-root "$ORCA_PROJECT_ROOT" --pairing-address "$ORCA_PAIRING_ADDRESS")
orca-ide serve "${serve_args[@]}" --recipe-json > "$RECIPE_FILE.tmp" 2>/tmp/orca-serve.log || { cat /tmp/orca-serve.log >&2; false; }
node -e "const r = JSON.parse(require(\"node:fs\").readFileSync(process.argv[1], \"utf8\")); if (!r.pairingCode) throw new Error(\"no pairingCode\")" "$RECIPE_FILE.tmp"
mv "$RECIPE_FILE.tmp" "$RECIPE_FILE"
stop_owner() {
  local f="$1" pid ticks
  [ -f "$f" ] || return 0
  pid="$(jq -r .pid "$f")"; ticks="$(jq -r .linuxStartTicks "$f")"
  [ -r "/proc/$pid/stat" ] || return 0
  # Only signal the process the lock file names, never a recycled PID.
  [ "$(awk "{print \$22}" "/proc/$pid/stat")" = "$ticks" ] || return 0
  kill -TERM "$pid"
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  echo "pid $pid did not stop" >&2; return 1
}
orca_data="${XDG_CONFIG_HOME:-$HOME/.config}/orca"
stop_owner "$orca_data/orcad.lock"
for f in "$orca_data"/daemon/daemon-v*.pid; do stop_owner "$f"; done
sprite-env services delete "$SERVICE" >/dev/null 2>&1 || true
sprite-env services create "$SERVICE" --restart always --dir "$HOME" -- /bin/bash -c \
  ". \"$AGENT_ENV_FILE\"; exec orca-ide serve --supervise $(printf "%q " "${serve_args[@]}")" >/dev/null
'"$remote_wait_port"'
wait_port
cat "$RECIPE_FILE"'

# Starts the stopped service again and prints the saved recipe JSON.
remote_resume='set -euo pipefail
[ -f "$RECIPE_FILE" ] || { echo "no $RECIPE_FILE on this Sprite" >&2; false; }
sprite-env services start "$SERVICE" >/dev/null
'"$remote_wait_port"'
wait_port
cat "$RECIPE_FILE"'

# build_sprite <name>: create a Sprite with a public URL, install Orca, check out the repo.
build_sprite() {
  local name="$1" token
  token="$(git_token)"
  log "creating Sprite $name"
  sp create --skip-console --label orca-recipe "$name" >&2
  sp config update --url-auth public "$name" >&2
  log "installing Orca $orca_version and cloning $repo_url@$repo_ref"
  rexec "$name" --env "ORCA_VERSION=$orca_version,ORCA_REPO_URL=$repo_url,ORCA_REPO_REF=$repo_ref,ORCA_PROJECT_ROOT=$project_root${token:+,GH_TOKEN=$token}" \
    -- bash -lc "$remote_build" >&2
}

remote_env() {
  local url="$1"
  printf 'ORCA_PORT=%s,ORCA_PROJECT_ROOT=%s,ORCA_REPO_REF=%s,ORCA_PAIRING_ADDRESS=%s,SERVICE=%s,RECIPE_FILE=%s,AGENT_ENV_FILE=%s' \
    "$port" "$project_root" "$repo_ref" "${url/https:\/\//wss://}" "$service_name" "$recipe_file" "$agent_env_file"
}

# serve_sprite <name>: start orca serve on a built Sprite and print its recipe JSON.
serve_sprite() {
  local name="$1" url token envs
  url="$(sprite_url "$name")"; [ -n "$url" ] || die "no URL for Sprite $name"
  token="$(git_token)"
  envs="$(remote_env "$url")${token:+,GH_TOKEN=$token}"
  # Agent credentials go straight to a 0600 file on the Sprite, never to state or userData.
  [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || envs+=",CLAUDE_CODE_OAUTH_TOKEN=$CLAUDE_CODE_OAUTH_TOKEN"
  [ -z "${ANTHROPIC_API_KEY:-}" ] || envs+=",ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] || log "warning: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; claude will ask to log in"
  rexec "$name" --env "$envs" -- bash -lc "$remote_serve"
}

# emit_result <recipe-json> <name>: merge userData and print.
emit_result() {
  node -e '
    const [json, name, org] = process.argv.slice(1);
    const r = JSON.parse(json);
    console.log(JSON.stringify({ ...r, schemaVersion: 1,
      userData: { ...(r.userData || {}), provider: "sprites", resourceId: name, org } }));
  ' "$1" "$2" "$org"
}

# payload_value <payload> <userData key>: read the lifecycle payload Orca sends on stdin.
payload_value() {
  node -e '
    const d = JSON.parse(process.argv[1] || "{}");
    const u = d.recipeResult?.userData ?? d.userData ?? {};
    const v = u[process.argv[2]];
    process.stdout.write(v === undefined || v === null ? "" : String(v));
  ' "$1" "$2"
}

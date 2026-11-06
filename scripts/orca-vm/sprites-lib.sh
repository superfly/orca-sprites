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

# rexec <sprite> [--env K=V,...] [--file src:dest] -- <cmd...>: run on the Sprite. Returns the
# remote exit code. --no-port-forward stops the CLI from binding ports the command opens
# (orca serve opens 8080) on the desktop.
rexec() { local name="$1"; shift; sp exec -s "$name" --no-stdin --no-port-forward "$@"; }

# use_payload_org <payload>: lifecycle scripts act in the org the Sprite was created in.
use_payload_org() {
  local o; o="$(payload_value "$1" org)"
  if [ -n "$o" ] && [ "$o" != "$org" ]; then log "using org $o from the lifecycle payload"; org="$o"; fi
}

# `sprite exec --env` splits on commas, so a value with a comma would be misparsed.
check_env_value() {
  case "$2" in *,*) die "$1 must not contain a comma (sprite exec --env splits on commas): $2" ;; esac
}
for v in repo_url repo_ref project_root orca_version; do check_env_value "$v" "${!v}"; done

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

# sprite_url <name>: the Sprite's URL, empty if there is no such Sprite. Fails if the list
# call fails, so an expired login is never mistaken for "no Sprite".
sprite_url() {
  local out
  out="$(sp --json list --prefix "$1")" || die "could not list Sprites in org $org (is the sprite CLI logged in?)"
  printf '%s' "$out" | node -e '
    let d = ""; process.stdin.on("data", c => d += c).on("end", () => {
      const s = (JSON.parse(d).sprites || []).find(x => x.name === process.argv[1]);
      process.stdout.write(s?.url ?? "");
    });' "$1"
}

# destroy_sprite <name>: succeeds if the Sprite is destroyed or does not exist; fails on any
# other error, so a Sprite is never left running behind a reported success.
destroy_sprite() {
  local name="$1" out rc=0
  out="$(sp destroy --force "$name" 2>&1)" || rc=$?
  printf '%s\n' "$out" >&2
  [ "$rc" = 0 ] && return 0
  case "$out" in *"sprite not found"*) log "$name is already gone"; return 0 ;; esac
  log "could not destroy $name; destroy it by hand: sprite -o $org destroy --force $name"
  return 1
}

# with_secrets <sprite> <env K=V,...> <cmd...>: run a command with the secrets uploaded as a file, so
# no token is on a command line on the desktop or the Sprite. The remote fragment sources
# $SECRETS_FILE and deletes it. Secrets: GH_TOKEN (git), CLAUDE_CODE_OAUTH_TOKEN, ANTHROPIC_API_KEY.
with_secrets() {
  local name="$1" envs="$2"; shift 2
  local local_file remote_file token rc=0
  local_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/orca-sprites.XXXXXX")"
  remote_file="/tmp/orca-secrets-$(date +%s)-$RANDOM$RANDOM.env"
  token="$(git_token)"
  {
    [ -z "$token" ] || printf 'export GH_TOKEN=%q\n' "$token"
    [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
    [ -z "${ANTHROPIC_API_KEY:-}" ] || printf 'export ANTHROPIC_API_KEY=%q\n' "$ANTHROPIC_API_KEY"
  } > "$local_file"
  rexec "$name" --file "$local_file:$remote_file" --env "${envs:+$envs,}SECRETS_FILE=$remote_file" -- "$@" || rc=$?
  rm -f "$local_file"
  return "$rc"
}

# Remote fragments run under `bash -lc` on the Sprite. They never call `exit`: in a login
# shell with `set -e`, `exit` runs ~/.bash_logout, whose clear_console fails without a TTY
# and turns every exit status into 1. They end on the status of their last command.

# Sources and deletes the uploaded secrets file. The upload lands root-owned and 0644, so it
# is removed with sudo straight away.
remote_secrets='if [ -n "${SECRETS_FILE:-}" ] && [ -f "$SECRETS_FILE" ]; then . "$SECRETS_FILE"; sudo rm -f "$SECRETS_FILE"; fi'

remote_askpass='if [ -n "${GH_TOKEN:-}" ]; then
  printf "%s\n" "#!/usr/bin/env bash" "case \"\$1\" in *Username*) echo x-access-token;; *Password*) echo \"\$GH_TOKEN\";; esac" > /tmp/orca-askpass.sh
  chmod 700 /tmp/orca-askpass.sh; export GIT_ASKPASS=/tmp/orca-askpass.sh
fi'

# Installs Orca and checks out the repository.
remote_build='set -euo pipefail
'"$remote_secrets"'
export GIT_TERMINAL_PROMPT=0
echo "installing orca-ide $ORCA_VERSION" >&2
curl -fsSL -o /tmp/orca.deb "https://github.com/stablyai/orca/releases/download/v$ORCA_VERSION/orca-ide_${ORCA_VERSION}_amd64.deb"
# Without the update, libgtk-3-0 does not resolve on the Sprite image.
sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/tmp/orca-apt.log 2>&1
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /tmp/orca.deb >>/tmp/orca-apt.log 2>&1 || { tail -n 30 /tmp/orca-apt.log >&2; false; }
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
'"$remote_secrets"'
: > "$AGENT_ENV_FILE"
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || printf "export CLAUDE_CODE_OAUTH_TOKEN=%q\n" "$CLAUDE_CODE_OAUTH_TOKEN" >> "$AGENT_ENV_FILE"
[ -z "${ANTHROPIC_API_KEY:-}" ] || printf "export ANTHROPIC_API_KEY=%q\n" "$ANTHROPIC_API_KEY" >> "$AGENT_ENV_FILE"
grep -q "orca-agent.env" "$HOME/.bashrc" 2>/dev/null || printf "%s\n" "[ -f \"$AGENT_ENV_FILE\" ] && . \"$AGENT_ENV_FILE\"" >> "$HOME/.bashrc"
unset GH_TOKEN
serve_args=(--port "$ORCA_PORT" --project-root "$ORCA_PROJECT_ROOT" --pairing-address "$ORCA_PAIRING_ADDRESS")
orca-ide serve "${serve_args[@]}" --recipe-json > "$RECIPE_FILE.tmp" 2>/tmp/orca-serve.log || { cat /tmp/orca-serve.log >&2; false; }
node -e "const r = JSON.parse(require(\"node:fs\").readFileSync(process.argv[1], \"utf8\")); if (!r.pairingCode) throw new Error(\"no pairingCode\")" "$RECIPE_FILE.tmp"
mv "$RECIPE_FILE.tmp" "$RECIPE_FILE"
stop_owner() {
  local f="$1" pid ticks
  [ -f "$f" ] || return 0
  pid="$(jq -r ".pid // empty" "$f")"; ticks="$(jq -r ".linuxStartTicks // empty" "$f")"
  [ -n "$pid" ] && [ -n "$ticks" ] || { echo "cannot read pid from $f" >&2; return 1; }
  [ -r "/proc/$pid/stat" ] || return 0
  # Only signal the process the lock file names, never a recycled PID. Field 22 is the start
  # time; drop the "(comm)" field first, because comm may contain spaces.
  [ "$(sed "s/.*) //" "/proc/$pid/stat" | awk "{print \$20}")" = "$ticks" ] || return 0
  kill -TERM "$pid"
  for _ in $(seq 1 100); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.1; done
  echo "pid $pid did not stop" >&2; return 1
}
orca_data="${XDG_CONFIG_HOME:-$HOME/.config}/orca"
stop_owner "$orca_data/orcad.lock"
for f in "$orca_data"/daemon/daemon-v*.pid; do stop_owner "$f"; done
# The supervised server waits while another Orca serves this profile, so the detached one must
# really be gone, or wake would find no server.
for _ in $(seq 1 100); do [ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ORCA_PORT/" 2>/dev/null)" = 000 ] && break; sleep 0.1; done
[ "$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$ORCA_PORT/" 2>/dev/null)" = 000 ] || { echo "port $ORCA_PORT is still in use after stopping the detached server" >&2; false; }
sprite-env services delete "$SERVICE" >/dev/null 2>&1 || true
# --http-port makes a request that wakes the Sprite wait until orca serve listens, instead of
# failing with 502 while it starts.
sprite-env services create "$SERVICE" --restart always --http-port "$ORCA_PORT" --dir "$HOME" -- /bin/bash -c \
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

# new_sprite <name>: create a Sprite. Fails if one with that name exists already.
new_sprite() {
  local name="$1"
  [ -z "$(sprite_url "$name")" ] || die "a Sprite named $name already exists; not touching it"
  log "creating Sprite $name"
  sp create --skip-console --label orca-recipe "$name" >&2
}

# build_sprite <name>: give a new Sprite a public URL, install Orca, check out the repo.
build_sprite() {
  local name="$1"
  sp config update --url-auth public "$name" >&2
  log "installing Orca $orca_version and cloning $repo_url@$repo_ref"
  with_secrets "$name" "ORCA_VERSION=$orca_version,ORCA_REPO_URL=$repo_url,ORCA_REPO_REF=$repo_ref,ORCA_PROJECT_ROOT=$project_root" \
    bash -lc "$remote_build" >&2
}

remote_env() {
  local url="$1"
  printf 'ORCA_PORT=%s,ORCA_PROJECT_ROOT=%s,ORCA_REPO_REF=%s,ORCA_PAIRING_ADDRESS=%s,SERVICE=%s,RECIPE_FILE=%s,AGENT_ENV_FILE=%s' \
    "$port" "$project_root" "$repo_ref" "${url/https:\/\//wss://}" "$service_name" "$recipe_file" "$agent_env_file"
}

# serve_sprite <name>: start orca serve on a built Sprite and print its recipe JSON.
# Agent credentials go to a 0600 file on the Sprite, never to state or userData.
serve_sprite() {
  local name="$1" url
  url="$(sprite_url "$name")"; [ -n "$url" ] || die "no URL for Sprite $name"
  [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}${ANTHROPIC_API_KEY:-}" ] || log "warning: neither CLAUDE_CODE_OAUTH_TOKEN nor ANTHROPIC_API_KEY is set; claude will ask to log in"
  with_secrets "$name" "$(remote_env "$url")" bash -lc "$remote_serve"
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

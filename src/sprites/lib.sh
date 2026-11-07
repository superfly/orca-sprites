# shellcheck shell=bash
# Shared helpers for the Sprites recipe. scripts/build.mjs inlines this file into every
# phase of recipes/sprites.json, because a plugin recipe must be self-contained.
#
# Every phase keeps stdout for its one JSON result. Everything else goes to stderr.
#
# Orca runs each phase in the repository's root directory and sets ORCA_* variables
# (ORCA_VM_INSTANCE_ID, ORCA_RECIPE_ID, ORCA_REPO_PATH, ...). For a recipe like this one it
# leaves ORCA_REPO_URL, ORCA_REPO_REF and ORCA_VERSION empty. Optional
# overrides, read from the environment Orca was started from:
#   SPRITES_ORG            Sprites organization (default: the sprite CLI's default org)
#   SPRITES_REPO_URL       repository to clone (default: the repo's origin remote)
#   SPRITES_REPO_REF       branch or tag to check out (default: origin's default branch)
#   SPRITES_PROJECT_ROOT   checkout path on the Sprite (default: /home/sprite/<repo name>)
#   SPRITES_ORCA_VERSION   orca-ide version to install (default: the desktop Orca CLI's version)
#   SPRITES_NAME_PREFIX    Sprite name prefix (default: orca)

log() { printf '[sprites] %s\n' "$*" >&2; }
die() { printf '[sprites] error: %s\n' "$*" >&2; exit 1; }

command -v sprite >/dev/null 2>&1 || die "the sprite CLI is not on PATH (install: curl -fsSL https://sprites.dev/install.sh | bash, then sprite login)"
command -v node >/dev/null 2>&1 || die "node is not on PATH; the recipe uses it to read and write JSON"

org="${SPRITES_ORG:-}"
repo_url="" repo_ref="" project_root=""
name_prefix="${SPRITES_NAME_PREFIX:-orca}"
# Orca does not pass its version to recipes, so ask the desktop's Orca CLI, then fall back
# to the version this recipe was tested with.
detect_orca_version() {
  local v="" cli
  for cli in orca-ide orca; do
    command -v "$cli" >/dev/null 2>&1 || continue
    v="$("$cli" --version 2>/dev/null | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
    [ -z "$v" ] || break
  done
  printf '%s' "${v:-1.4.246}"
}
orca_version="${SPRITES_ORCA_VERSION:-${ORCA_VERSION:-}}"
[ -n "$orca_version" ] || orca_version="$(detect_orca_version)"
orca_version="${orca_version#v}"
# The Sprite URL routes to port 8080.
port=8080
service_name="orca"
recipe_file="/home/sprite/.orca-recipe.json"
agent_env_file="/home/sprite/.orca-agent.env"
# src/sprites/orca-sprite-status.sh, base64: scripts/build.mjs fills this in.
sprite_status_b64=''

sp() { sprite -o "$org" "$@"; }

# rexec <sprite> [--env K=V,...] [--file src:dest] -- <cmd...>: run on the Sprite. Returns the
# remote exit code. --no-port-forward stops the CLI from binding ports the command opens
# (orca serve opens 8080) on the desktop.
rexec() { local name="$1"; shift; sp exec -s "$name" --no-stdin --no-port-forward "$@"; }

# ensure_org: use SPRITES_ORG, or the org the sprite CLI uses by default.
ensure_org() {
  [ -n "$org" ] && return 0
  org="$(sprite --json list 2>/dev/null | node -e 'let d="";process.stdin.on("data",c=>d+=c).on("end",()=>{try{process.stdout.write(JSON.parse(d).org?.name||"")}catch{}})')"
  [ -n "$org" ] || die "no Sprites org: run 'sprite login', or set SPRITES_ORG in the environment Orca starts from"
}

# use_payload_org <payload>: lifecycle phases act in the org the Sprite was created in.
use_payload_org() {
  local o; o="$(payload_value "$1" org)"
  [ -z "$o" ] || org="$o"
  ensure_org
}

# `sprite exec --env` splits on commas, so a value with a comma would be misparsed.
check_env_value() {
  case "$2" in *,*) die "$1 must not contain a comma (sprite exec --env splits on commas): $2" ;; esac
}

# resolve_repo: repo_url, repo_ref and project_root for the create phase.
resolve_repo() {
  local repo_dir="${ORCA_REPO_PATH:-$PWD}" ref
  repo_url="${SPRITES_REPO_URL:-${ORCA_REPO_URL:-}}"
  [ -n "$repo_url" ] || repo_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
  [ -n "$repo_url" ] || die "no repository URL: the repo has no 'origin' remote; add one or set SPRITES_REPO_URL"
  # Never carry credentials from the remote URL onto the Sprite; the git token goes separately.
  repo_url="$(printf '%s' "$repo_url" | sed -E 's#^(https?://)[^/@]+@#\1#')"
  case "$repo_url" in
    https://*|http://*) ;;
    git@*:*) repo_url="${repo_url#git@}"; repo_url="https://${repo_url/://}" ;;
    *) die "the Sprite clones over HTTPS, so the origin remote must be a hosted URL, not $repo_url (set SPRITES_REPO_URL)" ;;
  esac
  ref="${SPRITES_REPO_REF:-${ORCA_REPO_REF:-}}"
  ref="${ref#refs/heads/}"; ref="${ref#refs/remotes/origin/}"; ref="${ref#origin/}"
  # Orca sets ORCA_REPO_REF only for provisioned-root recipes, so this usually falls through
  # to origin's default branch: the local origin/HEAD, then asking the remote.
  if [ -z "$ref" ]; then
    ref="$(git -C "$repo_dir" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)"
    ref="${ref#origin/}"
  fi
  # Ask the HTTPS URL the Sprite will clone first: it works without SSH keys.
  local remote
  for remote in "$repo_url" origin; do
    [ -z "$ref" ] || break
    ref="$(GIT_TERMINAL_PROMPT=0 git -C "$repo_dir" ls-remote --symref "$remote" HEAD 2>/dev/null | sed -n 's#^ref: refs/heads/\([^[:space:]]*\)[[:space:]]*HEAD$#\1#p' | head -n 1 || true)"
  done
  repo_ref="${ref:-main}"
  local base="${repo_url%/}"; base="${base##*/}"; base="${base%.git}"
  project_root="${SPRITES_PROJECT_ROOT:-/home/sprite/${base:-project}}"
  case "$project_root" in /*) ;; *) die "SPRITES_PROJECT_ROOT must be an absolute path on the Sprite: $project_root" ;; esac
  for v in repo_url repo_ref project_root orca_version; do check_env_value "$v" "${!v}"; done
  log "repository $repo_url at $repo_ref, checked out at $project_root"
}

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

# with_secrets <sprite> <git|agent> <env K=V,...> <cmd...>: run a command with secrets
# uploaded as a file, so no token is on a command line on the desktop or the Sprite. The
# remote fragment sources $SECRETS_FILE and deletes it. `git` sends GH_TOKEN for the clone;
# `agent` sends CLAUDE_CODE_OAUTH_TOKEN and ANTHROPIC_API_KEY for the agent. Each step gets
# only what it needs.
with_secrets() {
  local name="$1" which="$2" envs="$3"; shift 3
  local local_file remote_file token="" rc=0
  local_file="$(umask 077; mktemp "${TMPDIR:-/tmp}/orca-sprites.XXXXXX")"
  remote_file="/tmp/orca-secrets-$(date +%s)-$RANDOM$RANDOM.env"
  [ "$which" != git ] || token="$(git_token)"
  {
    [ -z "$token" ] || printf 'export GH_TOKEN=%q\n' "$token"
    if [ "$which" = agent ]; then
      [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || printf 'export CLAUDE_CODE_OAUTH_TOKEN=%q\n' "$CLAUDE_CODE_OAUTH_TOKEN"
      [ -z "${ANTHROPIC_API_KEY:-}" ] || printf 'export ANTHROPIC_API_KEY=%q\n' "$ANTHROPIC_API_KEY"
    fi
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
# in its own lock files, then run `orca serve --supervise` as a service that restarts on
# wake. The pairing identity lives in ~/.config/orca, so the code from the first run keeps
# working against the supervised server, and after every wake.
remote_serve='set -euo pipefail
umask 077
'"$remote_secrets"'
: > "$AGENT_ENV_FILE"
[ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] || printf "export CLAUDE_CODE_OAUTH_TOKEN=%q\n" "$CLAUDE_CODE_OAUTH_TOKEN" >> "$AGENT_ENV_FILE"
[ -z "${ANTHROPIC_API_KEY:-}" ] || printf "export ANTHROPIC_API_KEY=%q\n" "$ANTHROPIC_API_KEY" >> "$AGENT_ENV_FILE"
# Claude Code: trust the project folder, and pre-approve an API key so the first run does not
# stop at "Do you want to use this API key?". Only the last 20 characters of the key are stored,
# which is what Claude Code itself records.
node -e "
  const fs = require(\"node:fs\"), p = process.env.HOME + \"/.claude.json\";
  let c = {}; try { c = JSON.parse(fs.readFileSync(p, \"utf8\")); } catch {}
  c.projects = c.projects || {};
  c.projects[process.env.ORCA_PROJECT_ROOT] = { ...(c.projects[process.env.ORCA_PROJECT_ROOT] || {}), hasTrustDialogAccepted: true };
  const k = process.env.ANTHROPIC_API_KEY;
  if (k) {
    c.customApiKeyResponses = c.customApiKeyResponses || { approved: [], rejected: [] };
    const tail = k.slice(-20);
    if (!c.customApiKeyResponses.approved.includes(tail)) c.customApiKeyResponses.approved.push(tail);
  }
  fs.writeFileSync(p, JSON.stringify(c, null, 2), { mode: 0o600 });
"
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
# The command goes in a script because older sprite-env (0.0.x) takes only --cmd and
# comma-separated --args, not "-- command...".
serve_script="$HOME/.orca-serve.sh"
printf "#!/bin/bash\n. %q\nexec orca-ide serve --supervise %s\n" "$AGENT_ENV_FILE" "$(printf "%q " "${serve_args[@]}")" > "$serve_script"
chmod 700 "$serve_script"
create_opts=(--cmd "$serve_script" --http-port "$ORCA_PORT" --dir "$HOME")
# Newer sprite-env needs --restart always to bring the server back after a wake. Older
# sprite-env has no --restart (it rejects the flag) and streams logs for 5 s unless told not to.
services_help="$(sprite-env services help 2>&1 || true)"
case "$services_help" in *--restart*) create_opts+=(--restart always) ;; esac
case "$services_help" in *--no-stream*) create_opts+=(--no-stream) ;; esac
sprite-env services create "$SERVICE" "${create_opts[@]}" >/dev/null
'"$remote_wait_port"'
wait_port
# The workspace status banner: orca-sprite-status, the facts it shows, and a hook that runs it
# in every new interactive terminal. Orca opens zsh on the Sprite, so the hook goes in .zshrc
# (and .bashrc for bash). The VM id is the end of the runtime id Orca saw when it paired, which
# names this workspace in Settings > Host; the server gets a new one each restart, so keep it now.
mkdir -p "$HOME/.local/bin"
install -m 755 "$STATUS_FILE" "$HOME/.local/bin/orca-sprite-status" && sudo rm -f "$STATUS_FILE"
runtime_id="$(timeout 30 orca-ide status --json 2>/dev/null | jq -r ".result.runtime.runtimeId // empty" || true)"
printf "ORCA_SPRITE_NAME=%q\nORCA_SPRITE_URL=%q\nORCA_REPO_NAME=%q\nORCA_VM_ID=%q\nORCA_PROJECT_ROOT=%q\n" \
  "$ORCA_SPRITE_NAME" "$ORCA_SPRITE_URL" "$ORCA_REPO_NAME" "${runtime_id: -8}" "$ORCA_PROJECT_ROOT" > "$HOME/.orca-sprite.env"
for rc in "$HOME/.zshrc" "$HOME/.bashrc"; do
  grep -q "orca-sprite-status --banner" "$rc" 2>/dev/null \
    || printf "%s\n" "case \$- in *i*) [ -x \"\$HOME/.local/bin/orca-sprite-status\" ] && \"\$HOME/.local/bin/orca-sprite-status\" --banner ;; esac" >> "$rc"
done
cat "$RECIPE_FILE"'

# Starts the stopped service again and prints the saved recipe JSON.
remote_resume='set -euo pipefail
[ -f "$RECIPE_FILE" ] || { echo "no $RECIPE_FILE on this Sprite" >&2; false; }
sprite-env services start "$SERVICE" >/dev/null
'"$remote_wait_port"'
wait_port
cat "$RECIPE_FILE"'

# name_is_free <name>: fail if a Sprite with that name exists, so cleanup never touches it.
name_is_free() {
  [ -z "$(sprite_url "$1")" ] || die "a Sprite named $1 already exists; not touching it"
}

# new_sprite <name>: create a Sprite.
new_sprite() {
  local name="$1"
  log "creating Sprite $name"
  local out rc=0
  out="$(sp create --skip-console --label orca-recipe "$name" 2>&1)" || rc=$?
  # Restricted tokens cannot set labels; the label only tags the Sprite, so create it without.
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'cannot set labels'; then
    rc=0; out="$(sp create --skip-console "$name" 2>&1)" || rc=$?
  fi
  # Drop the CLI's boxed "try the API" tip, which Orca shows in its provisioning log.
  printf '%s\n' "$out" | { grep -v -e '^│' -e '^[[:space:]]*$' || true; } >&2
  return "$rc"
}

# build_sprite <name>: give a new Sprite a public URL, install Orca, check out the repo.
build_sprite() {
  local name="$1"
  sp config update --url-auth public "$name" >&2
  log "installing Orca $orca_version and cloning $repo_url@$repo_ref"
  with_secrets "$name" git "ORCA_VERSION=$orca_version,ORCA_REPO_URL=$repo_url,ORCA_REPO_REF=$repo_ref,ORCA_PROJECT_ROOT=$project_root" \
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
  local status_local status_remote repo_name
  repo_name="$(basename "${ORCA_REPO_PATH:-$repo_url}" .git)"
  status_local="$(mktemp "${TMPDIR:-/tmp}/orca-sprite-status.XXXXXX")"
  status_remote="/tmp/orca-sprite-status-$(date +%s)-$RANDOM"
  node -e 'process.stdout.write(Buffer.from(process.argv[1], "base64"))' "$sprite_status_b64" > "$status_local"
  rexec "$name" --file "$status_local:$status_remote" -- true >&2 || { rm -f "$status_local"; die "could not upload the status script to $name"; }
  rm -f "$status_local"
  with_secrets "$name" agent "$(remote_env "$url"),ORCA_SPRITE_NAME=$name,ORCA_SPRITE_URL=$url,ORCA_REPO_NAME=$repo_name,STATUS_FILE=$status_remote" \
    bash -lc "$remote_serve"
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

# shellcheck shell=bash
# Shared helpers for the Sprites recipe. scripts/build.mjs inlines this file into every
# phase of recipes/sprites.json, because a plugin recipe must be self-contained.
#
# Every phase keeps stdout for its one JSON result. Everything else goes to stderr.
#
# Orca runs each phase in the repository's root directory and sets ORCA_* variables
# (ORCA_VM_INSTANCE_ID, ORCA_RECIPE_ID, ORCA_REPO_PATH, ...). For a recipe like this one it
# leaves ORCA_REPO_URL, ORCA_REPO_REF and ORCA_VERSION empty. The Sprite's checkout comes from
# the local repository, sent as a git bundle, so it needs no git token and no pushed branch.
# Optional overrides, read from the environment Orca was started from:
#   SPRITES_ORG            Sprites organization (default: the sprite CLI's default org)
#   SPRITES_PROJECT_ROOT   checkout path on the Sprite (default: /home/sprite/<repo name>)
#   SPRITES_ORCA_VERSION   orca-ide version to install (default: the desktop Orca CLI's version)
#   SPRITES_NAME_PREFIX    Sprite name prefix (default: orca)
#   SPRITES_INSTALL        fast (default): unpack the Orca .deb and run orca serve on orcad, with
#                          no desktop packages; full: apt-get install the .deb

log() { printf '[sprites] %s\n' "$*" >&2; }
# step <n> <text>: start step n of create's 5 and log it; step_done logs how long it took.
step() { step_started="$(date +%s)"; log "[$1/5] $2"; }
step_done() { log "      done ($(( $(date +%s) - step_started ))s)"; }
die() { printf '[sprites] error: %s\n' "$*" >&2; exit 1; }

command -v sprite >/dev/null 2>&1 || die "the sprite CLI is not on PATH (install: curl -fsSL https://sprites.dev/install.sh | bash, then sprite login)"
command -v node >/dev/null 2>&1 || die "node is not on PATH; the recipe uses it to read and write JSON"

org="${SPRITES_ORG:-}"
repo_dir="" repo_url="" repo_ref="" origin_head="" project_root=""
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
install_mode="${SPRITES_INSTALL:-fast}"
case "$install_mode" in fast|full) ;; *) die "SPRITES_INSTALL must be fast or full, not $install_mode" ;; esac
# The Sprite URL routes to port 8080.
port=8080
service_name="orca"
recipe_file="/home/sprite/.orca-recipe.json"

sp() { sprite -o "$org" "$@"; }

# rexec <sprite> [--env K=V,...] [--file src:dest] -- <cmd...>: run on the Sprite. Returns the
# remote exit code. --no-port-forward stops the CLI from binding ports the command opens
# (orca serve opens 8080) on the desktop.
# Its stderr drops two kinds of noise Orca would show in the provisioning log: the CLI's
# "Uploaded ... -> /tmp/orca-..." lines and the Sprite's .bashrc "bind" warnings,
# which bash prints because `bash -lc` has no line editing. stdout (the recipe JSON) is
# passed through untouched on fd 3.
# With rexec_stdin=1 it forwards stdin (for the repository bundle) instead of --no-stdin.
rexec() {
  local name="$1" rc=0 stdin_flag="--no-stdin"; shift
  if [ "${rexec_stdin:-0}" = 1 ]; then
    # Newer CLIs warn unless stdin forwarding is explicit; older ones have no --stdin.
    stdin_flag=""; sp exec --help 2>&1 | grep -q -e '^ *--stdin ' && stdin_flag="--stdin"
  fi
  # shellcheck disable=SC2086
  { sp exec -s "$name" $stdin_flag --no-port-forward "$@" 2>&1 1>&3 3>&- \
      | { grep --line-buffered -v -e 'bind: warning: line editing not enabled' -e '^Uploaded .* -> /tmp/orca-' \
            -e 'stdin is being forwarded implicitly' -e 'Pass --stdin to confirm' || true; } >&2
  } 3>&1 || rc=$?
  return "$rc"
}

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

# resolve_repo: repo_dir, repo_ref (the local branch, or a commit if HEAD is detached),
# repo_url (origin as HTTPS, may be empty) and project_root for the create phase.
resolve_repo() {
  repo_dir="${ORCA_REPO_PATH:-$PWD}"
  git -C "$repo_dir" rev-parse --verify --quiet HEAD >/dev/null \
    || die "$repo_dir is not a git repository with at least one commit"
  # Not --short: it disambiguates (a tag named like the branch gives heads/<branch>).
  repo_ref="$(git -C "$repo_dir" symbolic-ref --quiet HEAD 2>/dev/null || true)"
  repo_ref="${repo_ref#refs/heads/}"
  [ -n "$repo_ref" ] || repo_ref="$(git -C "$repo_dir" rev-parse HEAD)"
  # A bundle from a shallow clone has no prerequisites check and fails on the Sprite; a partial
  # clone would fetch every missing object from the promisor remote while bundling.
  [ "$(git -C "$repo_dir" rev-parse --is-shallow-repository 2>/dev/null)" != true ] \
    || die "$repo_dir is a shallow clone, which cannot be sent to the Sprite; run git fetch --unshallow first"
  [ -z "$(git -C "$repo_dir" config --get extensions.partialClone 2>/dev/null || true)" ] \
    || die "$repo_dir is a partial clone (--filter), which cannot be sent to the Sprite; clone it in full"
  # origin becomes the Sprite checkout's origin, so pushing works after gh auth login there.
  # HTTPS, because the Sprite has no SSH keys. Never carry credentials from the URL.
  repo_url="$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)"
  repo_url="$(printf '%s' "$repo_url" | sed -E 's#^(https?://)[^/@]+@#\1#')"
  case "$repo_url" in
    https://*|http://*) ;;
    git@*:*) repo_url="${repo_url#git@}"; repo_url="https://${repo_url/://}" ;;
    ssh://git@*) repo_url="https://${repo_url#ssh://git@}" ;;
    *) repo_url="" ;;
  esac
  origin_head="$(git -C "$repo_dir" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
  origin_head="${origin_head#refs/remotes/}"
  local base="${repo_url%/}"; base="${base##*/}"; base="${base%.git}"
  [ -n "$base" ] || base="$(basename "$(git -C "$repo_dir" rev-parse --show-toplevel)")"
  base="$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '-')"
  project_root="${SPRITES_PROJECT_ROOT:-/home/sprite/${base:-project}}"
  case "$project_root" in /*) ;; *) die "SPRITES_PROJECT_ROOT must be an absolute path on the Sprite: $project_root" ;; esac
  for v in repo_url repo_ref origin_head project_root orca_version; do check_env_value "$v" "${!v}"; done
}

# make_bundle <file>: bundle the local branches, origin's branches and tags, so the Sprite
# gets the same history Orca sees here, unpushed commits included. Uncommitted changes stay
# on this computer.
# Full ref names on stdin, not --branches/--tags: bundle create silently drops a branch and a
# tag that share a name. origin/HEAD is a symref and is set on the Sprite separately.
make_bundle() {
  local out rc=0
  out="$( { git -C "$repo_dir" for-each-ref --format='%(refname)' refs/heads refs/remotes/origin refs/tags \
              | grep -v '^refs/remotes/origin/HEAD$'; echo HEAD; } \
          | git -C "$repo_dir" bundle create "$1" --stdin 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { printf '%s\n' "$out" >&2; log "error: could not bundle $repo_dir"; }
  return "$rc"
}

# git_identity_file <file>: the local git user.name and user.email as shell exports, so
# commits on the Sprite carry the same author. A file, because names can contain commas.
git_identity_file() {
  local n e
  n="$(git -C "$repo_dir" config user.name 2>/dev/null || true)"
  e="$(git -C "$repo_dir" config user.email 2>/dev/null || true)"
  { [ -z "$n" ] || printf 'export GIT_USER_NAME=%q\n' "$n"
    [ -z "$e" ] || printf 'export GIT_USER_EMAIL=%q\n' "$e"; } > "$1"
}

# human_size <bytes>
human_size() { awk -v b="$1" 'BEGIN { split("B KB MB GB", u); i = 1; while (b >= 1024 && i < 4) { b /= 1024; i++ } printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i] }'; }

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
  [ "$rc" = 0 ] && { log "destroyed Sprite $name"; return 0; }
  printf '%s\n' "$out" | { grep -v -e '^[[:space:]]*$' -e 'About to destroy' || true; } >&2
  case "$out" in *"sprite not found"*) log "$name is already gone"; return 0 ;; esac
  log "could not destroy $name; destroy it by hand: sprite -o $org destroy --force $name"
  return 1
}

# with_checkout <sprite> <env K=V,...> <cmd...>: run a command with the repository bundle on
# its stdin and the git identity uploaded at $IDENTITY_FILE. The bundle goes over stdin
# because `sprite exec --file` rejects uploads of 32 MB and more (HTTP 413). No git token is
# sent.
with_checkout() {
  local name="$1" envs="$2"; shift 2
  local tmp rc=0 stamp size note dirty=0
  tmp="$(umask 077; mktemp -d "${TMPDIR:-/tmp}/orca-sprites.XXXXXX")"
  # Orca stops a cancelled phase with TERM; do not leave the bundle behind. The exit still
  # runs the phase's own EXIT trap (create.sh destroys the half-built Sprite).
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'; exit 143" TERM INT HUP
  if ! make_bundle "$tmp/repo.bundle" || ! git_identity_file "$tmp/identity.env"; then
    rm -rf "$tmp"; trap - TERM INT HUP; return 1
  fi
  size="$(wc -c < "$tmp/repo.bundle" | tr -d ' ')"
  # Shown by the remote step 3, so the log stays in order.
  note="$(git -C "$repo_dir" rev-parse --short HEAD) from this computer ($(human_size "$size"))"
  [ -z "$(git -C "$repo_dir" status --porcelain --untracked-files=no 2>/dev/null)" ] || dirty=1
  stamp="$(date +%s)-$RANDOM$RANDOM"
  rexec_stdin=1 rexec "$name" --file "$tmp/identity.env:/tmp/orca-identity-$stamp.env" \
    --env "${envs:+$envs,}BUNDLE_FILE=/tmp/orca-repo-$stamp.bundle,IDENTITY_FILE=/tmp/orca-identity-$stamp.env,BUNDLE_SIZE=$size,BUNDLE_NOTE=$note,BUNDLE_DIRTY=$dirty" \
    -- "$@" < "$tmp/repo.bundle" || rc=$?
  rm -rf "$tmp"
  trap - TERM INT HUP
  return "$rc"
}

# Remote fragments run under `bash -lc` on the Sprite. They never call `exit`: in a login
# shell with `set -e`, `exit` runs ~/.bash_logout, whose clear_console fails without a TTY
# and turns every exit status into 1. They end on the status of their last command.

# Installs Orca and checks out the repository.
remote_build='set -euo pipefail
# Read the repository bundle from stdin first, so nothing later (apt, dpkg) can consume it.
SECONDS=0
head -c "$BUNDLE_SIZE" > "$BUNDLE_FILE"
[ "$(wc -c < "$BUNDLE_FILE")" = "$BUNDLE_SIZE" ] \
  || { echo "[sprites] error: the repository arrived incomplete ($(wc -c < "$BUNDLE_FILE") of $BUNDLE_SIZE bytes); try again" >&2; false; }
bundle_secs=$SECONDS
echo "[sprites] [2/5] Installing Orca $ORCA_VERSION on the Sprite" >&2
SECONDS=0
curl -fsSL -o /tmp/orca.deb "https://github.com/stablyai/orca/releases/download/v$ORCA_VERSION/orca-ide_${ORCA_VERSION}_amd64.deb" \
  || { echo "[sprites] error: could not download orca-ide $ORCA_VERSION. Set SPRITES_ORCA_VERSION to a released Orca version." >&2; false; }
installed=""
if [ "${ORCA_INSTALL:-fast}" = fast ]; then
  # orca serve runs on orcad, Orca'"'"'s own Node server, which the .deb carries. Unpack the .deb
  # instead of installing it, and run Orca'"'"'s CLI on the Sprite'"'"'s Node: the desktop app and its
  # GTK and X11 dependencies are never needed. The CLI finds orcad through the app executable
  # and process.resourcesPath, which only exist in Electron, so a small Node wrapper provides
  # both. A preflight asks the CLI'"'"'s own selection step whether orcad can serve here, which also
  # downloads orcad'"'"'s pinned Node. Anything unexpected falls back to the full install.
  # Node is copied into the app directory: the Sprite'"'"'s node is a mise shim, and the version
  # directory it resolves to can be pruned later.
  app="$HOME/.orca-app"; res="$app/opt/Orca/resources"; cfg="${XDG_CONFIG_HOME:-$HOME/.config}/orca"
  rm -rf "$app"; mkdir -p "$app" "$HOME/.local/bin"; (umask 077; mkdir -p "$cfg")
  if cp "$(node -p process.execPath 2>>/tmp/orca-fast.log)" "$app/node.bin" 2>>/tmp/orca-fast.log \
     && dpkg-deb -x /tmp/orca.deb "$app" 2>>/tmp/orca-fast.log; then
    printf "process.resourcesPath = %s;\n" "$(node -p "JSON.stringify(process.argv[1])" "$res")" > "$app/preload.js"
    printf "#!/bin/sh\nexec %q -r %q \"\$@\"\n" "$app/node.bin" "$app/preload.js" > "$app/node"
    printf "#!/bin/sh\nORCA_APP_EXECUTABLE=%q exec %q %q \"\$@\"\n" "$app/node" "$app/node.bin" "$res/app.asar.unpacked/out/cli/index.js" > "$HOME/.local/bin/orca-ide"
    chmod +x "$app/node" "$HOME/.local/bin/orca-ide"
    selection="$("$app/node" "$res/app.asar.unpacked/out/main/orcad/orcad-local-serve-selection-entry.js" \
      --user-data "$cfg" --app-root "$res/app.asar.unpacked" 2>>/tmp/orca-fast.log || true)"
    case "$selection" in *"ORCA_SERVE_RUNTIME {\"kind\":\"orcad\""*) installed=fast ;; *) printf "%s\n" "$selection" >> /tmp/orca-fast.log ;; esac
  fi
  if [ -z "$installed" ]; then
    echo "[sprites]       orcad could not run from the unpacked package; installing the full package instead" >&2
    tail -n 5 /tmp/orca-fast.log >&2 || true
    rm -rf "$app" "$HOME/.local/bin/orca-ide" "$cfg"
  fi
fi
if [ -z "$installed" ]; then
  # Without the update, libgtk-3-0 does not resolve on the Sprite image.
  sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq >/tmp/orca-apt.log 2>&1
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq /tmp/orca.deb >>/tmp/orca-apt.log 2>&1 || { tail -n 30 /tmp/orca-apt.log >&2; false; }
  installed=full
fi
rm -f /tmp/orca.deb
echo "[sprites]       done (${SECONDS}s, $installed install)" >&2
echo "[sprites] [3/5] Checking out $ORCA_REPO_REF at $BUNDLE_NOTE into $ORCA_PROJECT_ROOT (sent in ${bundle_secs}s)" >&2
if [ "${BUNDLE_DIRTY:-0}" = 1 ]; then echo "[sprites]       uncommitted changes stay on this computer; commit them to have them on the Sprite" >&2; fi
SECONDS=0
# The identity upload lands root-owned; read it, then remove it with sudo.
if [ -s "$IDENTITY_FILE" ]; then . "$IDENTITY_FILE"; fi
git init --quiet "$ORCA_PROJECT_ROOT"
cd "$ORCA_PROJECT_ROOT"
git fetch --quiet --update-head-ok "$BUNDLE_FILE" "refs/heads/*:refs/heads/*" "refs/remotes/origin/*:refs/remotes/origin/*" "refs/tags/*:refs/tags/*"
rm -f "$BUNDLE_FILE"; sudo rm -f "$IDENTITY_FILE"
if git show-ref --verify --quiet "refs/heads/$ORCA_REPO_REF"; then
  git switch --quiet "$ORCA_REPO_REF"
else
  git checkout --quiet --detach "$ORCA_REPO_REF"
fi
if [ -n "${ORCA_REPO_URL:-}" ]; then
  git remote add origin "$ORCA_REPO_URL"
  if [ -n "${ORCA_ORIGIN_HEAD:-}" ]; then git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/$ORCA_ORIGIN_HEAD"; fi
  # Track origin like the local branch does, when origin has a branch of that name.
  if git show-ref --verify --quiet "refs/remotes/origin/$ORCA_REPO_REF"; then git branch --quiet --set-upstream-to "origin/$ORCA_REPO_REF"; fi
fi
if [ -n "${GIT_USER_NAME:-}" ]; then git config --global user.name "$GIT_USER_NAME"; fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then git config --global user.email "$GIT_USER_EMAIL"; fi
# Claude Code: skip the first-run screens. People sign it in from Orca (Settings > Accounts).
node -e "
  const fs = require(\"node:fs\"), p = process.env.HOME + \"/.claude.json\";
  let c = {}; try { c = JSON.parse(fs.readFileSync(p, \"utf8\")); } catch {}
  c.hasCompletedOnboarding = true; fs.writeFileSync(p, JSON.stringify(c, null, 2));
"
echo "[sprites]       done (${SECONDS}s, $(git rev-parse --short HEAD))" >&2'

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
# Claude Code: trust the project folder, so the first run does not stop at the trust prompt.
node -e "
  const fs = require(\"node:fs\"), p = process.env.HOME + \"/.claude.json\";
  let c = {}; try { c = JSON.parse(fs.readFileSync(p, \"utf8\")); } catch {}
  c.projects = c.projects || {};
  c.projects[process.env.ORCA_PROJECT_ROOT] = { ...(c.projects[process.env.ORCA_PROJECT_ROOT] || {}), hasTrustDialogAccepted: true };
  fs.writeFileSync(p, JSON.stringify(c, null, 2), { mode: 0o600 });
"
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
printf "#!/bin/bash\nexec %q serve --supervise %s\n" "$(command -v orca-ide)" "$(printf "%q " "${serve_args[@]}")" > "$serve_script"
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
  # sprite_url's die only ends its $(...) subshell, so stop here when the lookup fails.
  local url
  url="$(sprite_url "$1")" || exit 1
  [ -z "$url" ] || die "a Sprite named $1 already exists; not touching it"
}

# new_sprite <name>: create a Sprite.
new_sprite() {
  local name="$1"
  step 1 "Creating Sprite $name in $org"
  local out rc=0
  out="$(sp create --skip-console --label orca-recipe "$name" 2>&1)" || rc=$?
  # Restricted tokens cannot set labels; the label only tags the Sprite, so create it without.
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'cannot set labels'; then
    rc=0; out="$(sp create --skip-console "$name" 2>&1)" || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    # Drop the CLI's boxed "try the API" tip; keep its error.
    printf '%s\n' "$out" | { grep -v -e '^│' -e '^[[:space:]]*$' || true; } >&2
    case "$out" in
      *[Uu]nauthori[sz]ed*|*[Ii]nvalid\ token*|*[Nn]ot\ logged\ in*|*[Tt]oken\ *expired*|*[Tt]oken\ has\ expired*)
        log "error: the sprite CLI is not signed in to $org. Run sprite login, or set SPRITE_TOKEN where Orca starts." ;;
    esac
    return "$rc"
  fi
  step_done
}

# build_sprite <name>: give a new Sprite a public URL, install Orca, check out the repo.
build_sprite() {
  local name="$1"
  local out
  out="$(sp config update --url-auth public "$name" 2>&1)" || { printf '%s\n' "$out" >&2; die "could not give Sprite $name a public URL"; }
  with_checkout "$name" "ORCA_VERSION=$orca_version,ORCA_INSTALL=$install_mode,ORCA_REPO_URL=$repo_url,ORCA_REPO_REF=$repo_ref,ORCA_ORIGIN_HEAD=$origin_head,ORCA_PROJECT_ROOT=$project_root" \
    bash -lc "$remote_build" >&2
}

remote_env() {
  local url="$1"
  printf 'ORCA_PORT=%s,ORCA_PROJECT_ROOT=%s,ORCA_REPO_REF=%s,ORCA_PAIRING_ADDRESS=%s,SERVICE=%s,RECIPE_FILE=%s' \
    "$port" "$project_root" "$repo_ref" "${url/https:\/\//wss://}" "$service_name" "$recipe_file"
}

# serve_sprite <name>: start orca serve on a built Sprite and print its recipe JSON.
serve_sprite() {
  local name="$1" url
  url="$(sprite_url "$name")"; [ -n "$url" ] || die "no URL for Sprite $name"
  step 4 "Starting Orca on the Sprite"
  rexec "$name" --env "$(remote_env "$url")" -- bash -lc "$remote_serve"
  step_done
  log "[5/5] Ready in $(( $(date +%s) - create_started ))s: $url"
  log "Next: sign Claude in on this Sprite. Settings > Host: this workspace's VM > Accounts > Claude > Add Account"
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

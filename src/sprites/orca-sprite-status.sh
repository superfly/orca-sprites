#!/usr/bin/env bash
# orca-sprite-status [--banner]: what this workspace's Sprite still needs, and how to do it.
# Installed on each workspace's Sprite by the Fly.io Sprites Orca plugin (scripts/build.mjs
# embeds this file in the recipe). New terminals run it with --banner: one line when
# everything is set up, a short checklist when something is not.
set -u

info="$HOME/.orca-sprite.env"
# shellcheck disable=SC1090
[ -f "$info" ] && . "$info"
banner=0
[ "${1:-}" = --banner ] && banner=1

if [ -t 1 ]; then
  bold=$'\e[1m' dim=$'\e[2m' green=$'\e[32m' yellow=$'\e[33m' reset=$'\e[0m'
else
  bold='' dim='' green='' yellow='' reset=''
fi
ok="${green}✓${reset}" todo="${yellow}!${reset}"

# The entry for this workspace in Orca's Settings > Host menu.
host="${ORCA_REPO_NAME:-this repository} VM${ORCA_VM_ID:+ $ORCA_VM_ID}"

# Claude: follow Orca's account pointer, as Orca's own `claude` shell function does, so a
# managed account chosen in Settings > Accounts is what gets checked.
claude_status() {
  local dir="" out
  if [ -n "${ORCA_CLAUDE_PROFILE_POINTER:-}" ] && [ -s "${ORCA_CLAUDE_PROFILE_POINTER/#\~/$HOME}" ]; then
    dir="$(cat "${ORCA_CLAUDE_PROFILE_POINTER/#\~/$HOME}")"
  fi
  command -v claude >/dev/null 2>&1 || return 1
  # --foreground: in an interactive terminal, plain timeout runs claude in a background process
  # group, where touching the terminal stops it (and timeout with it) instead of timing out.
  out="$(CLAUDE_CONFIG_DIR="${dir:-${CLAUDE_CONFIG_DIR:-}}" timeout --foreground 8 claude auth status --json </dev/null 2>/dev/null)" || return 1
  [ "$(printf '%s' "$out" | jq -r '.loggedIn // false' 2>/dev/null)" = true ] || return 1
  printf '%s' "$out" | jq -r '[.email, .subscriptionType] | map(select(. != null and . != "")) | join(", ")' 2>/dev/null
}

# GitHub: pushing from the workspace needs the gh login (it also sets up git's credentials).
github_status() {
  local origin
  origin="$(git -C "${ORCA_PROJECT_ROOT:-$PWD}" remote get-url origin 2>/dev/null || true)"
  case "$origin" in *github.com*) ;; *) return 2 ;; esac
  command -v gh >/dev/null 2>&1 || return 1
  gh auth status --hostname github.com </dev/null >/dev/null 2>&1 || return 1
  gh auth status --hostname github.com </dev/null 2>&1 | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -n 1
}

claude_who="" claude_ok=0 gh_who="" gh_rc=0
claude_who="$(claude_status)" && claude_ok=1
gh_who="$(github_status)" || gh_rc=$?

if [ "$banner" = 1 ] && [ "$claude_ok" = 1 ] && [ "$gh_rc" != 1 ]; then
  line="${dim}Sprite ${ORCA_SPRITE_NAME:-$(hostname)} · Claude ✓${claude_who:+ $claude_who}"
  [ "$gh_rc" = 0 ] && line="$line · GitHub ✓${gh_who:+ $gh_who}"
  printf '%s · orca-sprite-status for details%s\n' "$line" "$reset"
  exit 0
fi

printf '%sSprite %s%s' "$bold" "${ORCA_SPRITE_NAME:-$(hostname)}" "$reset"
[ -n "${ORCA_SPRITE_URL:-}" ] && printf ' %s%s%s' "$dim" "$ORCA_SPRITE_URL" "$reset"
printf '\n'
if [ "$claude_ok" = 1 ]; then
  printf '  %s Claude signed in%s\n' "$ok" "${claude_who:+: $claude_who}"
else
  printf '  %s Claude is not signed in on this Sprite. In Orca:\n' "$todo"
  printf '      Settings > Host: %s%s%s > Accounts > Claude > Add Account,\n' "$bold" "$host" "$reset"
  printf '      then select the new account. Or run %sclaude%s here and log in.\n' "$bold" "$reset"
fi
case "$gh_rc" in
  0) printf '  %s GitHub signed in%s\n' "$ok" "${gh_who:+: $gh_who}" ;;
  1) printf '  %s To push and open pull requests from here, run %sgh auth login%s\n' "$todo" "$bold" "$reset" ;;
esac
if [ "$banner" = 1 ]; then
  printf '  %sRun orca-sprite-status to check again.%s\n' "$dim" "$reset"
fi
exit 0

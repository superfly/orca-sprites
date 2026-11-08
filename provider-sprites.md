# Sprites recipe: design notes

How the Sprites recipe for [Orca](https://github.com/stablyai/orca) works and why. It follows
Orca's per-workspace environment guide
([`orca-per-workspace-env.md`](https://github.com/stablyai/orca/blob/main/skill-guides/orca-per-workspace-env.md))
and its Vercel Sandbox example
([`provider-vercel.md`](https://github.com/stablyai/orca/blob/main/skill-guides/orca-per-workspace-env/references/provider-vercel.md)),
using `sprite create|exec|config|destroy` on the desktop and `sprite-env services` inside the
Sprite.

This is the Orca-server connection mode. Sprites have no SSH target that can be dialed, so SSH
mode does not apply.

## How Sprites differ from a snapshot provider

| Orca guide step | Sprites |
|---|---|
| Base snapshot, boot each workspace from it | Not used. A checkpoint belongs to one Sprite, and there is no create-from-checkpoint. `create` builds each Sprite: it installs the Orca `.deb` and checks out the repo from a bundle made on the desktop. Each workspace has its own Sprite, so no two workspaces share a pairing identity. |
| Agent-auth snapshot | Not needed, and the recipe sends no agent credential. People sign in per workspace with Orca's own accounts: Settings → Host (the workspace's VM) → Accounts → Add Account, which runs the agent's login on the Sprite and finishes in the desktop browser. A desktop login is never copied: Claude's refresh token rotates, so two copies sign each other out (tested). The recipe sends no secrets at all: the repository arrives as a git bundle from the desktop, so no git token is needed. |
| Published port | Each Sprite has one URL, `https://<name>-<slug>.sprites.app` (the slug is fixed per org; read the URL from `sprite --json list`), that routes to port 8080. Set its auth to `public`, and the pairing code is the credential. See "Why the URL is public". |
| Keep `orca serve` running | A Sprite service running `orca serve --supervise`, with `--restart always` and `--http-port 8080`. The Sprite sleeps when idle and starts services again on the next request. Because the port is declared, the request that wakes the Sprite waits until the server listens instead of failing with 502. |
| `suspend` / `resume` | `suspend` stops the service, so no connection keeps the Sprite awake and it sleeps. `resume` starts the service and prints the saved recipe JSON. The URL and pairing identity do not change. |
| `destroy` | `sprite destroy --force` |

## Why `create` runs `orca serve` twice

`orca serve --recipe-json` starts a **detached** server, prints the recipe JSON and returns.
A detached server is not a service, so it does not come back after the Sprite sleeps.
Running it under a service with `--restart always` fails too: the service manager restarts
the exited foreground process, and the new one fails on the lock the detached server holds
(Orca 1.4.246 logged "Orca serve exited before printing valid recipe JSON with code 78"). It also truncates the recipe JSON file each time. `--recipe-json`
cannot be combined with `--supervise`, and a supervised server hides its pairing URL when it
is not writing to a terminal.

So `create`:

1. runs `orca serve --recipe-json` once and saves the JSON to `~/.orca-recipe.json`;
2. stops that server by the PIDs in its own lock files (`~/.config/orca/orcad.lock` and
   `daemon/daemon-v*.pid`), and checks each PID's start time against the lock file first;
3. waits until port 8080 is free, and fails if it is not, because a supervised server waits
   while another Orca serves the profile;
4. creates the `orca` service, `orca serve --supervise` with the same flags.

The pairing identity is on disk in `~/.config/orca`, so the code from step 1 works against
the supervised server and after every wake.

## Why the URL is public

With the default `sprite` URL auth, the Sprites edge accepts a request only with an org token,
sent as `Authorization: Bearer <token>` or as HTTP Basic auth with the token as the password.
Orca's desktop and CLI client opens the WebSocket with only `maxPayload` and
`handshakeTimeout` set, so it cannot add a `Bearer` header. Putting the token into the pairing
address as `wss://x:<token>@host` would likely pass the edge as Basic auth, but the pairing
code would then carry an org-wide token: whoever holds the code could manage every Sprite in
the org. Browser-based Orca clients may not send URL credentials at all. A public URL keeps
the pairing code scoped to one Orca server, which matches Orca's Vercel Sandbox example. A token
scoped to one Sprite's URL would change this trade-off.

## Packaging: an Orca plugin

The recipe ships as a **declarative** Orca plugin: `orca-plugin.json` contributes
`recipes/sprites.json` through `contributes.vmRecipes`, so Sprites appears under Run on for
every repository and nothing is copied into repos. Orca asks once to approve the recipe's
commands; there is no plugin worker and no host-API capability.

A plugin recipe must be self-contained (each command is a string of at most 32 KiB), so
`scripts/build.mjs` inlines `src/sprites/lib.sh` into each phase and wraps it as
`bash -c '<script>' sprites-<phase>`, with each `'` written as `'\''`. Orca runs every phase
with `sh -c` in the repository's root: dash on Debian and Ubuntu, bash 3.2 on macOS. The
script travels as one argument, so stdin stays free for the lifecycle payload. A heredoc
inside `$(...)` is not used: bash 3.2 misparses an apostrophe in one.

| Source | Does |
|---|---|
| `src/sprites/lib.sh` | Settings, the `sprite` wrappers and the remote fragments |
| `src/sprites/create.sh` | Builds a Sprite, starts the `orca` service, prints the recipe JSON. Destroys the Sprite if any step fails. |
| `src/sprites/suspend.sh` | Stops the `orca` service |
| `src/sprites/resume.sh` | Starts the `orca` service, prints the saved recipe JSON |
| `src/sprites/destroy.sh` | Destroys the Sprite. It succeeds if the Sprite is already gone. |

There is no state file. `create` takes its settings from what the desktop already knows: the
local repository (its checked-out branch, its `origin` remote and `origin/HEAD`), the desktop
Orca CLI's version, and the `sprite` CLI's default organization. Orca sets `ORCA_REPO_URL`, `ORCA_REPO_REF` and `ORCA_VERSION` only for
`provisioned-root` recipes, or not at all, so the recipe does not rely on them. `SPRITES_*` variables override each one; see the README. The
lifecycle phases take the Sprite name and organization from `userData` in the payload.

Prerequisites on the desktop: the `sprite` CLI logged in to the org (`sprite login`, or
`SPRITE_TOKEN` in the environment), `node` and `git`. An Orca started from the Dock or a desktop launcher does
not see shell exports: start Orca from a terminal, or set the variables with `launchctl setenv`.

### The checkout comes from the desktop

Orca does not tell a non-`provisioned-root` recipe which commit or branch the workspace is for;
it creates the workspace's worktree itself, inside the checkout at `projectRoot`, from the base
ref picked in the dialog. So that checkout must hold every ref the desktop could offer as a
base. `create` bundles the local repo's branches, `origin`'s branches, tags and `HEAD` (by full ref name: `--branches --tags` silently drops a branch and a tag that share a name) and
the Sprite fetches it into a fresh repository with the same ref names (`refs/heads/*`,
`refs/remotes/origin/*`, `refs/tags/*`), sets `origin` to the remote's HTTPS URL and
`origin/HEAD` as it is locally, and checks out the local branch. Tested: a workspace based on
a local branch with an unpushed commit has that commit; a repository with no remote works.

No git token reaches the Sprite. `git fetch` and `git push` in the workspace need their own
credentials (for example `gh auth login` in a workspace terminal). The local `user.name` and
`user.email` are copied to the Sprite's global git config. Uncommitted changes are not sent;
the provisioning log says so when there are some.

## `create`

```bash
# refuse if a Sprite with this name exists, so cleanup can never destroy someone else's
sprite -o "$org" create --skip-console --label orca-recipe "$name"
trap cleanup EXIT   # armed after create: destroys the Sprite if anything below fails
sprite -o "$org" config update --url-auth public "$name"
git for-each-ref refs/heads refs/remotes/origin refs/tags + HEAD | git bundle create "$tmp/repo.bundle" --stdin
# the bundle goes over stdin: --file uploads of 32 MB and more fail with HTTP 413.
# The git identity (user.name, user.email) is a small --file upload.
# remote: save the bundle, apt-get update, install the orca-ide .deb, git init + fetch the bundle
sprite -o "$org" exec -s "$name" --stdin --no-port-forward --file "$tmp/identity.env:/tmp/orca-identity-….env" \
  --env "ORCA_VERSION=…,ORCA_REPO_URL=…,ORCA_REPO_REF=<local branch>,…" -- bash -lc "$remote_build" < "$tmp/repo.bundle"
url="$(sprite -o "$org" --json list --prefix "$name" | …)"   # https://<name>-<slug>.sprites.app
# remote: mark the project folder trusted for Claude Code; then
orca-ide serve --port 8080 --project-root "$PROJECT_ROOT" \
  --pairing-address "wss://<name>-<slug>.sprites.app" --recipe-json > ~/.orca-recipe.json
# remote: stop that detached server by its lock-file PIDs, wait for port 8080 to be free, then
# ~/.orca-serve.sh: exec orca-ide serve --supervise --port 8080 --project-root … --pairing-address …
sprite-env services create orca --cmd ~/.orca-serve.sh --http-port 8080 --dir "$HOME" \
  [--restart always]   # only where sprite-env supports it; older sprite-env restarts on wake anyway
# remote: wait for port 8080, print ~/.orca-recipe.json
# desktop: merge userData { provider: "sprites", resourceId, org } and print
```

Pass the full `wss://` URL to `--pairing-address`. A host name alone gives
`ws://<host>:8080`, which the client cannot reach.

## Gotchas

- **`exit` in `bash -lc` with `set -e` always returns 1 on the Sprite image.** The login shell
  runs `~/.bash_logout`, whose `clear_console` fails without a TTY. Remote fragments end on the
  status of their last command and use `return` inside functions.
- **`apt-get update` before installing the `.deb`.** Without it, `libgtk-3-0` does not resolve.
- **Do not stop processes with `pkill -f`.** The pattern can match the exec shell itself. Stop
  by PID, or use `sprite-env services stop|delete`.
- **Declare the service port.** Without `--http-port`, the request that wakes a Sprite gets a 502
  while the server starts. With it, the request waits.
- **`sudo -E` is ignored on the Sprite image.** Pass variables explicitly:
  `sudo DEBIAN_FRONTEND=noninteractive apt-get …`.
- **Pass `--no-port-forward` to `sprite exec`.** Otherwise the CLI forwards ports the command
  opens, such as 8080, to the desktop.
- **`sprite exec --file` uploads land root-owned with mode 0644.** Delete them with `sudo rm`.
- **Lifecycle scripts must fail when `sprite` fails.** Treat a Sprite as gone only when
  `sprite destroy` says "sprite not found". An expired login must not be reported as a
  successful destroy.
- **Sprite names are at most 55 characters.** Orca's `ORCA_VM_INSTANCE_ID` is a UUID, so the
  name carries a 12-character hash of it instead.
- **Claude Code first-run prompts.** The build step skips onboarding and the serve step marks
  the project folder as trusted. With Orca's default Yolo mode, Claude Code still asks once to
  accept `--dangerously-skip-permissions`; the recipe leaves that choice to the user.
- `sprite exec` returns the remote exit code.
- `sprite exec --env` takes `KEY=value,KEY2=value2`, so values must not contain commas. The
  scripts refuse such values.

## Measured

Two workspaces created in parallel on 2026-11-06 on the Ubuntu 26.04 Sprite image,
Orca 1.4.246, `octocat/Hello-World`. The desktop side ran on another Sprite. Single runs, not
benchmarks.

| Step | Workspace A | Workspace B |
|---|---|---|
| `create` (new Sprite, install, clone, serve; measured before the bundle checkout) | 81.5 s | 73.6 s |
| First pair from the client | 8.7 s | 7.8 s |
| **`create` to paired client** | **91.0 s** | **81.6 s** |
| Idle until the Sprite sleeps (`warm`) | 27.4 s | 27.0 s |
| Pair on wake, old code, retrying every 2 s | 27.9 s (3rd try) | 28.7 s (3rd try) |
| `suspend` | 0.7 s | 1.6 s |
| `resume` | 7.4 s | 6.8 s |
| Pair after `resume`, old code | 8.4 s (1st try) | 7.7 s (1st try) |
| Same endpoint after `resume` | yes | yes |
| Distinct `deviceToken` / `pairedDeviceId` | yes | yes |

Most of `create` is installing the 188 MB `orca-ide` `.deb` (about 50 s with `apt-get
update`). Each `orca-ide status` call takes 5 to 8 s, including CLI start.

Those runs predate declaring the service port. After adding `--http-port 8080`, a single run
measured: `create` to paired client 75.6 s, pair on wake 20.3 s (3rd try), `resume` 8.3 s,
pair after `resume` 9.2 s (1st try). With the port declared, the edge holds the waking
request until the server listens, but Orca's client gives up on a connection after 12 s
(`REMOTE_RUNTIME_CONNECT_TIMEOUT_MS`), so the first attempts after a wake still time out. A
client that retries reconnects in about 20 s.

`orca vm recipe doctor sprites --provision` passed in 72 s, and in 78 s after the changes
(create, validate, destroy).

## Checks

`orca vm recipe doctor` reads recipes from a repository's `orca.yaml`, so it does not cover a
plugin recipe. Instead:

```bash
node scripts/build.mjs --check                   # recipes/sprites.json matches src/
orca plugin validate . --json                    # manifest and recipe, as Orca loads them
orca plugin inspect . --json                     # what it contributes and asks to approve
dev/run-phase.sh create <repo> < /dev/null       # one phase, run the way Orca runs it
dev/lifecycle-test.sh <repo>                     # create, wake, suspend, resume, destroy
```

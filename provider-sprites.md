# Worked example — Sprites

Load this when writing the `create` or lifecycle scripts for [Sprites](https://sprites.dev),
the persistent Linux VMs from Fly.io. It fills section 7's skeletons with a real surface:
`sprite create|exec|config|destroy` on the desktop and `sprite-env services` inside the Sprite.
Verify each flag against `sprite <command> --help` for the user's CLI version.

This is the Orca-server connection mode. Sprites have no SSH target that can be dialed, so SSH
mode does not apply.

## How Sprites differ from a snapshot provider

| Guide step | Sprites |
|---|---|
| Base snapshot, boot each workspace from it | Not used. A checkpoint belongs to one Sprite, and there is no create-from-checkpoint. `create` builds each Sprite: it installs the Orca `.deb` and clones the repo. Each workspace has its own Sprite, so no two workspaces share a pairing identity. |
| Agent-auth snapshot | Not needed. `create` sends the agent credential from the desktop environment (`CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, or `ANTHROPIC_API_KEY`) into a `0600` file on the Sprite. It is never in state or `userData`. |
| Published port | Each Sprite has one URL, `https://<name>-<org-slug>.sprites.app`, that routes to port 8080. Set its auth to `public`: the Orca client cannot send Sprites auth headers, and the pairing code is the credential. |
| Keep `orca serve` running | A Sprite service running `orca serve --supervise`, with `--restart always`. The Sprite sleeps when idle and starts services again on the next request, so the server comes back on wake. |
| `suspend` / `resume` | `suspend` stops the service, so no connection keeps the Sprite awake and it sleeps. `resume` starts the service and prints the saved recipe JSON. The URL and pairing identity do not change. |
| `destroy` | `sprite destroy --force` |

## Why `create` runs `orca serve` twice

`orca serve --recipe-json` starts a **detached** server, prints the recipe JSON and returns.
A detached server is not a service, so it does not come back after the Sprite sleeps.
Running it under a service with `--restart always` fails too: the service manager restarts
the exited foreground process, and the new one exits with code 78 because the detached
server holds the lock. It also truncates the recipe JSON file each time. `--recipe-json`
cannot be combined with `--supervise`, and a supervised server hides its pairing URL when it
is not writing to a terminal.

So `create`:

1. runs `orca serve --recipe-json` once and saves the JSON to `~/.orca-recipe.json`;
2. stops that server by the PIDs in its own lock files (`~/.config/orca/orcad.lock` and
   `daemon/daemon-v*.pid`), and checks each PID's start time against the lock file first;
3. creates the `orca` service, `orca serve --supervise` with the same flags.

The pairing identity is on disk in `~/.config/orca`, so the code from step 1 works against
the supervised server and after every wake.

## Scripts

| File | Does |
|---|---|
| `sprites-lib.sh` | Settings (env, then `sprites-state.json`, then default), remote fragments |
| `sprites-create.sh` | Builds a Sprite, starts the `orca` service, prints the recipe JSON. Destroys the Sprite if any step fails. |
| `sprites-suspend.sh` | Stops the `orca` service |
| `sprites-resume.sh` | Starts the `orca` service, prints the saved recipe JSON |
| `sprites-destroy.sh` | Destroys the Sprite. It succeeds if the Sprite is already gone. |

State (`scripts/orca-vm/sprites-state.json`) holds only non-secret wiring:

```json
{
  "org": "<sprites-org>",
  "repoUrl": "https://github.com/<owner>/<repo>",
  "repoRef": "main",
  "projectRoot": "/home/sprite/project",
  "orcaVersion": "1.4.246",
  "namePrefix": "orca"
}
```

Prerequisites on the desktop: the `sprite` CLI logged in to the org (`sprite login`, or
`SPRITE_TOKEN` in the environment), `node`, the agent credential in the environment Orca
starts from, and for a private repo `GH_TOKEN`, `GITHUB_TOKEN` or `gh auth token`.

## `create`

```bash
trap cleanup EXIT   # destroys the Sprite if anything below fails
sprite -o "$org" create --skip-console --label orca-recipe "$name"
sprite -o "$org" config update --url-auth public "$name"
# remote: apt-get update, install the orca-ide .deb, clone with GIT_ASKPASS
sprite -o "$org" exec -s "$name" --no-stdin --env "ORCA_VERSION=…,ORCA_REPO_URL=…,GH_TOKEN=…" -- bash -lc "$remote_build"
url="$(sprite -o "$org" --json list --prefix "$name" | …)"   # https://<name>-<slug>.sprites.app
# remote: write ~/.orca-agent.env (0600); then
orca-ide serve --port 8080 --project-root "$PROJECT_ROOT" \
  --pairing-address "wss://<name>-<slug>.sprites.app" --recipe-json > ~/.orca-recipe.json
# remote: stop that detached server by its lock-file PIDs, then
sprite-env services create orca --restart always --dir "$HOME" -- /bin/bash -c \
  ". ~/.orca-agent.env; exec orca-ide serve --supervise --port 8080 --project-root … --pairing-address …"
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
- `sprite exec` returns the remote exit code.
- `sprite exec --env` takes `KEY=value,KEY2=value2`, so values must not contain commas.

## Measured

Two workspaces created in parallel on 2026-11-06 on the Ubuntu 26.04 Sprite image,
Orca 1.4.246, `octocat/Hello-World`. The desktop side ran on another Sprite. Single runs, not
benchmarks.

| Step | Workspace A | Workspace B |
|---|---|---|
| `create` (new Sprite, install, clone, serve) | 81.5 s | 73.6 s |
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
update`). Each `orca-ide status` call takes 5 to 8 s, including CLI start. On wake, the first
two attempts fail while the Sprite boots and `orca serve --supervise` starts. A client that
retries reconnects in under 30 s.

`orca vm recipe doctor sprites --provision` passed in 72 s (create, validate, destroy).

## Doctor

```bash
orca vm recipe doctor sprites --repo-path . --json             # static: no fail, no warn
orca vm recipe doctor sprites --repo-path . --provision --json # create, validate, destroy
```

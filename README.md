# Sprites for Orca

An [Orca](https://github.com/stablyai/orca) plugin that runs each workspace in its own
[Sprite](https://sprites.dev), a persistent Linux VM from Fly.io. It adds **Sprites** under
**Run on → Per-Workspace Environment** for every repository. Nothing is added to your repos.

When you create a workspace on Sprites, the recipe:

1. creates a Sprite and gives it a public URL,
2. installs Orca on it and clones your repository,
3. starts `orca serve` as a Sprite service, so it comes back after the Sprite sleeps,
4. returns the pairing code, and Orca connects over the Sprite's URL.

Suspending the workspace stops `orca serve` so the Sprite sleeps. Deleting it destroys the
Sprite.

## Install

1. Install the [`sprite` CLI](https://docs.sprites.dev) and run `sprite login`, or export
   `SPRITE_TOKEN`. You also need `node` and `git`.
2. In Orca, open **Settings → Plugins → Install from link** and enter
   `https://github.com/superfly/orca-sprites`. Approve the recipe when Orca asks.
3. Turn on **Settings → Experimental → Cloud VM**.
4. Give the agent a credential in the environment Orca starts from:
   `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY`. On macOS a
   Dock-launched Orca does not see shell exports; start Orca from a terminal or use
   `launchctl setenv`.
5. Create a workspace and pick **Run on → Per-Workspace Environment → Sprites**.

The repository must have an `origin` remote that the Sprite can clone over HTTPS. For a
private repository, set `GH_TOKEN` or `GITHUB_TOKEN`, or be logged in with `gh`. The token is
used for the clone and is not left on the Sprite.

## Settings

Everything has a default. To change one, set the variable in the environment Orca starts from.

| Variable | Default |
|---|---|
| `SPRITES_ORG` | The `sprite` CLI's default organization |
| `SPRITES_REPO_URL` | The repository's `origin` remote |
| `SPRITES_REPO_REF` | The workspace's base branch, then `origin`'s default branch |
| `SPRITES_PROJECT_ROOT` | `/home/sprite/<repository name>` |
| `SPRITES_ORCA_VERSION` | The version of Orca you are running |
| `SPRITES_NAME_PREFIX` | `orca` |

Each workspace's Sprite has a **public** URL. The Orca client cannot send Sprites auth
headers, so the pairing code is the credential: keep it private. See
[provider-sprites.md](provider-sprites.md) for why, and for the design and measured timings.

## Develop

The recipe's scripts are in `src/sprites/`. Orca reads `recipes/sprites.json`, which
`scripts/build.mjs` builds from them, because a plugin recipe must be self-contained:

```bash
node scripts/build.mjs            # rebuild recipes/sprites.json
node scripts/build.mjs --check    # fail if it is stale
orca plugin validate . --json
orca plugin dev load .            # load this folder into Orca
```

`dev/run-phase.sh <phase> <repo>` runs one phase of the built recipe the way Orca does, and
`dev/lifecycle-test.sh <repo>` runs create, idle wake, suspend, resume and destroy against a
real Orca client.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/lockup-dark.svg">
    <img alt="Fly.io and Orca" src="docs/lockup-light.svg" width="300">
  </picture>
</p>

<h1 align="center">Sprites for Orca</h1>

<p align="center">
  Run each <a href="https://github.com/stablyai/orca">Orca</a> workspace in its own Sprite,
  a persistent Linux VM from <a href="https://fly.io">Fly.io</a>.
</p>

An [Orca](https://github.com/stablyai/orca) plugin that runs each workspace in its own
[Sprite](https://fly.io/sprites), a persistent Linux VM from Fly.io. It adds **Sprites** under
**Run on → Per-Workspace Environment** for every repository. Nothing is added to your repos.

When you create a workspace on Sprites, the recipe:

1. creates a Sprite and gives it a public URL,
2. installs Orca on it and copies your repository from this computer,
3. starts `orca serve` as a Sprite service, so it comes back after the Sprite sleeps,
4. returns the pairing code, and Orca connects over the Sprite's URL.

Suspending the workspace stops `orca serve` so the Sprite sleeps. Deleting it destroys the
Sprite.

## Install

1. Install the [`sprite` CLI](https://docs.fly.io/sprites) and run `sprite login`, or export
   `SPRITE_TOKEN`. You also need `node` and `git`.
2. In Orca, open **Settings → Plugins → Add plugin → From a Git URL…**, enter
   `https://github.com/superfly/orca-sprites`, then **Continue** and **Install**. Orca asks
   you to confirm that you trust the publisher. Then turn the plugin on.
3. Turn on **Settings → Experimental → Cloud VM**.
4. Start Orca from a terminal if `sprite`, `node` and `git` are not in standard locations: an
   Orca started from the Dock or a desktop launcher does not see your shell's `PATH`.
5. Create a workspace and pick **Run on → Per-Workspace Environment → Sprites**.
6. Sign Claude in on that workspace's Sprite, once per workspace:
   1. Open **Settings** and, in the **Host** menu at the top, choose the workspace's VM (for
      example `my-repo VM e33a460e`).
   2. Under **Accounts → Claude**, click **Add Account**. Sign in in your browser, then paste
      the code it shows back into Orca.
   3. Select the new account, in that list or in the status bar's account menu. New Claude
      terminals in the workspace use it.

   The login stays on that Sprite and uses your Claude plan. It is separate from your login
   on this computer, so neither signs the other out. Do not copy a Claude login from one
   machine to another: its refresh token rotates, and the two copies sign each other out.

The Sprite gets your repository from this computer, not from GitHub: your branches (including
commits you have not pushed), `origin`'s branches and your tags, checked out on the branch you
have checked out here. It needs no git token, so private repositories and repositories with no
remote work too. Uncommitted changes stay on this computer. Commits on the Sprite use your
`user.name` and `user.email`. `origin` points at the same repository over HTTPS.

By default no Git token leaves this computer, so the Sprite cannot fetch from a private
repository or push. To push from one Sprite, run `gh auth login` in a workspace terminal. To
give every new Sprite a Git sign-in, set `SPRITES_GIT_TOKEN` (see [Git access](#git-access)).

## Settings

Everything has a default. To change one, set the variable in the environment Orca starts from.

| Variable | Default |
|---|---|
| `SPRITES_ORG` | The `sprite` CLI's default organization |
| `SPRITES_PROJECT_ROOT` | `/home/sprite/<repository name>` |
| `SPRITES_ORCA_VERSION` | The version of your Orca app: `Orca.app` on macOS, the `orca-ide` package on Linux, else the Orca CLI. Else 1.4.256. Step 2 of the provisioning log says where the version came from. |
| `SPRITES_NAME_PREFIX` | `orca` |
| `SPRITES_GIT_TOKEN` | Not set: no Git token is sent. Set it to a token, or to `gh` for this computer's GitHub CLI login, to give each new Sprite a Git sign-in. See [Git access](#git-access). |
| `SPRITES_BROWSER` | Off: the Sprite gets only Orca's server, from Orca's server-only build when the release has one. Set to `1` for Orca's per-workspace browser: the Sprite then installs Orca's whole desktop app, which takes about a minute longer. |

Each workspace's Sprite has a **public** URL. The Orca client cannot send Sprites auth
headers, so the pairing code is the credential: keep it private. See
[provider-sprites.md](provider-sprites.md) for why, and for the design and measured timings.

## Git access

Orca 1.4.256 and later check each new VM before they open the workspace. One check is that the
VM can fetch from `origin` and push to it. A Sprite has no Git sign-in by default, so Orca stops
on "The VM is up, but its environment checks failed" with "Cannot reach remote" or "A dry-run
push was refused". You have two choices:

- **Open anyway.** The workspace opens on the Sprite and works. Only fetching and pushing from
  the Sprite need a sign-in, which you can add later with `gh auth login` in a workspace terminal.
- **Set `SPRITES_GIT_TOKEN`** in the environment Orca starts from. Each new Sprite then stores
  the token as its Git sign-in for `origin`'s host, and the check passes when the token can
  push to the repository. It is made for GitHub and GitHub Enterprise tokens.
  - `SPRITES_GIT_TOKEN=<token>` sends that token. For GitHub, a
    [fine-grained token](https://github.com/settings/personal-access-tokens) limited to the
    repositories you use, with read and write access to Contents, is enough.
  - `SPRITES_GIT_TOKEN=gh` sends the token of this computer's GitHub CLI login
    (`gh auth token`). That token usually reaches every repository you can.

The token stays on the Sprite, in `~/.git-credentials`, until the workspace is deleted. Every
agent and terminal on that Sprite can use it, and the Sprite's URL is public (Orca's pairing code
is what protects it). So prefer a token that can do only what the Sprite needs. A new token
reaches only Sprites created after you set it.

## Troubleshooting

- **"The VM is up, but its environment checks failed".** If the failed check is about the Git
  remote, see [Git access](#git-access). Choose **Open anyway** to use the workspace as it is.
- **The Sprite runs a different Orca version from your desktop.** Step 2 of the provisioning log
  says where the version came from. If it says the recipe's default, the recipe could not find
  your Orca app or CLI. Set `SPRITES_ORCA_VERSION` to the version in Orca > About Orca.
- **A workspace failed and the Sprite is still there.** The recipe destroys the Sprite when
  `create` fails, but if you cancel a workspace while it is being created, Orca may stop the
  recipe before that finishes. List leftovers with `sprite list --prefix orca-` and remove
  one with `sprite destroy --force <name>`.
- **"the sprite CLI is not on PATH"** or **"node is not on PATH"**: Orca does not see your
  shell's `PATH`. Start Orca from a terminal.
- **"no Sprites org"**: run `sprite login`, or set `SPRITES_ORG`.
- **An account added in Orca does not seem to take effect.** Workspaces created with plugin
  version 0.1.5 or earlier still get the old `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY`
  from `~/.orca-agent.env` on the Sprite. Delete and recreate the workspace, or remove that
  file on the Sprite and restart the workspace.

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

## License

MIT. See [LICENSE](LICENSE).

The cover illustration in `images/cover.jpg` is by Annie Ruygt for Fly.io and is not covered by
the MIT license.

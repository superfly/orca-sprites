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

A Sprite stays awake while a connection is open or one of its own terminal sessions prints
output. Orca's terminals run inside Orca's server, a Sprite service the Sprite does not watch
for output, so once Orca disconnects the Sprite would sleep and stop the agent. So while Orca
reports an agent on the Sprite as working, a small service on the Sprite keeps it awake, even
after you close Orca or your laptop. The Sprite can sleep
again once the agent finishes or stops to wait for you. You pay for the Sprite while it is
awake. An agent that reports nothing to Orca for 30 minutes, such as one running a single
very long command, stops counting, so the Sprite can sleep under it.

Suspending the workspace stops `orca serve` so the Sprite sleeps. Deleting it destroys the
Sprite.

## Install

1. Install the [`sprite` CLI](https://docs.fly.io/sprites) and run `sprite login`, or export
   `SPRITE_TOKEN`. You also need `node` and `git`.
2. In Orca, open **Settings → Plugins → Add plugin → From a Git URL…**, enter
   `https://github.com/superfly/orca-sprites`, then **Continue** and **Install**. Orca asks
   you to confirm that you trust the publisher. Then turn the plugin on, and approve its access:
   it runs its own code on this computer (a small worker) and reads its own settings.
3. Turn on **Settings → Experimental → Cloud VM**.
4. Create a workspace and pick **Run on → Per-Workspace Environment → Sprites**.
5. Sign Claude in on that workspace's Sprite, once per workspace:
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
`user.name` and `user.email`. `origin` points at the same repository over HTTPS: to push from
the Sprite, run `gh auth login` in a workspace terminal.

## Settings

Everything has a default. To change one, open **Settings → Plugins → Fly.io Sprites**. A
change applies to the next workspace you create, and keep-awake also to existing ones when
they resume.

The plugin's worker copies these settings to `~/.config/orca-sprites/settings.json`, which the
recipe reads, with the `PATH` of your login shell. So an Orca started from the Dock or a desktop
launcher still finds `sprite`, `node` and `git`.

You can also set each one as an environment variable where Orca starts. A variable wins over
the setting:

| Variable | Default |
|---|---|
| `SPRITES_ORG` | The `sprite` CLI's default organization |
| `SPRITES_PROJECT_ROOT` | `/home/sprite/<repository name>` |
| `SPRITES_ORCA_VERSION` | The version of your Orca app: `Orca.app` on macOS, the `orca-ide` package on Linux, else the Orca CLI. Else 1.4.256. Step 2 of the provisioning log says where the version came from. |
| `SPRITES_NAME_PREFIX` | `orca` |
| `SPRITES_BROWSER` | Off: the Sprite gets only Orca's server, from Orca's server-only build when the release has one. Set to `1` for Orca's per-workspace browser: the Sprite then installs Orca's whole desktop app, which takes about a minute longer. |
| `SPRITES_KEEP_AWAKE` | On: the Sprite stays awake while an agent works. Set to `0` to let it sleep once no client is connected, which stops the agent. A change applies to new workspaces, and to existing ones when they resume. |

Each workspace's Sprite has a **public** URL. The Orca client cannot send Sprites auth
headers, so the pairing code is the credential: keep it private. See
[provider-sprites.md](provider-sprites.md) for why, and for the design and measured timings.

## Troubleshooting

- **The Sprite runs a different Orca version from your desktop.** Step 2 of the provisioning log
  says where the version came from. If it says the recipe's default, the recipe could not find
  your Orca app or CLI. Set `SPRITES_ORCA_VERSION` to the version in Orca > About Orca.
- **A workspace failed and the Sprite is still there.** The recipe destroys the Sprite when
  `create` fails, but if you cancel a workspace while it is being created, or Orca quits, Orca
  may stop the recipe before that finishes. Orca then keeps the VM listed in its Cloud VM
  settings. **Cleanup** on that row destroys the Sprite; **Remove from list** only removes the
  row and leaves the Sprite running. To find leftovers yourself, use
  `sprite list --prefix orca-`, and remove one with `sprite destroy --force <name>`.
- **"the sprite CLI is not on PATH"** or **"node is not on PATH"**: the recipe uses the `PATH`
  of your login shell, which the plugin's worker reads when it starts, every 10 minutes and when
  you change a setting. Check that the plugin is on and its access approved, and that `sprite`
  and `node` are on `PATH` in a new terminal. After installing one, turn the plugin off and on
  to pick it up at once. Or start Orca from a terminal.
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

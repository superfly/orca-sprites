# orca-sprites

An [Orca](https://github.com/stablyai/orca) environment recipe that runs each workspace in its
own [Sprite](https://sprites.dev). Orca calls the scripts to create, suspend, resume and destroy
the Sprite, and the Orca client pairs with `orca serve` over the Sprite's URL.

## Use it

1. Install the [`sprite` CLI](https://docs.sprites.dev) and log in (`sprite login`), or export
   `SPRITE_TOKEN`. You also need `node` on the desktop.
2. Copy `scripts/orca-vm/` into your repository and fill in
   `scripts/orca-vm/sprites-state.json`:

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

3. Add the recipe to `orca.yaml` on your primary branch (see `orca.yaml.example`).
4. Export the agent credential in the environment Orca starts from:
   `CLAUDE_CODE_OAUTH_TOKEN` (from `claude setup-token`) or `ANTHROPIC_API_KEY`. For a private
   repository, also `GH_TOKEN`, `GITHUB_TOKEN`, or a logged-in `gh`.
5. Check it:

   ```bash
   orca vm recipe doctor sprites --repo-path . --json
   orca vm recipe doctor sprites --repo-path . --provision --json
   ```

Each workspace gets a new Sprite with a **public** URL. The Orca client cannot send Sprites
auth headers, so the pairing code is the credential. Keep it private.

## How it works

See [provider-sprites.md](provider-sprites.md): the design, why `create` starts `orca serve`
twice, gotchas, and measured timings. `dev/lifecycle-test.sh` runs the whole lifecycle
against a real Orca client.

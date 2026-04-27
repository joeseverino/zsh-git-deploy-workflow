# zsh-git-deploy-workflow

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Shell: bash + zsh](https://img.shields.io/badge/shell-bash%20%2B%20zsh-89e051.svg)](#requirements)
[![No dependencies](https://img.shields.io/badge/dependencies-stdlib%20only-success.svg)](#requirements)

A small, opinionated **edit → commit → push → deploy** workflow for any project that lives in a Git repo on your laptop and a Git checkout on a server you SSH into. One bootstrap command sets up the SSH keys, the SSH config, and a clean set of zsh aliases, and you're done.

```sh
acmepush "fix: tighten the cache headers"
#  ↑   commits everything, pushes to GitHub, then SSHes into the
#      server and runs `git pull --ff-only` — all in one command.
```

**This is not a CI service.** No webhook, no YAML pipeline, no third-party dashboard. It's ~250 lines of zsh that wraps `git`, `ssh`, and a bit of safety logic — the entire deploy story stays in your shell and your SSH config.

## Why bother

Every "how do I deploy a WordPress plugin / a Django app / a static site" tutorial assumes one of three things:

- **SFTP** — no version history; rollback means restoring a backup and remembering exactly which files you edited.
- **The platform's upload form** — overwrites everything blindly, doesn't preserve runtime data.
- **Push-to-deploy CI** — great when the project's big enough to justify it, overkill when "deploy" is fundamentally `git pull` on a server.

This workflow is for the middle ground: a project you actually own end-to-end, where the server is one SSH hop away, and you want the simplicity of `acmepush "fix typo"` without the ceremony of a pipeline.

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Modes](#modes)
- [Safety and idempotence](#safety-and-idempotence)
- [Architecture](#architecture)
- [What you get](#what-you-get)
- [What the bootstrap does](#what-the-bootstrap-does)
- [Manual setup](#manual-setup)
- [Daily use](#daily-use)
- [Multiple projects](#multiple-projects)
- [Uninstalling](#uninstalling)
- [Project structure](#project-structure)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Requirements

- macOS or Linux with **zsh** as your interactive shell (default on macOS Catalina+).
- **bash 3.2+** for the bootstrap script (default on macOS, present on every Linux).
- `git`, `ssh`, `ssh-keygen`, `awk`, `sed` — all standard.
- A GitHub repo for your project.
- A server you can SSH into where the project lives in a Git checkout.

No language runtime, package manager, or dependency installation required.

## Quick start

### Brand-new project (zero to first commit + deploy in one go)

If you're starting from scratch — no repo, no GitHub, nothing — use the scaffolder:

```sh
mkdir my-new-thing
cd my-new-thing
bash ~/path/to/zsh-git-deploy-workflow/init-project.sh
```

It prompts for project name / type / license / GitHub handle, generates a sensible `.gitignore` (WordPress plugin, WordPress theme, Node.js, Python, or generic), README.md, and LICENSE, runs `git init` + `git commit`, sets the remote, and either runs `gh repo create` (if you have the GitHub CLI) or prints the manual `git push` commands. At the end it offers to chain into the deploy bootstrap so you go from empty folder to live deploy without breaking flow.

### Existing project (just wire up the deploy)

```sh
git clone git@github.com:joeseverino/zsh-git-deploy-workflow.git
cd zsh-git-deploy-workflow
bash bootstrap-deploy.sh
```

The bootstrap will ask:

- **Whether you have a remote server to deploy to.** If you say no, the script switches to no-server mode (see below) and skips every server-related question.
- A human-readable project name (e.g. *My Acme Plugin*).
- A short command prefix (e.g. `acme` → gives you `acmepull`, `acmepush`, etc.).
- Local clone path of your project.
- *(Server mode only)* server-side path, SSH host details (hostname, user, port).
- Where to put the SSH keys.

Then it generates the keys, patches `~/.ssh/config`, writes a customized workflow file to `~/.{prefix}-workflow.zsh`, and adds a single source line to your `~/.zshrc`. Reload your shell and you have new commands:

```sh
exec zsh
acmehelp
```

Use `--dry-run` to see every planned change first:

```sh
bash bootstrap-deploy.sh --dry-run
```

## Modes

The bootstrap has two modes, chosen by its first question:

**Server mode** (the default — answer Y to "Do you have a remote server?"):
The full edit → commit → push → deploy loop. Two SSH keys are generated, the SSH config gets both `Host github.com` and `Host <your-alias>` blocks, and `<prefix>push` SSHes into the server after pushing to GitHub.

**No-server mode** (answer N):
Just the git aliases — `<prefix>pull`, `<prefix>push`, `<prefix>branch`, `<prefix>revert`, `<prefix>status`, `<prefix>zip`. Useful for private repos, libraries, research code, or anything you don't deploy. `<prefix>push` becomes "stage everything, commit, push to GitHub" — the deploy step is skipped automatically because the configured server host is empty. Only one SSH key (for GitHub) is generated.

**Switching later.** If you start in no-server mode and add a server later — or vice versa — re-run the bootstrap with the same prefix and pick *replace* when it detects the existing setup. Your config is regenerated cleanly.

## Safety and idempotence

The bootstrap is designed to be safe to re-run.

- **Conflict detection.** Before doing anything, it checks `~/.zshrc`, `~/.ssh/config`, and `~/.{prefix}-workflow.zsh` for existing entries with the prefix you chose. If anything is found, it prints a list and asks whether to *replace* or *abort*.
- **Existing github.com config.** If your `~/.ssh/config` already has a user-managed `Host github.com` block (outside any of our marker blocks), the bootstrap detects it and asks before adding our own. Defaults to "skip" so you don't end up with duplicate blocks.
- **Backups before mutation.** Both `~/.zshrc` and `~/.ssh/config` are copied to timestamped `.bak.YYYYMMDD-HHMMSS` files before any change.
- **SSH keys are never overwritten.** If a key already exists at the requested path, the bootstrap leaves it alone and tells you. Delete it first if you want a fresh one.
- **Marker blocks per prefix.** Multiple projects can coexist — bootstrapping `acme` then `widgetco` doesn't touch each other's blocks.

## What you get

After bootstrap, you'll have these zsh commands (with your prefix in place of `<prefix>`):

| Command | What it does |
| --- | --- |
| `<prefix>pull` | Pull latest `main` from GitHub. Refuses if you have local edits. |
| `<prefix>push "msg"` | Stage everything, commit, push to GitHub, then SSH into the server and `git pull`. **Only runs from `main`** — for branch work use plain `git`. |
| `<prefix>branch <name>` | Create a new branch from your current state. |
| `<prefix>revert` | Revert the latest `main` commit (with `YES` confirmation), push the revert, redeploy. |
| `<prefix>status` | Quick `git status --short` + current branch. |
| `<prefix>zip` | `git archive` the current commit to a clean zip — for review uploads or distribution. |
| `deploy-<prefix>` | Just the deploy step alone (server-side `git pull`). |
| `<prefix>help` | Print this list with your configured paths. |

Every safety rail is built in: the dirty-tree check refuses to overwrite uncommitted work, `<prefix>push` only runs from `main`, `<prefix>revert` requires explicit `YES` confirmation, and every command exits non-zero on the first failed git/ssh call.

## What the bootstrap does

In order, on your laptop:

1. **Generates two ed25519 SSH keys** — one for your GitHub account, one for the production server. Existing keys at the same path are skipped (not overwritten).
2. **Patches `~/.ssh/config`** — adds a `Host github.com` block pointing at your GitHub key and a `Host <your-alias>` block for the server, both wrapped in marker lines so they're easy to remove later.
3. **Renders the workflow template** — runs `git-deploy-workflow.zsh` through `sed` + `awk` to substitute your prefix everywhere (`shippull` → `acmepull`, `SHIP_*` → `ACME_*`, etc.) and bake in your paths.
4. **Patches `~/.zshrc`** — adds a single `source` line, also wrapped in marker lines.
5. **Backs up everything** — both `~/.zshrc` and `~/.ssh/config` get timestamped `.bak.YYYYMMDD-HHMMSS` copies before any modification.
6. **Offers to set up the server-side deploy key for you** — at the end of the install, the bootstrap can SSH into your server, generate a deploy key (no passphrase — required so deploys run non-interactively), attempt to register it with GitHub automatically via the GitHub CLI, fall back to a manual paste walkthrough if the CLI isn't available or lacks permission, and test the SSH connection back to GitHub from the server. You can skip this and copy/paste the printed manual commands instead.
7. **Prints next steps** — exactly what you still have to do off-machine: paste your GitHub pubkey to GitHub Settings, paste the server's deploy pubkey to the repo's Deploy Keys page, clone the repo on the server.

## Manual setup

Don't trust the bootstrap? Don't want to. Open `git-deploy-workflow.zsh`, edit the four `SHIP_*` variables at the top to match your project, and add this line to your `~/.zshrc`:

```zsh
source "$HOME/path/to/git-deploy-workflow.zsh"
```

You'll have `shippull`, `shippush`, etc. The bootstrap exists purely to handle the SSH key + config + prefix-customization steps; the workflow file itself is fully usable as-is.

## Daily use

```sh
acmepull                                    # start clean from main
# ... edit code ...
acmepush "fix: stop double-encoding URLs"   # commit + push + deploy in one step
```

For non-deployable work — experiments, large refactors, anything that should be reviewed before going live:

```sh
acmepull
acmebranch refactor/extract-cache-helpers
# ... edit, commit, push to a branch via plain git ...
git push -u origin refactor/extract-cache-helpers
# ... open a PR, review, merge to main on GitHub ...
acmepull && acmepush "merge: extract cache helpers"
```

If a deploy went wrong:

```sh
acmerevert     # asks for "YES" confirmation, then reverts the latest commit and redeploys
```

## Multiple projects

Each bootstrap uses a unique marker block in `~/.zshrc` and `~/.ssh/config`, scoped to the prefix you chose. Run the bootstrap as many times as you have projects:

```sh
bash bootstrap-deploy.sh    # prefix: acme       → acmepush
bash bootstrap-deploy.sh    # prefix: widgetco   → wcpush
bash bootstrap-deploy.sh    # prefix: blog       → blogpush
```

Each gets its own workflow file, its own SSH keys, its own SSH config block, and its own source line. They don't collide.

## Uninstalling

```sh
bash bootstrap-deploy.sh --uninstall
```

Asks which prefix to remove, then strips the corresponding marker blocks from `~/.zshrc` and `~/.ssh/config`. Leaves your SSH keys and the rendered workflow file in place — it tells you the exact `rm` commands if you want them gone too. Backups are made before any modification.

## Architecture

The workflow uses a **shared library + thin per-project wrappers** pattern. After running the bootstrap for `acme` and `widgetco` and `theme`, your home directory looks like:

```
~/.git-deploy-lib.zsh      # ← shared logic, ~250 lines, installed once
~/.acme-workflow.zsh       # ← ~50 lines: context + 8 wrappers
~/.widgetco-workflow.zsh   # ← ~50 lines: context + 8 wrappers
~/.theme-workflow.zsh      # ← ~50 lines: context + 8 wrappers
```

The library defines generic functions (`_gdw_pull`, `_gdw_push`, etc.) that read their config from environment variables (`GDW_REPO`, `GDW_SSH_HOST`, …). Each per-project file is just a context-setter plus eight one-liner wrappers:

```zsh
_acme_ctx() {
  GDW_PREFIX="acme"
  GDW_LABEL="Acme Plugin"
  GDW_REPO="$HOME/Code/acme"
  GDW_SSH_HOST="acme-prod"
  GDW_SERVER_PATH='$HOME/wp-content/plugins/acme'
  GDW_ZIP_OUTPUT="$HOME/Downloads/acme-review.zip"
}

acmepull()    { _acme_ctx; _gdw_pull "$@"; }
acmepush()    { _acme_ctx; _gdw_push "$@"; }
# ...etc.
```

The bootstrap installs/updates the shared library every run, so library improvements ship to every project on the next bootstrap. If you want to fix a bug in `_gdw_push`, you fix it once in `git-deploy-lib.zsh` and re-run the bootstrap.

## Project structure

```
zsh-git-deploy-workflow/
├── git-deploy-lib.zsh        # Shared workflow logic (sourced by all projects)
├── git-deploy-workflow.zsh   # Per-project template (rendered by the bootstrap)
├── bootstrap-deploy.sh       # Interactive installer / uninstaller
├── init-project.sh           # New-project scaffolder (optionally chains into bootstrap)
├── README.md                 # You are here
├── LICENSE                   # MIT
└── .gitignore
```

Four files of code; everything else is documentation.

## Security model

This tool generates and manages SSH keys, so it's worth being explicit about what it does and doesn't trust:

- **Separate keys per concern.** GitHub and the server get different keys. If one leaks, the other side is unaffected.
- **`IdentitiesOnly yes`** in every Host block. SSH offers only the explicitly assigned key, never every key in your agent — important if you have many keys.
- **`AddKeysToAgent yes` + `UseKeychain yes`** on macOS (Linux uses `AddKeysToAgent yes` only — `UseKeychain` is a macOS-only directive). Passphrases are cached in the macOS Keychain, not typed for every command.
- **Read-only deploy key on the server.** The bootstrap walks you through this in step 3 of its "next steps" output. The server's GitHub key is registered as a read-only Deploy Key on the repo, so the server can `git pull` updates but cannot push back.
- **No network calls during bootstrap.** Everything happens on your laptop; no telemetry, no remote config fetching.
- **Backups before mutations.** Both `~/.zshrc` and `~/.ssh/config` are copied to timestamped `.bak.*` files before being modified.

## Troubleshooting

**`<prefix>pull` says "Local changes or untracked files detected"**
You have uncommitted edits. Either commit them with `<prefix>push "..."`, move them onto a branch with `<prefix>branch ...`, or discard them with `git restore .` and `git clean -fd`.

**`deploy-<prefix>` fails with permission denied**
The server's SSH user can't reach your GitHub deploy key, or the deploy key doesn't have access to the repo. Re-test with `ssh <your-alias> "ssh -T git@github-<prefix>"` (using the alias you configured) — it should report a successful GitHub authentication on the server side.

**Server pull fails with merge conflicts**
The server has uncommitted local changes (often from someone editing files via SFTP). SSH in and resolve manually:

```sh
ssh <your-alias>
cd <your-server-path>
git status
# git stash, git checkout -- <file>, etc.
```

**`<prefix>push` hangs forever**
Usually a network issue or an interactive SSH prompt. Cancel with `Ctrl+C`, then test `ssh <your-alias> echo ok` and `ssh -T github.com` separately to find the broken link.

**Bootstrap says "Could not find workflow template"**
Run the bootstrap from inside the cloned repo (where `git-deploy-workflow.zsh` lives), not from elsewhere. The script looks for the template alongside itself.

## License

MIT. See [LICENSE](LICENSE) for the full text. Use this however you want; attribution appreciated but not required.

---

*Built originally for the [Severino Labs Security Layer](https://github.com/joeseverino/severino-labs-security-layer) WordPress plugin, generalized so anyone can use it for anything.*

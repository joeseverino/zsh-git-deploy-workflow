# zsh-git-deploy-workflow

A small, opinionated **edit → commit → push → deploy** workflow for projects that live in a Git repo on your laptop and, optionally, a Git checkout on a server you SSH into.

One bootstrap command sets up project-specific zsh commands, SSH keys, SSH config entries, a shared deploy library, and a repeatable push/deploy flow.

```sh
acmepush "fix: tighten cache headers"
# commits everything, pushes to GitHub, then optionally SSHes into the
# server and runs git pull --ff-only
```

This is not a CI service. No webhook, no YAML pipeline, no third-party dashboard. It wraps `git`, `ssh`, `ssh-keygen`, and shell scripts so the deploy story stays readable, local, and easy to audit.

## Why bother

Many small projects do not need a full deployment pipeline, but they still deserve something better than manual file edits.

Common options usually fall into one of these buckets:

- **SFTP** — no clean version history; rollback depends on backups and memory.
- **Platform upload forms** — easy to overwrite files blindly and mix code with runtime data.
- **Push-to-deploy CI** — powerful, but often too much ceremony for a small project whose deploy step is really just `git pull` on a server.

This workflow is for the middle ground: projects you own end-to-end, where a simple Git-based release path is enough, but you still want safety checks, repeatability, key separation, and clean commands.

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Modes](#modes)
- [What you get](#what-you-get)
- [Daily use](#daily-use)
- [Safety and idempotence](#safety-and-idempotence)
- [What the bootstrap does](#what-the-bootstrap-does)
- [New-project scaffolding](#new-project-scaffolding)
- [Architecture](#architecture)
- [Multiple projects](#multiple-projects)
- [Manual setup](#manual-setup)
- [Uninstalling](#uninstalling)
- [Project structure](#project-structure)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)
- [License](#license)

## Requirements

Required:

- macOS or Linux.
- **zsh** as your interactive shell.
- **bash 3.2+** for the bootstrap scripts.
- `git`, `ssh`, `ssh-keygen`, `awk`, `sed`, `mktemp`, and standard shell tools.
- A GitHub repository for the project.
- For server mode: a server you can SSH into where the project should live as a Git checkout.

Optional:

- GitHub CLI (`gh`) for automatic repo creation and deploy-key registration.
- Without `gh`, the scripts print the manual GitHub steps instead.

No language runtime, package manager, or application framework is required.

## Quick start

### 1. Clone this workflow repo

```sh
git clone git@github.com:joeseverino/zsh-git-deploy-workflow.git
cd zsh-git-deploy-workflow
```

### 2. Bootstrap an existing project

From the project you want to wire up:

```sh
cd ~/path/to/your-project
bash ~/path/to/zsh-git-deploy-workflow/bootstrap-deploy.sh
```

The bootstrap asks for:

- Whether this project deploys to a remote server.
- A command prefix, such as `acme`.
- The local project path.
- The local ZIP output path.
- GitHub SSH key details.
- In server mode: server SSH details, server project path, server-side GitHub alias, and server-side remote URL.

After the bootstrap finishes:

```sh
exec zsh
acmehelp
```

### 3. Preview first with dry run

```sh
bash ~/path/to/zsh-git-deploy-workflow/bootstrap-deploy.sh --dry-run
```

Dry run prints the plan and writes nothing.

## Modes

The bootstrap supports two modes.

### Server mode

Use this for projects that deploy to a remote server, such as:

- WordPress plugins
- WordPress themes
- Static sites
- Small apps hosted on a VPS or shared host
- Any project where deploy means "SSH into the server and pull latest main"

In server mode, `<prefix>push "message"` does this:

1. Confirms the local repo is on `main`.
2. Stages all changes.
3. Stops cleanly if there is nothing to commit.
4. Shows the pending Git status.
5. Creates the commit.
6. Pushes to GitHub.
7. SSHes into the server.
8. Runs a fast-forward-only pull inside the configured server path.

If the server path does not exist yet, the deploy command can create the parent directory and clone the repo into place. If the path exists but is not a Git repo, it refuses to overwrite it.

### No-server mode

Use this for projects that do not deploy anywhere yet, such as:

- Libraries
- Scripts
- Research code
- Private GitHub repos
- Early-stage projects

In no-server mode, `<prefix>push "message"` stages, commits, and pushes to GitHub. The deploy step is skipped automatically because no server host is configured.

If you add a server later, rerun the bootstrap with the same prefix and choose `replace`.

## What you get

After bootstrap, your shell gets project-specific commands using the prefix you chose.

For prefix `acme`:

| Command | What it does |
| --- | --- |
| `acmepull` | Pulls latest `main` from GitHub. Refuses if local edits exist. |
| `acmepush "message"` | Stages all changes, commits, pushes to GitHub, and deploys if a server is configured. Only runs from `main`. |
| `acmebranch <name>` | Creates a new branch from the current state. |
| `acmerevert` | Reverts the latest `main` commit after explicit `YES` confirmation, pushes the revert, and redeploys if configured. |
| `acmestatus` | Shows short Git status and the current branch. |
| `acmezip` | Builds a clean ZIP from the current Git commit using `git archive`. |
| `deploy-acme` | Runs only the deploy step. In no-server mode, it reports that no deploy is configured. |
| `acmehelp` | Shows the command list and configured paths for the project. |
| `gdw-list` | Lists every bootstrapped project found in `~/.zshrc`. |

## Daily use

Start clean:

```sh
acmepull
```

Make changes, then commit, push, and deploy:

```sh
acmepush "fix: stop double-encoding URLs"
```

Check status:

```sh
acmestatus
```

Create a branch for work that should not deploy immediately:

```sh
acmebranch refactor/cache-helpers
git push -u origin refactor/cache-helpers
```

Build a clean review ZIP:

```sh
acmezip
```

Revert the latest `main` commit and redeploy:

```sh
acmerevert
```

## Safety and idempotence

The bootstrap is designed to be safe to rerun.

- **Dry run support.** Use `--dry-run` to preview changes before writing anything.
- **Prefix conflict detection.** If the chosen prefix already exists, the bootstrap asks whether to replace the previous setup or abort.
- **Backups before mutation.** `~/.zshrc` and `~/.ssh/config` are copied to timestamped `.bak.YYYYMMDD-HHMMSS` files before modification.
- **Marker blocks.** All generated shell and SSH config blocks are wrapped in prefix-specific marker comments.
- **Existing SSH config reuse.** If a matching `Host` block already exists, the bootstrap reuses it instead of duplicating it.
- **SSH keys are not overwritten.** Existing keys at the selected paths are reused.
- **Main-branch guard.** `<prefix>push` and `<prefix>revert` only run from `main`.
- **Dirty-tree guard.** Pull and revert commands refuse to continue if local changes or untracked files are present.
- **Fast-forward-only deploy.** Server deploys use `git pull --ff-only`, preventing silent merge commits on the server.
- **Server overwrite guard.** If the server path exists but is not a Git repo, deploy refuses to touch it.

## What the bootstrap does

On your laptop, `bootstrap-deploy.sh`:

1. Prompts for project mode, prefix, local repo path, ZIP output path, and SSH details.
2. Installs the shared library at:

   ```sh
   ~/.git-deploy-lib.zsh
   ```

3. Renders a small per-project workflow file at:

   ```sh
   ~/.<prefix>-workflow.zsh
   ```

4. Adds one source block to `~/.zshrc`.
5. Reuses or creates the selected local GitHub SSH key.
6. In server mode, reuses or creates the selected server SSH key.
7. Adds SSH config blocks only when needed.
8. In server mode, asks whether to set up the server-side deploy key and GitHub alias.
9. Adds a `gdw-bootstrap` convenience alias on first run.
10. Prints next steps.

In server mode, the optional server-side setup can:

1. SSH into the server.
2. Generate a repo-specific deploy key without a passphrase.
3. Add a server-side SSH alias such as:

   ```sshconfig
   Host github-acme
     HostName github.com
     User git
     IdentityFile ~/.ssh/acme_github_deploy
     IdentitiesOnly yes
   ```

4. Attempt to register the deploy key with GitHub using `gh repo deploy-key add`.
5. Fall back to a manual paste flow if GitHub CLI is unavailable or lacks permission.
6. Test the server's GitHub authentication through the alias.

## New-project scaffolding

`init-project.sh` creates a new project from an empty or new directory.

```sh
mkdir my-new-thing
cd my-new-thing
bash ~/path/to/zsh-git-deploy-workflow/init-project.sh
```

It does the following:

1. Uses the current directory name as the project name and GitHub repo name.
2. Prompts for a one-line description.
3. Detects your GitHub username from `gh` or global Git config when possible.
4. Writes a starter `.gitignore`.
5. Writes a starter `README.md`.
6. Creates a `LICENSE` file when selected.
7. Runs `git init -b main`.
8. Stages the files and makes the initial commit.
9. Creates and pushes the GitHub repo with `gh` when available.
10. Falls back to manual GitHub instructions when `gh` is unavailable.
11. Adds a `gdw-init` convenience alias on first run.
12. Offers to chain directly into `bootstrap-deploy.sh`.

Use dry run to preview:

```sh
bash ~/path/to/zsh-git-deploy-workflow/init-project.sh --dry-run
```

## Architecture

The workflow uses a **shared library + thin per-project wrapper** pattern.

After bootstrapping projects named `acme`, `widgetco`, and `theme`, your home directory looks like this:

```text
~/.git-deploy-lib.zsh      # shared logic, installed once
~/.acme-workflow.zsh       # project context + wrappers
~/.widgetco-workflow.zsh   # project context + wrappers
~/.theme-workflow.zsh      # project context + wrappers
```

The shared library defines generic functions such as `_gdw_pull`, `_gdw_push`, `_gdw_revert`, `_gdw_zip`, and `_gdw_deploy`. Each per-project workflow file sets context variables and exposes friendly commands.

Example wrapper structure:

```zsh
_acme_ctx() {
  GDW_PREFIX="acme"
  GDW_LABEL="Acme Plugin"
  GDW_REPO="$HOME/Code/acme"
  GDW_SSH_HOST="acme-prod"
  GDW_SERVER_PATH='$HOME/wp-content/plugins/acme'
  GDW_ZIP_OUTPUT="$HOME/Downloads/acme-review.zip"
}

acmepull() { _acme_ctx; _gdw_pull "$@"; }
acmepush() { _acme_ctx; _gdw_push "$@"; }
```

The bootstrap installs or updates the shared library on each run. That means improvements to `git-deploy-lib.zsh` can be applied across bootstrapped projects by rerunning the bootstrap.

## Multiple projects

Each project uses its own prefix, workflow file, SSH config markers, and optional server alias.

```sh
bash bootstrap-deploy.sh    # prefix: acme      → acmepush
bash bootstrap-deploy.sh    # prefix: widgetco  → widgetcopush
bash bootstrap-deploy.sh    # prefix: blog      → blogpush
```

The generated files and config blocks are scoped by prefix, so projects do not overwrite each other.

`gdw-list` shows the bootstrapped projects currently sourced from `~/.zshrc`.

## Manual setup

The bootstrap is the normal path, but the workflow can be wired manually.

1. Copy the library somewhere stable:

   ```sh
   cp git-deploy-lib.zsh ~/.git-deploy-lib.zsh
   ```

2. Copy the workflow template:

   ```sh
   cp git-deploy-workflow.zsh ~/.acme-workflow.zsh
   ```

3. Edit the project variables in the copied workflow file.
4. Source it from `~/.zshrc`:

   ```zsh
   source "$HOME/.acme-workflow.zsh"
   ```

5. Reload zsh:

   ```sh
   exec zsh
   ```

Manual setup is useful for review or customization, but the bootstrap handles the repetitive SSH and prefix wiring more safely.

## Uninstalling

```sh
bash bootstrap-deploy.sh --uninstall
```

The uninstall flow asks which prefix to remove, then strips that prefix's marker blocks from:

- `~/.zshrc`
- `~/.ssh/config`

It leaves SSH keys and rendered workflow files in place, then prints the exact `rm` commands if you want to remove those too.

Backups are made before any modification.

## Project structure

```text
zsh-git-deploy-workflow/
├── bootstrap-deploy.sh       # Interactive installer / uninstaller
├── git-deploy-lib.zsh        # Shared workflow logic
├── git-deploy-workflow.zsh   # Per-project workflow template
├── init-project.sh           # New-project scaffolder
├── README.md                 # Documentation
├── LICENSE                   # MIT license
└── .gitignore
```

## Security model

This tool manages SSH-based Git workflows, so the boundaries matter.

- **Separate keys per concern.** Local GitHub access, server SSH access, and server-side GitHub deploy access can use separate keys.
- **Read-only server deploy key.** The server-side GitHub key is intended to be registered as a read-only deploy key, so the server can pull from the repo but cannot push back.
- **Repo-specific server aliases.** Server-side GitHub access should use aliases such as `github-acme`, not a global `Host github.com` override, when multiple repos or deploy keys are involved.
- **`IdentitiesOnly yes`.** Generated SSH blocks force SSH to offer only the configured key for that host.
- **macOS Keychain support where valid.** macOS blocks include `UseKeychain yes`; Linux blocks do not because `UseKeychain` is a macOS-specific SSH directive.
- **No private keys are copied into the repo.** Keys stay in `~/.ssh` on the machine that uses them.
- **No signing keys on the production server.** The server only needs pull access through its deploy key. Commit signing remains local.
- **Fast-forward-only server pulls.** Deploy uses `git pull --ff-only` so the server does not create surprise merge commits.
- **Backups before config changes.** Shell and SSH config files are backed up before marker blocks are edited.

## Troubleshooting

### `<prefix>pull` says local changes were detected

You have uncommitted or untracked files.

Check the state:

```sh
<prefix>status
```

Then either commit the work, move it to a branch, or discard it intentionally.

### `<prefix>push` refuses because I am not on `main`

That is expected. `<prefix>push` is the release path and only runs from `main`.

For branch work, use normal Git:

```sh
git checkout -b feature/my-change
git add .
git commit -m "work in progress"
git push -u origin feature/my-change
```

### `deploy-<prefix>` fails with permission denied

The server may not have working GitHub deploy-key access.

Test from your laptop through the server:

```sh
ssh <your-server-alias> "ssh -T git@github-<prefix>"
```

That should test the server's configured GitHub alias, not your laptop's GitHub key.

### Server pull fails with merge conflicts

The server probably has local changes.

SSH into the server and inspect the repo:

```sh
ssh <your-server-alias>
cd <your-server-path>
git status
```

Resolve the server state manually, then rerun the deploy command.

### `<prefix>push` hangs

It is usually an SSH prompt, network issue, or GitHub authentication issue.

Test each link separately:

```sh
ssh -T git@github.com
ssh <your-server-alias> "echo ok"
ssh <your-server-alias> "ssh -T git@github-<prefix>"
```

### Bootstrap says it cannot find the workflow template

Run `bootstrap-deploy.sh` from the cloned workflow repo, or call it by full path so it can find the files next to itself:

```sh
bash ~/path/to/zsh-git-deploy-workflow/bootstrap-deploy.sh
```

### GitHub CLI deploy-key registration fails

The bootstrap should fall back to manual instructions. Copy the printed public key and add it in GitHub under:

```text
Repository → Settings → Deploy keys → Add deploy key
```

Leave write access disabled for a read-only deploy key.

## License

MIT. See [LICENSE](LICENSE).

Built originally for the [Severino Labs Security Layer](https://github.com/joeseverino/severino-labs-security-layer) WordPress plugin, then generalized for reusable Git-based project deployment.

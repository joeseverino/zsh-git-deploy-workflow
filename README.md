# zsh-git-deploy-workflow

A small, opinionated **edit → commit → push → deploy** workflow for projects that live in a Git repo on your laptop and, optionally, a Git checkout on a server you SSH into.

One bootstrap command sets up project-specific zsh commands, SSH keys, SSH config entries, a shared deploy library, and a repeatable push/deploy flow.

```sh
acmepush "fix: tighten cache headers"
# stages everything, commits, pushes to GitHub, SSHes into the
# server, and runs git pull --ff-only
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
- [Configuration defaults (~/.gdw-config)](#configuration-defaults-gdw-config)
- [Express mode](#express-mode)
- [CLI flags reference](#cli-flags-reference)
- [Modes](#modes)
- [What you get](#what-you-get)
- [Daily use](#daily-use)
- [Safety and idempotence](#safety-and-idempotence)
- [What the bootstrap does](#what-the-bootstrap-does)
- [New-project scaffolding (gdw-init)](#new-project-scaffolding-gdw-init)
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

Optional but recommended:

- **GitHub CLI (`gh`)** — enables automatic repo creation and deploy-key registration. Without it, the scripts print the manual GitHub steps instead.

No language runtime, package manager, or application framework is required.

## Quick start

### 1. Clone this workflow repo

```sh
git clone git@github.com:joeseverino/zsh-git-deploy-workflow.git
```

### 2. Set up your defaults (optional but recommended)

Copy the config example to your home directory and fill in your values:

```sh
cp zsh-git-deploy-workflow/.gdw-config.example ~/.gdw-config
$EDITOR ~/.gdw-config
```

See [Configuration defaults](#configuration-defaults-gdw-config) for the full list of options. The more you fill in, the less the bootstrap asks.

### 3a. Scaffold a new project (recommended)

```sh
mkdir my-new-plugin
cd my-new-plugin
bash ~/path/to/zsh-git-deploy-workflow/init-project.sh
```

This creates the repo, pushes it to GitHub, and chains directly into the bootstrap. A `gdw-init` alias is added to `~/.zshrc` on first run so future scaffolds are just:

```sh
mkdir my-project && cd my-project && gdw-init
```

### 3b. Bootstrap an existing project

From the project directory:

```sh
cd ~/path/to/your-project
bash ~/path/to/zsh-git-deploy-workflow/bootstrap-deploy.sh
```

A `gdw-bootstrap` alias is added on first run.

### 4. Reload your shell

```sh
exec zsh
acmehelp
```

### One-liner with express mode

With a populated `~/.gdw-config`, the entire flow from empty directory to deployed server can be run with a single command:

```sh
mkdir my-plugin && cd my-plugin
gdw-init --express \
  --prefix myplugin \
  --description "My WordPress plugin" \
  --server-path /home/user/public_html/wp-content/plugins/my-plugin
```

Express mode auto-yes every confirmation and runs every step — including the server-side deploy key setup and the initial server deploy — without pausing. See [Express mode](#express-mode) for details.

## Configuration defaults (`~/.gdw-config`)

Both `init-project.sh` and `bootstrap-deploy.sh` source `~/.gdw-config` at startup. Any variable set there is used as a silent default, skipping the corresponding prompt entirely.

The priority order for every setting is: **CLI flag → `~/.gdw-config` → interactive prompt**.

Copy the example file to get started:

```sh
cp zsh-git-deploy-workflow/.gdw-config.example ~/.gdw-config
```

### Available variables

```sh
# ── init-project.sh ─────────────────────────────────────────────────────────

# Your GitHub username. Skips the username prompt.
GDW_DEFAULT_GH_USER="joeseverino"

# Default visibility for new repos created via init-project. One of: public, private
GDW_DEFAULT_GH_VISIBILITY="private"

# ── bootstrap-deploy.sh ─────────────────────────────────────────────────────

# SSH host alias for the production server (must match a Host in ~/.ssh/config).
# When set, bootstrap skips the SSH host alias prompt entirely.
GDW_DEFAULT_SSH_HOST="myserver.net"

# GitHub SSH hostname. Almost always "github.com".
GDW_DEFAULT_GITHUB_HOST="github.com"

# Directory for zip review archives. The prefix and "-review.zip" are appended
# automatically, e.g. ~/Downloads/theme-review.zip
GDW_DEFAULT_ZIP_DIR="$HOME/Downloads"

# Server-side GitHub SSH alias pattern. __PREFIX__ is substituted at bootstrap
# time, e.g. "github-__PREFIX__" → "github-theme" for prefix "theme".
GDW_DEFAULT_SERVER_GITHUB_ALIAS="github-__PREFIX__"
```

A fully populated config means most projects only need a prefix and a server path from the user — or nothing at all in express mode.

## Express mode

Pass `--express` to either script to run completely without manual confirmation prompts.

```sh
gdw-init --express --description "My plugin" --server-path /var/www/my-plugin
# or
gdw-bootstrap --express --prefix theme --server-path /var/www/theme
```

In express mode:

- Every yes/no confirmation (`[Y/n]`) is automatically answered yes and logged.
- The command prefix is auto-derived from the project directory name by lowercasing it and stripping hyphens and other non-alphanumeric characters. `my-new-plugin` becomes `mynewplugin`. Override with `--prefix` if you want something shorter.
- All fields that have a config default or can be derived (GitHub host, SSH host alias, server GitHub alias, server remote URL, zip path, local path) are resolved silently.
- The server-side setup runs fully — deploy key generation, SSH alias config, GitHub key registration, and the connection test — without pausing.
- The test retry loop runs once instead of looping indefinitely.
- The initial server deploy (`deploy-<prefix>`) runs automatically at the end.

Express mode is designed to be combined with CLI flags and `~/.gdw-config` for fully non-interactive runs. The only prompts that can still appear in express mode are fields that cannot be derived and were not provided — most commonly the server hostname when the SSH host alias is not yet in `~/.ssh/config`.

### Full express example

Given a `~/.gdw-config` with `GDW_DEFAULT_GH_USER`, `GDW_DEFAULT_SSH_HOST`, `GDW_DEFAULT_GITHUB_HOST`, `GDW_DEFAULT_ZIP_DIR`, and `GDW_DEFAULT_SERVER_GITHUB_ALIAS` set:

```sh
mkdir test-project-6 && cd test-project-6
gdw-init --express \
  --prefix test6 \
  --description "Test project 6" \
  --server-path /home/user/public_html/wp-content/plugins/test-project-6
```

`--prefix` is recommended in express mode. Without it, the prefix is auto-derived from the directory name — `test-project-6` becomes `testproject6` — which works, but produces longer daily-use commands like `testproject6push`. A short explicit prefix like `test6` gives you `test6push` instead.

This single command:

1. Writes `.gitignore` and `README.md`, runs `git init`, makes the initial commit.
2. Creates the private GitHub repo and pushes via `gh`.
3. Installs the shared deploy library and renders the workflow file.
4. Reuses or creates SSH keys for GitHub and the server.
5. Patches `~/.ssh/config` and `~/.zshrc` as needed.
6. SSHes into the configured server and generates a project-specific deploy key.
7. Registers the deploy key with GitHub via `gh repo deploy-key add`.
8. Tests the server's GitHub authentication.
9. Runs the initial deploy — cloning the repo at the server path.

After this, `test6push "first change"` is the entire release flow.

## CLI flags reference

### `init-project.sh` / `gdw-init`

```
--express                Auto-yes all confirmations; chains bootstrap in express mode.
--dry-run                Preview every action; write nothing.
--description <text>     One-line project description.
--github-user <user>     GitHub username.
--visibility <v>         Repo visibility: public or private. Default: private.
```

All bootstrap flags listed below are also accepted and forwarded automatically when init-project chains into bootstrap.

### `bootstrap-deploy.sh` / `gdw-bootstrap`

**Modes:**

```
--express                Auto-yes all confirmations; runs every step without pausing.
                         In uninstall mode, the only prompt is typing the GitHub repo
                         name to confirm deletion.
--dry-run                Preview the plan; write nothing.
--uninstall              Remove a previous bootstrap: strips ~/.zshrc and ~/.ssh/config
                         blocks, removes the server deploy key and project folder, and
                         deletes the GitHub repo. Combine with --express and --prefix
                         for a fully non-interactive teardown.
```

**Project:**

```
--prefix <p>             Command prefix (e.g. theme → themepull / themepush).
                         In express mode, auto-derived from the project name if omitted.
--label <l>              Human-readable project name.
--local-path <path>      Local clone path of the project.
--server-path <path>     Project path on the production server.
--zip-path <path>        Full output path for zip review archives.
--no-server              No-server mode: commit + push only, no deploy step.
```

**GitHub:**

```
--github-host <host>     GitHub SSH hostname. Default: github.com.
--github-key <path>      Path to the local GitHub SSH key.
```

**Server SSH:**

```
--ssh-host <alias>       SSH host alias in your local ~/.ssh/config.
--ssh-hostname <host>    Actual server hostname or IP (used when creating a new SSH block).
--ssh-user <user>        Server SSH user.
--ssh-port <port>        Server SSH port. Default: 22.
--server-key <path>      Path to the server SSH key.
```

**Deploy key:**

```
--server-github-alias <alias>   Server-side GitHub SSH alias. Default: github-<prefix>.
--server-remote <url>           Server-side GitHub remote URL.
```

### Combining flags and config

Flags, config, and interactive prompts stack cleanly. A field is resolved by checking each source in order and stopping at the first one that provides a value:

1. CLI flag
2. `~/.gdw-config` variable
3. Auto-derivation (express mode only, where applicable)
4. Interactive prompt

## Modes

### Server mode

Use this for projects that deploy to a remote server, such as WordPress plugins, WordPress themes, static sites, or any app where deploy means "SSH into the server and pull latest main."

In server mode, `<prefix>push "message"` does this:

1. Confirms the local repo is on `main`.
2. Stages all changes.
3. Stops cleanly if there is nothing to commit.
4. Shows the pending Git status.
5. Creates the commit.
6. Pushes to GitHub.
7. SSHes into the server.
8. Runs a fast-forward-only pull inside the configured server path.

If the server path does not exist yet, the deploy command creates the parent directory and clones the repo into place. If the path exists but is not a Git repo, it refuses to overwrite it.

### No-server mode

Use this for libraries, scripts, private research code, or any project that does not deploy anywhere yet. `<prefix>push "message"` stages, commits, and pushes to GitHub. The deploy step is skipped automatically because no server host is configured.

If you add a server later, rerun the bootstrap with the same prefix and choose `replace`.

## What you get

After bootstrap, your shell gets project-specific commands scoped to the prefix you chose. For prefix `acme`:

| Command | What it does |
| --- | --- |
| `acmepull` | Pulls latest `main` from GitHub. Refuses if local edits exist. |
| `acmepush "message"` | Stages all changes, commits, pushes to GitHub, and deploys if a server is configured. Only runs from `main`. |
| `acmebranch <name>` | Creates a new branch from the current state. |
| `acmerevert` | Reverts the latest `main` commit after explicit `YES` confirmation, pushes the revert, and redeploys. |
| `acmestatus` | Shows short Git status and the current branch. |
| `acmezip` | Builds a clean ZIP from the current Git commit using `git archive`. |
| `deploy-acme` | Runs only the deploy step (server `git pull` or clone). |
| `acmehelp` | Shows the command list and configured paths. |
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
- **Prefix conflict detection.** If the chosen prefix already exists, the bootstrap asks whether to replace the previous setup or abort. In express mode, it auto-replaces.
- **Backups before mutation.** `~/.zshrc` and `~/.ssh/config` are copied to timestamped `.bak.YYYYMMDD-HHMMSS` files before modification.
- **Marker blocks.** All generated shell and SSH config blocks are wrapped in prefix-specific marker comments so they can be cleanly stripped by `--uninstall`.
- **Existing SSH config reuse.** If a matching `Host` block already exists, the bootstrap reads it instead of duplicating it.
- **SSH keys are not overwritten.** Existing keys at the selected paths are reused. Only missing keys are created.
- **Main-branch guard.** `<prefix>push` and `<prefix>revert` only run from `main`.
- **Dirty-tree guard.** Pull and revert commands refuse to continue if local changes or untracked files are present.
- **Fast-forward-only deploy.** Server deploys use `git pull --ff-only`, preventing silent merge commits on the server.
- **Server overwrite guard.** If the server path exists but is not a Git repo, deploy refuses to touch it.

## What the bootstrap does

Running `bootstrap-deploy.sh` (or `gdw-bootstrap`) on your laptop does the following:

1. Collects project settings from CLI flags, `~/.gdw-config`, and interactive prompts as needed.
2. Installs the shared library at `~/.git-deploy-lib.zsh`.
3. Renders a small per-project workflow file at `~/.<prefix>-workflow.zsh`.
4. Adds one `source` block to `~/.zshrc`.
5. Reuses or creates the local GitHub SSH key.
6. In server mode, reuses or creates the server SSH key.
7. Patches `~/.ssh/config` only for host blocks that do not already exist.
8. In server mode, runs the server-side setup (see below).
9. Adds a `gdw-bootstrap` convenience alias on first run.
10. Offers to run `deploy-<prefix>` immediately to do the initial server-side clone.

### Server-side setup

When server mode is active, the bootstrap SSHes into the server and:

1. Generates a repo-specific deploy key without a passphrase (required for non-interactive deploys).
2. Writes a marker-bracketed `Host github-<prefix>` block in the server's `~/.ssh/config`.
3. Attempts to register the deploy key with GitHub using `gh repo deploy-key add`. Falls back to a manual paste flow if GitHub CLI is unavailable or lacks `admin:repo_hook` scope.
4. Tests the server's GitHub authentication through the alias.

In express mode, all confirmations in this flow are answered automatically and the test runs once.

### Initial deploy

At the end of bootstrap, the script offers to run `deploy-<prefix>` immediately. This SSHes into the server and either clones the repo if the server path does not exist yet, or pulls the latest `main` if it does. In express mode this runs automatically.

## New-project scaffolding (`gdw-init`)

`init-project.sh` (aliased as `gdw-init` after the first run) scaffolds a brand-new project from an empty directory.

```sh
mkdir my-plugin
cd my-plugin
gdw-init
```

It does the following:

1. Uses the current directory name as both the project name and the GitHub repo name.
2. Prompts for a one-line description (or takes it from `--description`).
3. Detects your GitHub username from `gh`, global Git config, or `~/.gdw-config`.
4. Writes a starter `.gitignore` and `README.md`.
5. Runs `git init -b main`, stages everything, and makes the initial commit.
6. Creates and pushes the GitHub repo with `gh` when authenticated; otherwise prints the manual steps.
7. Adds the `gdw-init` convenience alias to `~/.zshrc` on first run.
8. Chains directly into `bootstrap-deploy.sh`, passing the confirmed project path so bootstrap does not ask for it again.

### Express scaffolding

With `~/.gdw-config` populated, the full scaffold-to-deploy flow is a single command:

```sh
mkdir my-plugin && cd my-plugin
gdw-init --express \
  --description "My WordPress plugin" \
  --server-path /home/user/public_html/wp-content/plugins/my-plugin
```

All bootstrap flags (`--prefix`, `--ssh-host`, `--server-remote`, etc.) are accepted by `gdw-init` and forwarded automatically when it chains into bootstrap.

### Preview with dry run

```sh
gdw-init --dry-run
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

The shared library defines generic functions such as `_gdw_pull`, `_gdw_push`, `_gdw_revert`, `_gdw_zip`, and `_gdw_deploy`. Each per-project workflow file sets the project-specific context variables and then exposes the friendly command names.

```zsh
_acme_ctx() {
  GDW_PREFIX="acme"
  GDW_LABEL="Acme Plugin"
  GDW_REPO="$HOME/Code/acme"
  GDW_SSH_HOST="myserver"
  GDW_SERVER_PATH='$HOME/wp-content/plugins/acme'
  GDW_ZIP_OUTPUT="$HOME/Downloads/acme-review.zip"
  GDW_SERVER_REMOTE="git@github-acme:joeseverino/acme.git"
}

acmepull()   { _acme_ctx; _gdw_pull "$@"; }
acmepush()   { _acme_ctx; _gdw_push "$@"; }
deploy-acme() { _acme_ctx; _gdw_deploy "$@"; }
```

The bootstrap installs or updates the shared library on each run. Improvements to `git-deploy-lib.zsh` propagate to all bootstrapped projects by rerunning the bootstrap.

## Multiple projects

Each project uses its own prefix, workflow file, SSH config markers, and optional server-side GitHub alias. Projects do not interfere with each other.

```sh
gdw-bootstrap --prefix acme    # → acmepush
gdw-bootstrap --prefix theme   # → themepush
gdw-bootstrap --prefix blog    # → blogpush
```

`gdw-list` shows all bootstrapped projects currently sourced from `~/.zshrc`.

## Manual setup

The bootstrap is the normal path, but the workflow can be wired manually.

1. Copy the library: `cp git-deploy-lib.zsh ~/.git-deploy-lib.zsh`
2. Copy the template: `cp git-deploy-workflow.zsh ~/.acme-workflow.zsh`
3. Edit the project variables in the copied file.
4. Add `source "$HOME/.acme-workflow.zsh"` to `~/.zshrc`.
5. Reload: `exec zsh`

## Uninstalling

```sh
gdw-bootstrap --uninstall
```

The uninstall flow asks which prefix to remove, then strips that prefix's marker blocks from `~/.zshrc` and `~/.ssh/config`. Backups are made before any modification.

After the local cleanup, the uninstaller reads the project's workflow file to find the server and GitHub details and offers three additional steps:

**Remove the server-side deploy key.** SSHes into the server and deletes `~/.ssh/<prefix>_github_deploy` (and the `.pub`) and strips the `Host github-<prefix>` block from the server's `~/.ssh/config`.

**Delete the project folder on the server.** Prompts with the full path, then runs `rm -rf` on the server project directory.

**Delete the GitHub repository.** Prompts you to type the full repo name (`owner/repo`) to confirm — GitHub-style — then runs `gh repo delete --yes`.

Local SSH keys are never touched. The uninstaller prints the exact `rm` commands for the workflow file and shared library if you want to clean those up manually.

### Express uninstall

Pass `--express` to auto-answer every confirmation. The only prompt that remains is typing the GitHub repo name to confirm deletion — that gate is always interactive regardless of express mode.

Pass `--prefix` to skip even the prefix prompt, making the entire uninstall non-interactive up until the repo name confirmation:

```sh
gdw-bootstrap --uninstall --express --prefix theme
```

## Project structure

```text
zsh-git-deploy-workflow/
├── bootstrap-deploy.sh       # Interactive installer and uninstaller
├── git-deploy-lib.zsh        # Shared workflow logic
├── git-deploy-workflow.zsh   # Per-project workflow template
├── init-project.sh           # New-project scaffolder
├── .gdw-config.example       # User defaults template → copy to ~/.gdw-config
├── README.md
├── LICENSE
└── .gitignore
```

## Security model

This tool manages SSH-based Git workflows, so the boundaries matter.

- **Separate keys per concern.** Local GitHub access, server SSH access, and server-side GitHub deploy access each use their own key.
- **Read-only server deploy key.** The server-side GitHub key is registered as a read-only deploy key — the server can clone and pull but cannot push back.
- **Repo-specific server aliases.** Each repo on the server uses a unique SSH alias (e.g. `github-acme`) rather than a shared `Host github.com` override, so each can carry its own deploy key independently.
- **No passphrase on deploy keys.** Server-side deploy keys are generated without a passphrase so deploys run non-interactively. The security tradeoff is acceptable because these keys are read-only and owned by the server's user account (chmod 600).
- **`IdentitiesOnly yes`.** Every generated SSH block forces SSH to offer only the configured key for that host.
- **macOS Keychain integration.** macOS SSH blocks include `UseKeychain yes` and `AddKeysToAgent yes`. Linux blocks omit `UseKeychain` because it is a macOS-specific directive.
- **No private keys in the repo.** Keys stay in `~/.ssh` on the machines that use them.
- **No signing access on the server.** The server only needs pull access through its deploy key. Commit signing stays local.
- **Fast-forward-only server pulls.** Deploy uses `git pull --ff-only` so the server never creates surprise merge commits.
- **Backups before config changes.** Shell and SSH config files are backed up before marker blocks are written or edited.

## Troubleshooting

### `<prefix>pull` says local changes were detected

You have uncommitted or untracked files. Check with `<prefix>status`, then commit, branch, or discard the work intentionally.

### `<prefix>push` refuses because I am not on `main`

Expected. `<prefix>push` is the release path and only runs from `main`. For branch work, use plain Git commands and push the branch to GitHub for review.

### `deploy-<prefix>` fails with permission denied

The server may not have working GitHub deploy-key access. Test from your laptop through the server:

```sh
ssh <your-server-alias> "ssh -T git@github-<prefix>"
```

Expected output: `Hi you/repo! You've successfully authenticated...`

If that fails, the deploy key may not be registered, the key file path in the server's `~/.ssh/config` may be wrong, or the key's permissions may be too open (`chmod 600` the key file on the server).

### Server pull fails with merge conflicts or non-fast-forward error

The server has diverged from `main`. SSH in, inspect with `git status` and `git log`, resolve the state manually, then rerun the deploy command.

### `<prefix>push` hangs

Usually an SSH prompt, network issue, or key-agent issue. Test each link:

```sh
ssh -T git@github.com                          # local GitHub key
ssh <your-server-alias> "echo ok"              # server SSH
ssh <your-server-alias> "ssh -T git@github-<prefix>"  # server deploy key
```

### Express mode still asked me something

Express mode auto-derives everything it can, but a few fields require actual input when they cannot be guessed:

- **Server hostname** — if your `--ssh-host` alias does not exist in `~/.ssh/config` yet, the real hostname cannot be guessed. Pass `--ssh-hostname` to eliminate this prompt.
- **Prefix** — auto-derived from the directory name in express mode. Pass `--prefix` explicitly if you want a specific name.
- **Server path** — the only project-specific field with no reasonable universal default. Pass `--server-path`.

Setting `GDW_DEFAULT_SSH_HOST` in `~/.gdw-config` to an alias that already exists in `~/.ssh/config` is the most effective way to get fully prompt-free express runs.

### Bootstrap says it cannot find the workflow template

Run `bootstrap-deploy.sh` from the cloned workflow repo, or call it by full path so it can locate `git-deploy-lib.zsh` and `git-deploy-workflow.zsh` next to itself.

### GitHub CLI deploy-key registration fails

Bootstrap falls back to manual instructions. Copy the printed public key and add it in GitHub under **Repository → Settings → Deploy keys → Add deploy key**. Leave write access disabled.

If you want `gh` to handle it automatically in the future, grant the required scope:

```sh
gh auth refresh -s admin:repo_hook
```

## License

MIT. See [LICENSE](LICENSE).

Built originally for the [Severino Labs Security Layer](https://github.com/joeseverino/severino-labs-security-layer) WordPress plugin, then generalized for reusable Git-based project deployment.

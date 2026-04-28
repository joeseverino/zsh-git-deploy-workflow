# zsh-git-deploy-workflow

An **edit → commit → push → deploy** workflow for projects that live in a Git repo on your laptop and, optionally, a Git checkout on a server you SSH into.

One bootstrap command sets up everything: project-specific shell commands, SSH keys, SSH config entries, and a repeatable push/deploy flow.

```sh
acmepush "fix: tighten cache headers"
# stages everything, commits, pushes to GitHub, SSHes into the
# server, and runs git pull — all in one command
```

No CI service, no YAML pipeline, no third-party dashboard. Just `git`, `ssh`, and shell scripts. Readable, local, and easy to audit.

---

## Table of Contents

- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Daily use](#daily-use)
- [Modes](#modes)
- [What you get](#what-you-get)
- [Express mode](#express-mode)
- [Configuration defaults (~/.gdw-config)](#configuration-defaults-gdw-config)
- [CLI flags reference](#cli-flags-reference)
- [Safety and idempotence](#safety-and-idempotence)
- [What the bootstrap does](#what-the-bootstrap-does)
- [New-project scaffolding (gdw-init)](#new-project-scaffolding-gdw-init)
- [Architecture](#architecture)
- [Multiple projects](#multiple-projects)
- [Uninstalling](#uninstalling)
- [Manual setup](#manual-setup)
- [Project structure](#project-structure)
- [Security model](#security-model)
- [Troubleshooting](#troubleshooting)
- [What this is not](#what-this-is-not)
- [License](#license)

---

## Requirements

**Required:**

- macOS or Linux
- **zsh** as your interactive shell
- **bash 3.2+** to run the bootstrap scripts
- `git`, `ssh`, `ssh-keygen`, `sed`, `awk` — standard on most systems
- A GitHub repository for the project
- For server mode: a server you can SSH into

**Optional but strongly recommended:**

- **GitHub CLI (`gh`)** — enables automatic repo creation and SSH key registration. Install it, then run `gh auth login` before running the bootstrap. Without it (or if you skip signing in), the scripts walk you through the manual steps instead.

> **Ubuntu users:** Ubuntu's default shell is bash, not zsh. The workflow files are sourced from `~/.zshrc`, so you need zsh set as your login shell for the aliases and functions to be available in new terminals. After installing zsh (`sudo apt-get install zsh`), run:
> ```sh
> chsh -s $(which zsh)
> ```
> Then log out and back in. You only need to do this once per machine.

No language runtime, package manager, or framework required.

---

## Quick start

### 1. Clone this repo

If SSH is already set up on this machine:

```sh
git clone git@github.com:joeseverino/zsh-git-deploy-workflow.git
```

If this is a fresh machine where SSH isn't configured yet, use HTTPS instead — the bootstrap will set up SSH for your projects:

```sh
git clone https://github.com/joeseverino/zsh-git-deploy-workflow.git
```

### 2. Set up your defaults (optional but saves time)

```sh
cp zsh-git-deploy-workflow/.gdw-config.example ~/.gdw-config
$EDITOR ~/.gdw-config
```

The more you fill in, the less the bootstrap asks. See [Configuration defaults](#configuration-defaults-gdw-config).

### 3a. Starting a brand-new project

`init-project.sh` and `bootstrap-deploy.sh` are bash scripts — running them with `bash` is correct. They install the zsh workflow files; they don't need to run in zsh themselves.

```sh
mkdir my-plugin
cd my-plugin
bash ~/path/to/zsh-git-deploy-workflow/init-project.sh
```

This creates the repo, pushes it to GitHub, and chains directly into the bootstrap. After the first run, a `gdw-init` alias is added to `~/.zshrc`:

```sh
mkdir my-project && cd my-project && gdw-init
```

### 3b. Bootstrapping an existing project

```sh
cd ~/path/to/your-project
bash ~/path/to/zsh-git-deploy-workflow/bootstrap-deploy.sh
```

A `gdw-bootstrap` alias is added after the first run.

### 4. Reload your shell

```sh
exec zsh
acmehelp   # replace "acme" with the prefix you chose
```

### One-liner with express mode

With a populated `~/.gdw-config`, the full flow from empty directory to deployed server is a single command:

```sh
mkdir my-plugin && cd my-plugin
gdw-init --express \
  --prefix myplugin \
  --description "My WordPress plugin" \
  --server-path /home/user/public_html/wp-content/plugins/my-plugin
```

See [Express mode](#express-mode) for what this does automatically.

---

## Daily use

After bootstrap, everything runs through the prefix you chose. For prefix `acme`:

```sh
# Pull the latest before starting work
acmepull

# Make your changes, then commit, push, and deploy in one step
acmepush "fix: stop double-encoding URLs"

# Check what's changed
acmestatus

# Work on something that isn't ready to ship yet
acmebranch feature/new-thing
git push -u origin feature/new-thing

# Build a clean zip for review or distribution
acmezip

# Undo the last deploy (prompts for YES confirmation)
acmerevert
```

---

## Modes

### Server mode

For projects that deploy to a remote server — WordPress plugins, themes, static sites, or any app where deploy means "SSH in and pull latest."

`acmepush "message"` does this in order:

1. Confirms you are on `main`
2. Stages all changes
3. Stops cleanly if there is nothing to commit
4. Shows the pending status
5. Creates the commit
6. Pushes to GitHub
7. SSHes into the server and runs a fast-forward-only pull

If the server path does not exist yet, the first deploy clones the repo into place. If the path exists but is not a Git repo, it refuses to touch it.

### No-server mode

For libraries, scripts, or any project that does not deploy anywhere yet. `acmepush` stages, commits, and pushes to GitHub. The deploy step is skipped automatically.

To add a server later, rerun the bootstrap with the same prefix and choose `replace`.

---

## What you get

After bootstrap, your shell gets project-specific commands scoped to the prefix you chose. For prefix `acme`:

| Command | What it does |
| --- | --- |
| `acmepull` | Pulls latest `main`. Refuses if local edits exist. |
| `acmepush "message"` | Stages, commits, pushes, and deploys. Only runs from `main`. |
| `acmebranch <name>` | Creates a new branch from the current state. |
| `acmerevert` | Reverts the latest `main` commit after `YES` confirmation, pushes the revert, and redeploys. |
| `acmestatus` | Shows short Git status and current branch. |
| `acmezip` | Builds a clean ZIP from the current commit using `git archive`. |
| `deploy-acme` | Runs only the deploy step (server `git pull` or initial clone). |
| `acmehelp` | Shows the command list and configured paths. |
| `gdw-list` | Lists every bootstrapped project found in `~/.zshrc`. |

---

## Express mode

Pass `--express` to either script to skip all yes/no confirmations and run every step automatically.

```sh
gdw-init --express --description "My plugin" --server-path /var/www/my-plugin
# or
gdw-bootstrap --express --prefix theme --server-path /var/www/theme
```

In express mode:

- Every `[Y/n]` confirmation is automatically answered yes and logged.
- The command prefix is auto-derived from the project directory name (lowercased, non-alphanumeric characters stripped). `my-new-plugin` becomes `mynewplugin`. This happens in both interactive and express mode — express just skips the confirmation prompt. Pass `--prefix` to set something shorter.
- All fields that have a config default or can be derived (GitHub host, SSH alias, server alias, remote URL, zip path) are resolved silently.
- The server-side deploy key setup runs fully — key generation, SSH alias config, GitHub registration, and connection test — without pausing.
- The initial server deploy runs automatically at the end.

**The only prompt that cannot be skipped in express mode** is typing the full repo name to confirm GitHub repo deletion during uninstall. That gate is always interactive.

### Full express example

With `~/.gdw-config` populated:

```sh
mkdir acme-plugin && cd acme-plugin
gdw-init --express \
  --prefix acme \
  --description "Acme WordPress plugin" \
  --server-path /home/user/public_html/wp-content/plugins/acme-plugin
```

`--prefix` is recommended in express mode. Without it, a directory named `my-new-plugin` becomes the prefix `mynewplugin`, giving you longer daily commands like `mynewpluginpush`. A short explicit prefix like `acme` gives you `acmepush`.

This single command:

1. Writes `.gitignore` and `README.md`, runs `git init`, makes the initial commit
2. Creates the private GitHub repo and pushes via `gh`
3. Installs the shared deploy library and renders the workflow file
4. Reuses or creates SSH keys for GitHub and the server
5. Patches `~/.ssh/config` and `~/.zshrc` as needed
6. SSHes into the server and generates a project-specific deploy key
7. Registers the deploy key with GitHub via `gh repo deploy-key add`
8. Tests the server's GitHub authentication
9. Runs the initial deploy — cloning the repo at the server path

After this, `test6push "first change"` is the entire release flow.

---

## Configuration defaults (`~/.gdw-config`)

Both scripts source `~/.gdw-config` at startup. Any variable set there is used as a silent default, skipping the corresponding prompt.

Priority order for every setting: **CLI flag → `~/.gdw-config` → interactive prompt**

Copy the example to get started:

```sh
cp zsh-git-deploy-workflow/.gdw-config.example ~/.gdw-config
```

### Available variables

```sh
# ── init-project.sh ─────────────────────────────────────────────────────────

# Your GitHub username. Skips the username prompt.
GDW_DEFAULT_GH_USER="your-github-username"

# Default visibility for new repos. One of: public, private
GDW_DEFAULT_GH_VISIBILITY="private"

# ── bootstrap-deploy.sh ─────────────────────────────────────────────────────

# SSH host alias for your production server (must match a Host in ~/.ssh/config).
GDW_DEFAULT_SSH_HOST="myserver.net"

# GitHub SSH hostname. Almost always "github.com".
GDW_DEFAULT_GITHUB_HOST="github.com"

# Directory for zip review archives. Prefix and "-review.zip" are appended
# automatically — e.g. ~/Downloads/theme-review.zip
GDW_DEFAULT_ZIP_DIR="$HOME/Downloads"

# Server-side GitHub SSH alias pattern. __PREFIX__ is substituted at bootstrap
# time — e.g. "github-__PREFIX__" becomes "github-theme" for prefix "theme".
GDW_DEFAULT_SERVER_GITHUB_ALIAS="github-__PREFIX__"
```

A fully populated config means most projects only need a prefix and a server path — or nothing at all in express mode.

---

## CLI flags reference

### `init-project.sh` / `gdw-init`

```
--express                Auto-yes all confirmations; chains into bootstrap in express mode.
--dry-run                Preview every action; write nothing.
--description <text>     One-line project description.
--github-user <user>     GitHub username.
--visibility <v>         Repo visibility: public or private. Default: private.
```

All bootstrap flags below are also accepted by `gdw-init` and forwarded automatically when it chains into bootstrap.

### `bootstrap-deploy.sh` / `gdw-bootstrap`

**Modes:**

```
--express                Auto-yes all confirmations; runs every step without pausing.
--dry-run                Preview the plan; write nothing.
--uninstall              Remove a previous bootstrap: strips ~/.zshrc and ~/.ssh/config blocks,
                         removes the server deploy key and project folder, and deletes the
                         GitHub repo. Combine with --express and --prefix for a fully
                         non-interactive teardown (GitHub deletion still requires typing the repo name).
```

**Project:**

```
--prefix <p>             Command prefix (e.g. theme → themepull / themepush).
--label <l>              Human-readable project name.
--local-path <path>      Local clone path of the project.
--server-path <path>     Project path on the production server.
--zip-path <path>        Full output path for zip archives.
--no-server              No-server mode: commit + push only, no deploy.
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

---

## Safety and idempotence

The bootstrap is designed to be safe to rerun.

- **Dry run.** Use `--dry-run` to preview every change before writing anything.
- **Prefix conflict detection.** If the chosen prefix already exists, the bootstrap asks whether to replace or abort. In express mode, it auto-replaces.
- **Backups before any change.** `~/.zshrc` and `~/.ssh/config` are copied to timestamped `.bak.YYYYMMDD-HHMMSS` files before modification.
- **Marker blocks.** All generated config blocks are wrapped in prefix-specific markers so they can be cleanly removed by `--uninstall`.
- **Existing SSH config reuse.** If a matching `Host` block already exists, the bootstrap reads it instead of duplicating it.
- **SSH keys are never overwritten.** Existing keys are reused. Only missing keys are created.
- **Main-branch guard.** `<prefix>push` and `<prefix>revert` only run from `main`.
- **Dirty-tree guard.** Pull and revert refuse to continue if local changes or untracked files are present.
- **Fast-forward-only deploys.** Server deploys use `git pull --ff-only`, preventing silent merge commits on the server.
- **Server overwrite guard.** If the server path exists but is not a Git repo, deploy refuses to touch it.

---

## What the bootstrap does

Running `bootstrap-deploy.sh` on your laptop does the following:

1. Checks that `gh` is installed and signed in. If not, explains what you'll need to do manually.
2. Collects project settings — name, command prefix (auto-derived from the directory name, editable), and optional server details.
3. Offers a one-question "use default SSH settings?" shortcut so most users never see the individual hostname and key-path prompts.
4. Shows the full plan and asks for confirmation before writing anything.
5. Installs the shared library at `~/.git-deploy-lib.zsh`.
6. Creates any missing SSH keys with a plain-language explanation for each: your GitHub key (named `user@hostname`, shared across all projects on this machine) and, in server mode, a per-project server access key for SSHing into your server. Existing keys are always reused.
7. Patches `~/.ssh/config`. Normally skips any `Host` block that already exists. Exception: if a `Host github.com` block exists but has no `IdentityFile` line, the bootstrap cannot reliably bind to a specific key through it, so it adds a scoped `Host github-<prefix>` alias with an explicit `IdentityFile` instead. The existing block is always left untouched.
8. In server mode, installs your server SSH public key into the server's `authorized_keys` via `ssh-copy-id` (one password prompt) so all remaining SSH steps — and every future deploy — are password-free.
9. Registers the GitHub SSH key automatically (via `gh`) or walks you through the manual paste if `gh` is unavailable. After registration, tests the connection — waits automatically on the first attempt to allow for GitHub's key propagation delay.
10. Switches the local repo's origin remote from HTTPS to SSH if needed.
11. Pushes the initial commit if the repo was created by `gdw-init` but the SSH push was deferred because no key was set up yet.
12. Renders a small per-project workflow file at `~/.<prefix>-workflow.zsh`.
13. Adds one `source` block to `~/.zshrc`.
14. Adds a `gdw-bootstrap` convenience alias on first run.
15. In server mode, runs the server-side setup (see below).
16. Offers to run `deploy-<prefix>` immediately to do the initial server-side clone or pull.
17. Prints next steps — reload your shell and you're done.

### Server-side setup

When server mode is active, the bootstrap SSHes into the server and:

1. Generates a repo-specific deploy key without a passphrase (required for non-interactive deploys).
2. Writes a `Host github-<prefix>` block in the server's `~/.ssh/config`.
3. Attempts to register the deploy key with GitHub using `gh repo deploy-key add`. Falls back to a manual paste flow if GitHub CLI is unavailable or lacks `admin:repo_hook` scope.
4. Tests the server's GitHub authentication through the alias.

If you skipped the interactive setup, the next-steps output prints the exact manual commands to complete it yourself.

---

## New-project scaffolding (`gdw-init`)

`init-project.sh` (aliased as `gdw-init` after the first run) scaffolds a brand-new project from an empty directory.

```sh
mkdir my-plugin
cd my-plugin
gdw-init
```

It does the following:

1. Checks that `gh` is installed and signed in. If `gh` is present but not authenticated, it explains what you'll need to do manually and offers to continue or exit so you can run `gh auth login` first.
2. Uses the current directory name as the project name and GitHub repo name.
3. Prompts for a one-line description (or takes it from `--description`).
4. Detects your GitHub username from `gh`, global Git config, or `~/.gdw-config`.
5. Writes a starter `.gitignore` and `README.md`.
6. Runs `git init -b main`, stages everything, and makes the initial commit.
7. Creates the GitHub repo via `gh` and pushes the initial commit. If no SSH key is set up yet (fresh machine), the push is deferred — bootstrap handles it automatically in the next step after setting up the key. If `gh` is unavailable, prints the manual steps.
8. Adds the `gdw-init` alias to `~/.zshrc` on first run.
9. Chains directly into `bootstrap-deploy.sh` with the confirmed project path.

All bootstrap flags (`--prefix`, `--ssh-host`, `--server-remote`, etc.) are accepted by `gdw-init` and forwarded automatically.

### Preview with dry run

```sh
gdw-init --dry-run
```

---

## Architecture

The workflow uses a **shared library + thin per-project wrapper** pattern.

After bootstrapping projects named `acme`, `widgetco`, and `theme`, your home directory looks like this:

```text
~/.git-deploy-lib.zsh      # shared logic, installed once
~/.acme-workflow.zsh       # project context + wrappers
~/.widgetco-workflow.zsh   # project context + wrappers
~/.theme-workflow.zsh      # project context + wrappers
```

The shared library defines generic functions (`_gdw_pull`, `_gdw_push`, `_gdw_deploy`, etc.). Each per-project file sets the context variables and exposes the friendly command names:

```zsh
_acme_ctx() {
  GDW_PREFIX="acme"
  GDW_LABEL="Acme Plugin"
  GDW_REPO="$HOME/Code/acme"
  GDW_SSH_HOST="myserver"
  GDW_SERVER_PATH="$HOME/wp-content/plugins/acme"
  GDW_ZIP_OUTPUT="$HOME/Downloads/acme-review.zip"
  GDW_SERVER_REMOTE="git@github-acme:joeseverino/acme.git"
}

acmepull()    { _acme_ctx; _gdw_pull "$@"; }
acmepush()    { _acme_ctx; _gdw_push "$@"; }
deploy-acme() { _acme_ctx; _gdw_deploy "$@"; }
```

Improvements to `git-deploy-lib.zsh` propagate to all projects by rerunning bootstrap.

---

## Multiple projects

Each project uses its own prefix, workflow file, and SSH config markers. Projects do not interfere with each other.

```sh
gdw-bootstrap --prefix acme    # → acmepush
gdw-bootstrap --prefix theme   # → themepush
gdw-bootstrap --prefix blog    # → blogpush
```

`gdw-list` shows all bootstrapped projects currently sourced from `~/.zshrc`.

---

## Uninstalling

```sh
gdw-bootstrap --uninstall
```

The uninstall flow asks which prefix to remove, then:

1. Strips that prefix's marker blocks from `~/.zshrc` and `~/.ssh/config` (backups made first).
2. Offers to SSH into the server and remove the deploy key and `Host github-<prefix>` alias.
3. Offers to delete the project folder on the server (`rm -rf`). Prompts twice to confirm.
4. Offers to delete the GitHub repository — you must type the full repo name (`owner/repo`) to confirm, GitHub-style. This gate is always interactive regardless of express mode.

Local SSH keys are never touched. The uninstaller prints the exact `rm` commands for the workflow file and shared library if you want to clean those up manually.

### Express uninstall

```sh
gdw-bootstrap --uninstall --express --prefix theme
```

Auto-answers every prompt. The only manual step is typing the GitHub repo name to confirm deletion.

---

## Manual setup

The bootstrap is the normal path, but the workflow can be wired by hand:

1. Copy the library: `cp git-deploy-lib.zsh ~/.git-deploy-lib.zsh`
2. Copy the template: `cp git-deploy-workflow.zsh ~/.acme-workflow.zsh`
3. Edit the project variables in the copied file.
4. Add `source "$HOME/.acme-workflow.zsh"` to `~/.zshrc`.
5. Reload: `exec zsh`

---

## Project structure

```text
zsh-git-deploy-workflow/
├── bootstrap-deploy.sh       # Installer and uninstaller
├── git-deploy-lib.zsh        # Shared workflow logic
├── git-deploy-workflow.zsh   # Per-project workflow template
├── init-project.sh           # New-project scaffolder
├── gdw-test-reset.sh         # Test utility — undoes everything bootstrap + init created
├── .gdw-config.example       # User defaults template → copy to ~/.gdw-config
├── README.md
├── LICENSE
└── .gitignore
```

---

## Security model

- **Separate keys per concern.** Local GitHub access, server SSH access, and server-side GitHub deploy access each use their own key.
- **Read-only server deploy key.** The server-side GitHub key is registered as a deploy key with no write access — the server can clone and pull but cannot push.
- **Repo-specific server aliases.** Each repo on the server uses a unique SSH alias (e.g. `github-acme`) so each can carry its own deploy key independently.
- **Passphrase guidance per key type.** Your GitHub key and server access key can have a passphrase — ssh-agent caches it so you only type it once per session. Server-side deploy keys must have no passphrase because the server runs `git pull` non-interactively; a passphrase would cause it to hang.
- **`IdentitiesOnly yes`.** Every generated SSH block forces SSH to offer only the configured key for that host.
- **macOS Keychain integration.** macOS SSH blocks include `UseKeychain yes` and `AddKeysToAgent yes`. Linux blocks omit `UseKeychain` because it is a macOS-only directive.
- **No private keys in the repo.** Keys stay in `~/.ssh` on the machines that use them.
- **Fast-forward-only server pulls.** Deploys use `git pull --ff-only` so the server never silently creates merge commits.
- **Backups before config changes.** Shell and SSH config files are backed up before any marker block is written or modified.

---

## Troubleshooting

### `<prefix>pull` says local changes were detected

You have uncommitted or untracked files. Check with `<prefix>status`, then commit, branch, or discard the work intentionally.

### `<prefix>push` refuses because I am not on `main`

Expected. `<prefix>push` is the release path and only runs from `main`. For branch work, push with plain `git push -u origin <branch>`.

### `deploy-<prefix>` fails with permission denied

The server may not have working GitHub deploy-key access. Test it from your laptop:

```sh
ssh <your-server-alias> "ssh -T git@github-<prefix>"
```

Expected: `Hi you/repo! You've successfully authenticated...`

If that fails, the deploy key may not be registered, the path in the server's `~/.ssh/config` may be wrong, or the key permissions may be too open (`chmod 600` the key file on the server).

### Server pull fails with a non-fast-forward error

The server's repo has diverged from `main`. SSH in, inspect with `git status` and `git log`, resolve the state manually, then rerun deploy.

### `<prefix>push` hangs

Usually an SSH prompt, network issue, or key-agent problem. Test each link in sequence:

```sh
ssh -T git@github.com                                          # local GitHub key
ssh <your-server-alias> "echo ok"                              # server SSH
ssh <your-server-alias> "ssh -T git@github-<prefix>"          # server deploy key
```

### Express mode still asked me something

Express mode auto-derives everything it can. A few fields have no universal default:

- **Server hostname** — if your `--ssh-host` alias does not exist in `~/.ssh/config`, the hostname cannot be guessed. Pass `--ssh-hostname` to eliminate this prompt.
- **Server path** — the only project-specific field that cannot be derived. Pass `--server-path`.
- **Prefix** — auto-derived from the directory name. Pass `--prefix` for something shorter.

Setting `GDW_DEFAULT_SSH_HOST` in `~/.gdw-config` to an alias that already exists in `~/.ssh/config` is the most effective way to get fully prompt-free runs.

### Bootstrap asked for my server password multiple times

The bootstrap SSHes into your server several times — for the deploy key setup, reading the key back, testing GitHub auth, and the initial deploy. If key-based auth isn't set up on your server yet, each connection falls back to a password prompt.

The bootstrap now includes a **"Server key authentication"** step that runs `ssh-copy-id` to push your server SSH key into the server's `authorized_keys`. You enter your password once for that step, and every subsequent SSH call — including all remaining bootstrap steps and all future deploys — is password-free.

If you skipped that step or it failed, you can run it manually at any time:

```sh
ssh-copy-id -i ~/.ssh/<prefix>_server <your-server-alias>
```

To confirm key auth is working:

```sh
ssh <your-server-alias> "echo ok"
# Should print: ok — with no password prompt
```

### Bootstrap asked for my SSH key passphrase multiple times on Linux

On Linux without a desktop session, `ssh-agent` may not be running, so the passphrase for your server key isn't cached between connections. Start an agent and add your key for the session:

```sh
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/<prefix>_server
```

After that, SSH will reuse the cached key without re-prompting until you log out. To make this automatic on login, add those two lines to your `~/.bashrc` or `~/.zshrc`.

### Bootstrap says authentication failed but `ssh -T git@github.com` works

GitHub takes a few seconds to activate a newly registered key. The bootstrap waits 5 seconds automatically on the first failure and retries silently. If it still fails after 3 attempts, the bootstrap continues and your key will work shortly after. Test with:

```sh
ssh -T git@github.com
# Expected: Hi <you>! You've successfully authenticated...
```

If that succeeds, everything is fine — your push commands will work once you reload your shell.

### Bootstrap added a `Host github-<prefix>` entry even though I didn't ask for a server

This happens when your existing `~/.ssh/config` already has a `Host github.com` block but it has no `IdentityFile` line — common when another tool (like 1Password SSH agent or a corporate setup) manages GitHub key selection. In that case the bootstrap can't reliably tie its workflow to a specific key through that block, so it creates a dedicated `Host github-<prefix>` alias with an explicit `IdentityFile` instead. Your existing `Host github.com` block is left completely untouched.

If you'd rather not have the extra alias, add an `IdentityFile` line to your existing `Host github.com` block pointing at the key you want GDW to use, then rerun the bootstrap — it will find the key and skip creating the alias.

### Bootstrap says GitHub CLI is installed but not signed in

The bootstrap will offer to run `gh auth login` for you inline — just answer yes when prompted. If you prefer to sign in separately first, run `gh auth login` in your terminal, follow the prompts, then rerun the bootstrap. Either way works; signing in lets the bootstrap register your SSH key and deploy key automatically instead of walking you through the manual paste steps.

### Bootstrap says it cannot find the workflow template

Run `bootstrap-deploy.sh` by full path so it can find `git-deploy-lib.zsh` and `git-deploy-workflow.zsh` next to itself, or use the `gdw-bootstrap` alias which bakes in the path automatically.

### GitHub CLI deploy-key registration fails

Bootstrap falls back to manual instructions — it prints the public key and tells you exactly where to paste it in GitHub. To let `gh` handle it automatically in the future:

```sh
gh auth refresh -s admin:repo_hook
```

---

## What this is not

- **Not a CI/CD service.** There is no webhook, pipeline runner, or hosted dashboard. Deploys run from your terminal.
- **Not for teams.** This workflow is designed for a single developer owning the full deploy path.
- **Not a zero-downtime deployer.** Deploy is `git pull`. For blue-green deploys or rolling restarts, use a proper deploy tool.
- **Not opinionated about your stack.** The workflow does not care whether your project is PHP, Python, Node, or static HTML. If it lives in a Git repo, this workflow can deploy it.

---

## License

MIT. See [LICENSE](LICENSE).

Built originally for the [Severino Labs Security Layer](https://github.com/joeseverino/severino-labs-security-layer) WordPress plugin, then generalized for reusable Git-based project deployment.

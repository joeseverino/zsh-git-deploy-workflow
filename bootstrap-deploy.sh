#!/usr/bin/env bash
#
# bootstrap-deploy.sh — install a customized git deploy workflow.
#
# Interactively bootstraps a complete edit → commit → push → deploy loop
# for any project. Customizes the workflow command names to your project,
# installs a shared deploy library, renders a small per-project wrapper,
# reuses existing SSH configuration when available, and optionally helps
# create a server-side GitHub deploy key.
#
# Usage
# -----
#   bash bootstrap-deploy.sh              # interactive install
#   bash bootstrap-deploy.sh --dry-run    # preview every change, write nothing
#   bash bootstrap-deploy.sh --uninstall  # cleanly remove a previous bootstrap
#   bash bootstrap-deploy.sh --help
#
# What this DOES
#   1. Prompts for project name, command prefix, local repo path, and
#      optional production server details.
#   2. Reuses existing ~/.ssh/config Host blocks when available instead
#      of duplicating user-managed SSH config.
#   3. Reuses existing SSH keys when available and only creates missing
#      keys after confirmation.
#   4. Installs a shared git deploy library at ~/.git-deploy-lib.zsh.
#   5. Renders a small per-project workflow file at ~/.{prefix}-workflow.zsh.
#   6. Adds one source block to ~/.zshrc.
#   7. Optionally SSHes into the production server and helps generate a
#      repo-specific read-only GitHub deploy key.
#
# What this does NOT do
#   - Require GitHub CLI; if gh is unavailable or lacks the right scope,
#     it falls back to a manual deploy-key paste flow.
#   - Replace existing user-managed SSH config blocks.
#
# Tested on macOS (bash 3.2 / 5.x) and Linux (bash 4.x+).
# Core dependencies: sed, awk, ssh-keygen, ssh — standard on all systems.
# Optional: GitHub CLI (gh) — enables automatic SSH key and deploy-key
# registration. Without it the script walks you through the manual steps.

set -euo pipefail

# Print a clear message if the script exits unexpectedly so the cause
# is never just a silent drop back to the shell prompt.
trap 'echo; echo "  ✗ bootstrap-deploy.sh exited unexpectedly at line $LINENO (exit $?)." >&2; echo "  If this looks like a bug, open an issue and paste the output above." >&2' ERR

# ---------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------

_preflight_error() { echo "Error: $*" >&2; }
_preflight_warn()  { echo "Warning: $*" >&2; }

# Hard requirements — cannot proceed without these.
_preflight_ok=1
for _tool in zsh git ssh ssh-keygen sed awk; do
  if ! command -v "$_tool" >/dev/null 2>&1; then
    _preflight_error "$_tool is required but not installed."
    case "$_tool" in
      zsh)            echo "  Ubuntu/Debian:  sudo apt-get install zsh" >&2 ;;
      git)            echo "  Ubuntu/Debian:  sudo apt-get install git" >&2 ;;
      ssh|ssh-keygen) echo "  Ubuntu/Debian:  sudo apt-get install openssh-client" >&2 ;;
      sed|awk)        echo "  Ubuntu/Debian:  sudo apt-get install sed gawk" >&2 ;;
    esac
    _preflight_ok=0
  fi
done
[ "$_preflight_ok" -eq 0 ] && exit 1

# GitHub CLI — optional but strongly recommended.
if ! command -v gh >/dev/null 2>&1; then
  echo "" >&2
  echo "  ┌─ GitHub CLI (gh) not found ──────────────────────────────────────┐" >&2
  echo "  │  Without it, two steps require manual action:                    │" >&2
  echo "  │    • Registering your SSH public key at github.com/settings/keys │" >&2
  echo "  │    • Adding the server deploy key to your GitHub repo            │" >&2
  echo "  │                                                                  │" >&2
  echo "  │  Install: https://github.com/cli/cli#installation                │" >&2
  echo "  │  Ubuntu:  see above link — needs the gh apt repo added first     │" >&2
  echo "  │  macOS:   brew install gh                                        │" >&2
  echo "  │  Then run: gh auth login, select "GitHub.com" , "SSH" ,          │" >&2
  echo "  │  Optional: Select "Yes" to generate SSH key to use with GitHub   │" >&2
  echo "  │  Select your title, and then login with web browser.             │" >&2
  echo "  └──────────────────────────────────────────────────────────────────┘" >&2
  echo "" >&2
  printf '  Continue without gh? [Y/n]: '
  read -r _gh_ans
  case "$(printf '%s' "${_gh_ans:-y}" | tr '[:upper:]' '[:lower:]')" in
    n|no) echo "Install gh, then rerun." >&2; exit 0 ;;
  esac
fi

# gh is installed — check that the user is actually signed in.
# An unauthenticated gh is worse than no gh: it silently skips auto-registration
# and leaves the user staring at a manual key-paste step with no explanation.
if command -v gh >/dev/null 2>&1 && ! gh auth token >/dev/null 2>&1; then
  echo "" >&2
  echo "  ┌─ GitHub CLI (gh) found but not signed in ────────────────────────┐" >&2
  echo "  │  gh is installed but you haven't authenticated it yet.           │" >&2
  echo "  │                                                                  │" >&2
  echo "  │  Signing in lets this script register your SSH key with GitHub   │" >&2
  echo "  │  automatically. Without it you'll paste the key manually instead.│" >&2
  echo "  └──────────────────────────────────────────────────────────────────┘" >&2
  echo "" >&2
  printf '  Sign in to GitHub CLI now? [Y/n]: '
  read -r _gh_auth_ans
  case "$(printf '%s' "${_gh_auth_ans:-y}" | tr '[:upper:]' '[:lower:]')" in
    y|yes|'')
      gh auth login
      # Verify it worked before continuing.
      if ! gh auth token >/dev/null 2>&1; then
        echo "" >&2
        echo "  gh auth login did not complete successfully." >&2
        echo "  Continuing without gh — SSH key registration will be manual." >&2
        echo "" >&2
      else
        echo "" >&2
        echo "  Signed in. Continuing..." >&2
        echo "" >&2
      fi
      ;;
    *)
      echo "" >&2
      echo "  Continuing without gh — SSH key registration will be a manual step." >&2
      echo "" >&2
      ;;
  esac
fi

# ---------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/git-deploy-workflow.zsh"
LIB_SOURCE="$SCRIPT_DIR/git-deploy-lib.zsh"
LIB_DEST="$HOME/.git-deploy-lib.zsh"

ZSHRC="$HOME/.zshrc"
SSH_CONFIG="$HOME/.ssh/config"

# Optional user defaults file. If present, its values are used as
# implicit answers and the corresponding prompts are skipped.
#
# Supported variables:
#   GDW_DEFAULT_GH_USER                e.g. "joeseverino"
#   GDW_DEFAULT_GH_VISIBILITY          "public" or "private"
#   GDW_DEFAULT_SSH_HOST               e.g. "jseverino.net"
#   GDW_DEFAULT_GITHUB_HOST            e.g. "github.com"
#   GDW_DEFAULT_ZIP_DIR                e.g. "$HOME/Downloads"
#   GDW_DEFAULT_SERVER_GITHUB_ALIAS    e.g. "github-__PREFIX__"
GDW_CONFIG="$HOME/.gdw-config"
[ -f "$GDW_CONFIG" ] && . "$GDW_CONFIG"

# Marker blocks — used so we can find/remove our additions later.
# __PREFIX__ is replaced at runtime so multiple projects can coexist.
ZSHRC_MARK_START="# >>> __PREFIX__ git deploy workflow >>>"
ZSHRC_MARK_END="# <<< __PREFIX__ git deploy workflow <<<"
SSH_MARK_START="# >>> __PREFIX__ deploy hosts >>>"
SSH_MARK_END="# <<< __PREFIX__ deploy hosts <<<"

DRY_RUN=0
UNINSTALL=0
FROM_INIT=0
FROM_INIT_PATH=""
EXPRESS=0

# CLI-provided values — when set, the corresponding prompt is bypassed entirely.
CLI_PREFIX=""
CLI_LABEL=""
CLI_LOCAL_PATH=""        # user-facing alias for --from-init
CLI_SERVER_PATH=""
CLI_ZIP_PATH=""
CLI_GITHUB_HOST=""
CLI_GITHUB_KEY=""
CLI_SSH_HOST=""
CLI_SSH_HOSTNAME=""
CLI_SSH_USER=""
CLI_SSH_PORT=""
CLI_SERVER_KEY=""
CLI_SERVER_GITHUB_ALIAS=""
CLI_SERVER_REMOTE=""
CLI_NO_SERVER=0

# Runtime variables — initialized here so they are always defined even
# in no-server mode (set -u would crash on any unset reference otherwise).
HAS_SERVER=1
PROJECT_PREFIX=""
PROJECT_LABEL=""
REPO_PATH=""
GITHUB_HOST=""
GITHUB_KEY=""
ADD_GITHUB_HOST=1
SSH_HOST=""
SSH_HOSTNAME=""
SSH_USER=""
SSH_PORT=""
SERVER_KEY=""
SERVER_PATH=""
ZIP_PATH=""
SERVER_REMOTE=""
SERVER_GITHUB_ALIAS=""
ADD_SERVER_HOST=0


# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------

# Colorized output, but only if stdout is a terminal.
_color() {
  if [ -t 1 ]; then
    printf '\033[%sm%s\033[0m\n' "$1" "$2"
  else
    printf '%s\n' "$2"
  fi
}
info() { _color "36" "$*"; }
ok()   { _color "32" "$*"; }
warn() { _color "33" "$*"; }
err()  { _color "31" "$*" >&2; }

section() {
  echo
  _color "1;36" "── $* ──"
}

plan() {
  printf '  %s\n' "$*"
}

# Shell-safe single-quoting for values embedded in remote SSH command
# strings or generated shell files. Wraps $1 in single quotes, with any
# embedded single quotes escaped as '\'' (the POSIX portable approach).
# Works with bash 3.2+; does not require printf %q (bash 4+ only).
#
# Usage:  cmd="ssh-keygen ... -C $(_sq "$PROJECT_LABEL deploy") ..."
_sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}


# ---------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------

# ask "Question" "default" -> echoes the answer
ask() {
  local question="$1" default="${2:-}"
  local suffix=""
  [ -n "$default" ] && suffix=" [$default]"
  local answer=""
  read -r -p "  ${question}${suffix}: " answer
  [ -n "$answer" ] && printf '%s' "$answer" || printf '%s' "$default"
}

# confirm "Question" -> returns 0 (yes) or 1 (no).
# In express mode, always returns 0 (yes) without prompting.
confirm() {
  if [ "$EXPRESS" -eq 1 ]; then
    printf '  %s [Y/n]: Y  (express)\n' "$1"
    return 0
  fi
  local raw=""
  read -r -p "  $1 [Y/n]: " raw
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    n|no) return 1 ;;
    *)    return 0 ;;
  esac
}

# confirm_repo "owner/repo" -> GitHub-style type-to-confirm for repo deletion.
# Always interactive — this is the safety gate in express uninstall mode.
confirm_repo() {
  local repo="$1"
  printf '\n  To confirm deletion, type the repository name (%s): ' "$repo"
  local typed=""
  read -r typed
  if [ "$typed" = "$repo" ]; then
    return 0
  else
    warn "  Input did not match — skipping GitHub repo deletion."
    return 1
  fi
}


# ---------------------------------------------------------------------
# File patching helpers
# ---------------------------------------------------------------------

# Make a timestamped backup of $1 if it exists. Echoes the backup path.
backup_file() {
  local target="$1"
  [ -e "$target" ] || return 0
  local backup
  backup="${target}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$target" "$backup"
  echo "$backup"
}

# Strip a marker-bracketed block from a file in place.
# strip_block <file> <start-marker> <end-marker>
strip_block() {
  local file="$1" start="$2" end="$3"
  [ -f "$file" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v start="$start" -v end="$end" '
    BEGIN { skip = 0 }
    $0 == start { skip = 1; next }
    skip && $0 == end { skip = 0; next }
    !skip { print }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

# Append a marker-bracketed block to a file. Idempotent — does nothing
# if the block is already present.
# append_block <file> <start-marker> <end-marker> <body>
append_block() {
  local file="$1" start="$2" end="$3" body="$4"
  if [ -f "$file" ] && grep -Fq "$start" "$file"; then
    warn "  $file already contains the block — skipped."
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  {
    [ -f "$file" ] && cat "$file"
    printf '\n%s\n%s\n%s\n' "$start" "$body" "$end"
  } >"${file}.new"
  mv "${file}.new" "$file"
}


# ---------------------------------------------------------------------
# SSH config helpers
# ---------------------------------------------------------------------

# Returns 0 if ~/.ssh/config has an exact Host entry for the alias.
# Supports Host lines with multiple aliases, e.g. `Host github.com github`.
ssh_config_has_host() {
  local host="$1"
  [ -f "$SSH_CONFIG" ] || return 1

  awk -v target="$host" '
    /^[[:space:]]*[Hh]ost[[:space:]]+/ {
      for (i = 2; i <= NF; i++) {
        if ($i == target) found = 1
      }
    }
    END { exit found ? 0 : 1 }
  ' "$SSH_CONFIG"
}

# Extract one field from an exact Host block in ~/.ssh/config.
# Usage: ssh_config_get_host_field "jseverino.net" "IdentityFile"
ssh_config_get_host_field() {
  local host="$1" field="$2"
  [ -f "$SSH_CONFIG" ] || return 1

  awk -v target="$host" -v field="$field" '
    BEGIN { in_block = 0 }

    /^[[:space:]]*[Hh]ost[[:space:]]+/ {
      in_block = 0
      for (i = 2; i <= NF; i++) {
        if ($i == target) in_block = 1
      }
      next
    }

    in_block && tolower($1) == tolower(field) {
      $1 = ""
      sub(/^[[:space:]]+/, "")
      print
      exit
    }
  ' "$SSH_CONFIG"
}

# Expand leading ~ in SSH config paths.
expand_ssh_path() {
  local path="${1:-}"
  if [ -z "$path" ]; then
    return 0
  fi
  if [ "$path" = "~" ]; then
    printf '%s' "$HOME"
    return 0
  fi
  if [ "${path:0:2}" = "~/" ]; then
    printf '%s/%s' "$HOME" "${path:2}"
    return 0
  fi
  printf '%s' "$path"
}

# ---------------------------------------------------------------------
# Workflow file rendering
# ---------------------------------------------------------------------

# Render the template with project-specific names + paths.
# The template is small — it sources the shared lib, sets context,
# and defines thin wrappers. This function does straight string
# substitution against the `ship` placeholder names.
#
# render_workflow <prefix> <project_label> <repo_path> <ssh_host>
#                 <server_path> <zip_path> <server_remote>
render_workflow() {
  local prefix="$1" label="$2" repo="$3" ssh_host="$4"
  local server_path="$5" zip_path="$6" server_remote="${7:-}"

  # Pre-escape all user-supplied values for safe single-quoting in the
  # generated .zsh file. Single-quoting is used throughout because it
  # avoids double-quote pitfalls ($, \, backticks) with no extra escaping
  # needed — only embedded single quotes require the '\'' treatment.
  # These are passed to awk as -v variables; awk receives them literally
  # (awk -v only processes \n \t \\ etc., not \').
  local _label_sq _repo_sq _host_sq _server_sq _zip_sq _remote_sq
  _label_sq="$(_sq "$label")"
  _repo_sq="$(_sq "$repo")"
  _host_sq="$(_sq "$ssh_host")"
  _server_sq="$(_sq "$server_path")"
  _zip_sq="$(_sq "$zip_path")"
  _remote_sq="$(_sq "$server_remote")"

  # Order matters: replace `_ship_ctx` and `deploy-ship` patterns before
  # the generic `ship*` -> `${prefix}*` rules so we don't double-rewrite.
  sed \
    -e "s/_ship_ctx/_${prefix}_ctx/g" \
    -e "s/deploy-ship/deploy-${prefix}/g" \
    -e "s/shippull/${prefix}pull/g" \
    -e "s/shippush/${prefix}push/g" \
    -e "s/shipbranch/${prefix}branch/g" \
    -e "s/shiprevert/${prefix}revert/g" \
    -e "s/shipstatus/${prefix}status/g" \
    -e "s/shipzip/${prefix}zip/g" \
    -e "s/shiphelp/${prefix}help/g" \
    "$TEMPLATE" |
  awk -v prefix="$prefix" \
      -v label_sq="$_label_sq" \
      -v repo_sq="$_repo_sq" \
      -v host_sq="$_host_sq" \
      -v server_sq="$_server_sq" \
      -v zip_sq="$_zip_sq" \
      -v remote_sq="$_remote_sq" '
    /^  GDW_PREFIX=/        { print "  GDW_PREFIX='\''" prefix "'\''"; next }
    /^  GDW_LABEL=/         { print "  GDW_LABEL=" label_sq; next }
    /^  GDW_REPO=/          { print "  GDW_REPO=" repo_sq; next }
    /^  GDW_SSH_HOST=/      { print "  GDW_SSH_HOST=" host_sq; next }
    /^  GDW_SERVER_PATH=/   { print "  GDW_SERVER_PATH=" server_sq; next }
    /^  GDW_ZIP_OUTPUT=/    { print "  GDW_ZIP_OUTPUT=" zip_sq; next }
    /^  GDW_SERVER_REMOTE=/ { print "  GDW_SERVER_REMOTE=" remote_sq; next }
    { print }
  '
}


# Install the shared lib (once per machine). Idempotent — copies if the
# repo's lib is newer or if the destination is missing.
install_shared_lib() {
  if [ ! -f "$LIB_SOURCE" ]; then
    err "Shared library not found at $LIB_SOURCE"
    err "Run this script from inside the cloned repo."
    exit 1
  fi

  if [ ! -f "$LIB_DEST" ] || ! cmp -s "$LIB_SOURCE" "$LIB_DEST"; then
    cp "$LIB_SOURCE" "$LIB_DEST"
    chmod 644 "$LIB_DEST"
    ok "  Installed shared library: $LIB_DEST"
  else
    info "  Shared library already up to date: $LIB_DEST"
  fi
}


# ---------------------------------------------------------------------
# SSH key generation
# ---------------------------------------------------------------------

# generate_key <key_path> <comment> [github|server|deploy]
#   github — local key for authenticating to GitHub; passphrase optional
#   server — local key for SSHing into your server; passphrase optional
#   deploy — server-side read-only GitHub deploy key; NO passphrase (non-interactive)
generate_key() {
  local key_path="$1" comment="$2" key_type="${3:-github}"

  if [ -z "$key_path" ]; then
    warn "  Empty key path — skipped."
    return 0
  fi

  if [ -f "$key_path" ]; then
    ok "  Key already exists at $key_path — reusing it."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "Would create SSH key: $key_path  (comment: $comment)"
    return 0
  fi

  echo
  case "$key_type" in
    deploy)
      info "  ┌─ Creating server deploy key ────────────────────────────────────┐"
      info "  │  This key lives on your server and lets it pull from GitHub.    │"
      info "  │  It is read-only — the server can clone/pull but not push.      │"
      info "  │                                                                 │"
      info "  │  Private key : $key_path"
      info "  │  Public key  : ${key_path}.pub  ← registered as a GitHub deploy key"
      info "  │                                                                 │"
      info "  │  Passphrase: press Enter twice for NO passphrase.               │"
      info "  │  (The server runs git pull non-interactively — a passphrase     │"
      info "  │  would cause it to hang waiting for input.)                     │"
      info "  └─────────────────────────────────────────────────────────────────┘"
      ;;
    server)
      info "  ┌─ Creating your server SSH key ──────────────────────────────────┐"
      info "  │  This key lets your laptop SSH into your server.                │"
      info "  │                                                                 │"
      info "  │  Private key : $key_path"
      info "  │                                                                 │"
      info "  │  Passphrase: you can set one — ssh-agent will cache it so you   │"
      info "  │  only type it once per login session. Press Enter twice to      │"
      info "  │  skip (less secure but simpler).                                │"
      info "  └─────────────────────────────────────────────────────────────────┘"
      ;;
    *)
      info "  ┌─ Creating your GitHub SSH key ──────────────────────────────────┐"
      info "  │  An SSH key is a cryptographic identity for this machine.       │"
      info "  │  GitHub uses it to verify your pushes — no password needed      │"
      info "  │  once it is registered.                                         │"
      info "  │                                                                 │"
      info "  │  Private key : $key_path"
      info "  │  Public key  : ${key_path}.pub  ← registered with your GitHub account"
      info "  │                                                                 │"
      info "  │  Passphrase: you can set one — ssh-agent will cache it so you   │"
      info "  │  only type it once per login session. Press Enter twice to      │"
      info "  │  skip (less secure but simpler).                                │"
      info "  └─────────────────────────────────────────────────────────────────┘"
      ;;
  esac
  echo
  mkdir -p "$(dirname "$key_path")"
  chmod 700 "$(dirname "$key_path")"
  ssh-keygen -t ed25519 -f "$key_path" -C "$comment"
  echo
  ok "  SSH key created: $key_path"
  if [ "$key_type" = "github" ]; then
    info "  The public key will be registered with GitHub in the next step."
  fi
  echo
}


# ---------------------------------------------------------------------
# GitHub authentication verification
# ---------------------------------------------------------------------

# verify_github_auth <github_host> <key_path>
#
# Tests SSH auth to github_host. If it fails:
#   1. Attempts to register the key via `gh api /user/keys` (silent, non-interactive).
#   2. If that fails or gh is unavailable, shows the public key, prints the
#      settings URL, and waits for the user to press Enter before retesting.
#   3. In express mode, skips the interactive wait — tries gh API only and warns
#      if it still fails.
verify_github_auth() {
  local host="$1" key="$2"

  section "GitHub authentication"

  _test_gh_auth() {
    # Capture output before grepping — piping directly causes set -o pipefail
    # to return ssh's exit code (always 1, GitHub denies shell access) instead
    # of grep's, making the test fail even when auth succeeds.
    local _out
    _out="$(ssh -o BatchMode=yes -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        -T "git@${host}" 2>&1 || true)"
    printf '%s' "$_out" | grep -qi "successfully authenticated"
  }

  # Only trust a passing auth test if the key file actually exists on disk.
  # If the file is gone but ssh-agent still has it cached in memory, SSH will
  # succeed — but the key would be lost after the next reboot and the user
  # would have no idea. Force a fresh setup if the file is missing.
  if [ ! -f "$key" ]; then
    warn "  Key file not found at $key."
    warn "  It may have been deleted. The bootstrap will create a new one."
    echo
  elif _test_gh_auth; then
    ok "  Authenticated with ${host}."
    return 0
  fi

  warn "  SSH key not yet registered with ${host}."
  echo

  # ── Try to register automatically via gh CLI ───────────────────────
  local registered=0

  if command -v gh >/dev/null 2>&1; then

    # gh is present but not signed in — offer to run gh auth login inline.
    # gh auth login can also register the SSH key in one flow if the user
    # chooses the SSH protocol option during login.
    if ! gh auth token >/dev/null 2>&1; then
      echo
      _color "1;33" "  ══════════════════════════════════════════════════════════════════"
      _color "1;33" "  ACTION REQUIRED: Sign in to GitHub CLI"
      _color "1;33" "  ══════════════════════════════════════════════════════════════════"
      echo
      info "  gh is installed but you haven't authenticated it yet."
      info "  Signing in lets the bootstrap register your SSH key automatically."
      info "  When prompted, choosing 'SSH' as your protocol can also upload"
      info "  your existing key at $key.pub — so you may not need a separate step."
      echo
      if [ "$EXPRESS" -eq 0 ]; then
        printf '  Run gh auth login now? [Y/n]: '
        read -r _inline_gh_ans
        case "$(printf '%s' "${_inline_gh_ans:-y}" | tr '[:upper:]' '[:lower:]')" in
          y|yes|'')
            gh auth login
            echo
            ;;
        esac
      fi
    fi

    # Now try auto-registration (gh may be freshly authed, or was already authed)
    if gh auth token >/dev/null 2>&1; then
      info "  Attempting to register key with GitHub via gh..."
      local key_title
      key_title="$(whoami)@$(hostname -s 2>/dev/null || echo 'local')"
      if gh api /user/keys \
           -f title="$key_title" \
           -f key="$(cat "${key}.pub" 2>/dev/null || true)" \
           >/dev/null 2>&1; then
        ok "  Key registered with GitHub automatically."
        registered=1
      else
        # Most likely the key was already added (e.g. via gh auth login SSH flow above)
        info "  Key may already be registered — verifying..."
        registered=1
      fi
    fi
  fi

  # ── Manual fallback (no gh, or gh auth failed) ──────────────────────
  if [ "$registered" -eq 0 ]; then
    echo
    _color "1;33" "  ══════════════════════════════════════════════════════════════════"
    _color "1;33" "  ACTION REQUIRED: Add your SSH public key to GitHub"
    _color "1;33" "  ══════════════════════════════════════════════════════════════════"
    echo
    info "  Your public key (copy the entire line between the box):"
    echo
    echo "  ┌─────────────────────────────────────────────────────────────────┐"
    cat "${key}.pub" 2>/dev/null | sed 's/^/  │  /' || echo "  │  (key file not found: ${key}.pub)"
    echo "  └─────────────────────────────────────────────────────────────────┘"
    echo
    info "  Steps:"
    info "    1. Open  https://github.com/settings/keys  in your browser"
    info "    2. Click 'New SSH key'"
    info "    3. Paste the key above and save"
    echo
    info "  Come back here and press Enter once done."
    echo

    if [ "$EXPRESS" -eq 1 ]; then
      warn "  Express mode — skipping wait. Add the key manually then rerun if needed."
      return 0
    fi

    read -r -p "  ↩  Press Enter once you have added the key to GitHub... " _
    echo
  fi

  # ── Verify the connection ────────────────────────────────────────────
  local attempt=1
  while [ "$attempt" -le 3 ]; do
    info "  Testing GitHub SSH connection (attempt ${attempt}/3)..."
    if _test_gh_auth; then
      ok "  GitHub SSH authentication verified. You're good to go."
      return 0
    fi
    echo
    if [ "$attempt" -eq 1 ]; then
      # First failure is almost always GitHub's propagation delay (1-5 seconds
      # after a key is registered). Retry automatically instead of alarming the user.
      info "  Not connected yet — GitHub may need a moment to recognize the new key."
      info "  Retrying in 5 seconds..."
      sleep 5
    elif [ "$attempt" -lt 3 ]; then
      warn "  Still not connecting. Common causes:"
      warn "    • The key isn't added to your GitHub account yet"
      warn "    • You added a different key than the one at ${key}.pub"
      read -r -p "  ↩  Press Enter to try again, or Ctrl-C to abort... " _
      echo
    fi
    attempt=$((attempt + 1))
  done

  echo
  warn "  Could not verify GitHub SSH authentication after 3 attempts."
  warn "  The bootstrap will continue, but 'git push' will fail until the key works."
  warn "  To test manually:  ssh -T git@github.com"
  warn "  To add the key:    https://github.com/settings/keys"
}

# ---------------------------------------------------------------------
# SSH config block builders
# ---------------------------------------------------------------------

# SSH agent / keychain lines that vary by platform.
#
# `UseKeychain yes` is a macOS-only directive that integrates with the
# system Keychain. Linux's OpenSSH rejects it as an unknown option, so
# we only emit it on Darwin.
ssh_keychain_lines() {
  if [ "$(uname -s)" = "Darwin" ]; then
    cat <<'EOF'
  AddKeysToAgent yes
  UseKeychain yes
EOF
  else
    cat <<'EOF'
  AddKeysToAgent yes
EOF
  fi
}

build_github_block() {
  local github_host="$1" github_key="$2"
  cat <<EOF
Host $github_host
  User git
$(ssh_keychain_lines)
  IdentityFile $github_key
  IdentitiesOnly yes
EOF
}

build_server_block() {
  local ssh_host="$1" hostname="$2" user="$3" port="$4" server_key="$5"
  cat <<EOF
Host $ssh_host
  HostName $hostname
  User $user
  Port $port
  IdentityFile $server_key
  IdentitiesOnly yes
$(ssh_keychain_lines)
EOF
}


# ---------------------------------------------------------------------
# Pre-flight conflict detection
# ---------------------------------------------------------------------

# Returns 0 if any existing setup with this prefix is detected. Echoes a
# bullet list of what was found.
check_existing_setup() {
  local prefix="$1"
  local zshrc_marker="${ZSHRC_MARK_START//__PREFIX__/$prefix}"
  local ssh_marker="${SSH_MARK_START//__PREFIX__/$prefix}"
  local workflow_file="$HOME/.${prefix}-workflow.zsh"
  local found=0

  if [ -f "$ZSHRC" ] && grep -Fq "$zshrc_marker" "$ZSHRC"; then
    echo "  - ~/.zshrc already has a block for prefix '$prefix'"
    found=1
  fi
  if [ -f "$SSH_CONFIG" ] && grep -Fq "$ssh_marker" "$SSH_CONFIG"; then
    echo "  - ~/.ssh/config already has a block for prefix '$prefix'"
    found=1
  fi
  if [ -f "$workflow_file" ]; then
    echo "  - Workflow file already exists at $workflow_file"
    found=1
  fi

  return $((1 - found))
}


# ---------------------------------------------------------------------
# Server-side deploy key setup
# ---------------------------------------------------------------------

# Offer to SSH into the server and set up the deploy key interactively.
# Runs as part of the install flow's "next steps" section.
#
# Steps performed remotely (each safe to re-run):
#   1. Ensure ~/.ssh exists with mode 700.
#   2. Generate ~/.ssh/<prefix>_github_deploy WITHOUT a passphrase
#      (industry standard for read-only deploy keys; lets the deploy
#      run non-interactively). Skipped if the key already exists.
#   3. (Re)write a marker-bracketed `Host <SERVER_GITHUB_ALIAS>` block
#      in ~/.ssh/config pointing at the key. Strip-and-rewrite means
#      fixes from updated bootstrap runs propagate.
#   4. Tighten permissions on the key files and ssh config.
#   5. Try to add the deploy key to GitHub via `gh repo deploy-key add`
#      if the GitHub CLI is available; fall back to a manual paste
#      walkthrough otherwise.
#   6. Optionally test the alias with `ssh -T git@<alias>`.
#
# Reads from install-flow scope: $SSH_HOST, $PROJECT_PREFIX,
# $PROJECT_LABEL, $SERVER_PATH, $SERVER_GITHUB_ALIAS.
server_side_setup_offer() {
  section "Server-side deploy key"

  if ! confirm "  Set up the deploy key + SSH alias on $SSH_HOST now?"; then
    info "  Skipping — manual steps are shown below."
    return 0
  fi

  # Use tilde (~) rather than $HOME so the same path string works in
  # BOTH shell commands (where the remote shell expands ~) AND inside
  # ~/.ssh/config IdentityFile lines (where ssh expands ~ but does NOT
  # expand $HOME).
  local remote_key="~/.ssh/${PROJECT_PREFIX}_github_deploy"
  local marker_start="# >>> ${PROJECT_PREFIX} ${SERVER_GITHUB_ALIAS} alias >>>"
  local marker_end="# <<< ${PROJECT_PREFIX} ${SERVER_GITHUB_ALIAS} alias <<<"

  echo
  info "  → SSHing into $SSH_HOST..."
  info "    A new deploy key will be generated WITHOUT a passphrase."
  info "    This is the standard practice for read-only deploy keys —"
  info "    a passphrase would block non-interactive deploys, and the"
  info "    security gain is negligible for a key that can only clone"
  info "    a single repo and is owned by your server user (chmod 600)."
  echo

  # Pre-escape the deploy key comment for safe embedding in the remote
  # command string. PROJECT_LABEL is user-supplied and may contain single
  # quotes; _sq() wraps it so the remote shell always parses it correctly.
  local _deploy_comment_sq
  _deploy_comment_sq="$(_sq "${PROJECT_LABEL} deploy")"

  # Single SSH session that does everything. Each step is safe to
  # re-run; the Host alias block is always stripped-and-rewritten so
  # config fixes from an updated bootstrap propagate on subsequent runs.
  #
  # ssh-keygen uses -N "" (empty passphrase) so the deploy can run
  # non-interactively. If a key already exists we leave it alone — the
  # operator can decide whether to keep its passphrase or strip it.
  if ! ssh -t "$SSH_HOST" "
    set -e

    # 1. ~/.ssh exists with correct permissions
    mkdir -p \$HOME/.ssh
    chmod 700 \$HOME/.ssh

    # 2. Deploy key — only generate if missing
    if [ -f $remote_key ]; then
      echo 'Deploy key already exists at $remote_key — leaving it alone.'
      echo '(Delete it first if you want a fresh one. If the existing'
      echo 'key has a passphrase and deploys hang, run:'
      echo '  ssh-keygen -p -f $remote_key'
      echo 'and set an empty new passphrase.)'
    else
      ssh-keygen -t ed25519 -N '' -C ${_deploy_comment_sq} -f $remote_key
    fi
    chmod 600 $remote_key
    chmod 644 ${remote_key}.pub

    # 3. (Re)write Host alias block in ~/.ssh/config. Strip any prior
    # marker-bracketed block first so the latest content always wins.
    touch \$HOME/.ssh/config
    chmod 600 \$HOME/.ssh/config
    if grep -Fq '$marker_start' \$HOME/.ssh/config; then
      awk -v start='$marker_start' -v end='$marker_end' '
        BEGIN{skip=0}
        \$0==start{skip=1; next}
        skip && \$0==end{skip=0; next}
        !skip{print}
      ' \$HOME/.ssh/config > \$HOME/.ssh/config.new && mv \$HOME/.ssh/config.new \$HOME/.ssh/config
      chmod 600 \$HOME/.ssh/config
      echo 'Refreshed existing Host $SERVER_GITHUB_ALIAS block.'
    else
      echo 'Adding new Host $SERVER_GITHUB_ALIAS block.'
    fi
    printf '\n%s\nHost %s\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n%s\n' \
      '$marker_start' '$SERVER_GITHUB_ALIAS' '$remote_key' '$marker_end' \
      >> \$HOME/.ssh/config
  "; then
    err "  Server-side setup failed."
    return 1
  fi

  echo
  info "  → Reading the public key from the server..."
  local pubkey
  pubkey="$(ssh "$SSH_HOST" "cat $remote_key.pub" 2>/dev/null)" || {
    err "  Could not read the public key from the server."
    return 1
  }

  # ---- Try to auto-register the key via the GitHub CLI ----
  local KEY_ADDED=0
  if command -v gh >/dev/null 2>&1 && gh auth token >/dev/null 2>&1; then
    # Parse owner/repo out of the server remote URL.
    # Handles both git@github-alias:owner/repo.git and git@github.com:owner/repo.git
    local repo_path
    repo_path="${SERVER_REMOTE##*:}"
    repo_path="${repo_path%.git}"

    if [ -n "$repo_path" ] && printf '%s' "$repo_path" | grep -qE '^[^/]+/[^/]+$'; then
      info "  → GitHub CLI detected. Attempting to add the deploy key directly to '$repo_path'..."

      # Write the key to a temp file. Some `gh` versions are picky about
      # `-` (stdin) for repo deploy-key add; a real file path is the
      # most portable option.
      local tmp_key
      tmp_key="$(mktemp -t gdw-pubkey.XXXXXX)"
      printf '%s\n' "$pubkey" > "$tmp_key"

      if gh repo deploy-key add "$tmp_key" \
        --title "$PROJECT_LABEL deploy" \
        --repo "$repo_path" 2>&1 | sed 's/^/    /'; then
        ok "  ✓ Deploy key added to $repo_path (read-only)."
        KEY_ADDED=1
      else
        warn "  gh deploy-key add failed — falling back to manual paste below."
        warn "  (Common cause: your gh token doesn't have admin:repo_hook scope."
        warn "   Run 'gh auth refresh -s admin:repo_hook' to grant it.)"
      fi

      rm -f "$tmp_key"
    else
      warn "  Couldn't parse owner/repo from $SERVER_REMOTE — falling back to manual paste."
    fi
  fi

  if [ "$KEY_ADDED" -eq 0 ]; then
    echo
    echo "  ─── Copy everything between the lines ───"
    echo
    printf '%s\n' "$pubkey"
    echo
    echo "  ─── End of public key ───"
    echo

    cat <<EOF
  Now in your browser:

    1. Open your repo's GitHub deploy keys page:
       https://github.com/<you>/<your-repo>/settings/keys
    2. Click "Add deploy key"
    3. Paste the public key above into the Key field
    4. Title it: $PROJECT_LABEL deploy
    5. Leave "Allow write access" unchecked — this key should be read-only.
    6. Click "Add key"

  (Tip: install the GitHub CLI to skip the browser step next time:
    brew install gh && gh auth login --scopes admin:repo_hook)
EOF

    if command -v open >/dev/null 2>&1; then
      echo
      if confirm "     Open GitHub in your browser?"; then
        open "https://github.com/" 2>/dev/null || true
      fi
    fi
  fi

  # Test loop — let the user retry once or twice while they finish
  # adding the deploy key on GitHub (it usually takes a few seconds for
  # GitHub to recognize a freshly-added deploy key).
  # In express mode, run the test exactly once (confirm auto-yes would
  # otherwise cause an infinite retry loop on failure).
  local attempt=1
  local max_attempts=99   # effectively unlimited in interactive mode
  [ "$EXPRESS" -eq 1 ] && max_attempts=1

  while [ "$attempt" -le "$max_attempts" ]; do
    echo
    if ! confirm "     Done adding the key on GitHub? Test the alias from the server now?"; then
      info "  Skipping the test."
      break
    fi

    echo
    info "  → Testing 'ssh -T git@$SERVER_GITHUB_ALIAS' from the server (attempt $attempt)..."
    info "    Expected output: 'Hi <you>/<repo>! You've successfully authenticated...'"
    info "    (The non-zero exit is normal — GitHub doesn't allow shell access.)"
    echo

    # Capture both stdout and stderr so we can diagnose failures.
    local test_output
    test_output="$(ssh "$SSH_HOST" "ssh -T -o BatchMode=no -o StrictHostKeyChecking=accept-new git@$SERVER_GITHUB_ALIAS" 2>&1 || true)"
    echo "$test_output"

    if printf '%s' "$test_output" | grep -q "successfully authenticated"; then
      echo
      ok "  ✓ GitHub authenticated the deploy key. You're good to go."
      break
    fi

    echo
    warn "  GitHub did not authenticate the key. Common causes:"
    echo "    - The deploy key wasn't added to the right repo yet."
    echo "    - The pasted key got truncated (it should start with 'ssh-ed25519' and end with the comment)."
    echo "    - You added it as an account-level SSH key instead of a repo Deploy Key."
    echo "    - The IdentityFile path in the server's ~/.ssh/config is wrong"
    echo "      (look for 'no such identity' above)."
    echo
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$max_attempts" ] || ! confirm "     Try again?"; then
      break
    fi
  done

  echo
  ok "  Server-side setup complete."
  SERVER_SETUP_COMPLETE=1
  return 0
}


# ---------------------------------------------------------------------
# Install flow — settings collectors
# ---------------------------------------------------------------------

_detect_server_mode() {
  section "Mode"
  HAS_SERVER=1
  if [ "$CLI_NO_SERVER" -eq 1 ]; then
    HAS_SERVER=0
    info "  No-server mode  (--no-server)"
    return
  fi
  if [ "$EXPRESS" -eq 0 ]; then
    info "  Some projects deploy to a remote server when you push — WordPress"
    info "  themes/plugins, Django apps, static sites, etc. Others are just"
    info "  GitHub repos where you only want commit + push shortcuts."
    echo
  fi
  if ! confirm "Does this project deploy to a remote server?"; then
    HAS_SERVER=0
    info "  No-server mode: push commands will commit + push only, no deploy."
  fi
}

_collect_project_info() {
  section "Project info"
  local pwd_basename
  pwd_basename="$(basename "$(pwd)")"

  # Project name — flag > from-init path > current dir > prompt
  if [ -n "$CLI_LABEL" ]; then
    PROJECT_LABEL="$CLI_LABEL"
    ok "  Project name: $PROJECT_LABEL  (--label)"
  elif [ "$FROM_INIT" -eq 1 ] && [ -n "$FROM_INIT_PATH" ]; then
    PROJECT_LABEL="$(basename "$FROM_INIT_PATH")"
    info "  Project name: $PROJECT_LABEL  (from gdw-init)"
  elif [ -d "$(pwd)/.git" ] || [ "$pwd_basename" != "$(basename "$SCRIPT_DIR")" ]; then
    PROJECT_LABEL="$pwd_basename"
    info "  Project name: $PROJECT_LABEL  (from current directory)"
  else
    PROJECT_LABEL="$(ask 'Project name (human-readable)' 'My Project')"
  fi

  # Command prefix — flag > auto-derive always > prompt to confirm
  if [ -n "$CLI_PREFIX" ]; then
    PROJECT_PREFIX="$CLI_PREFIX"
    ok "  Command prefix: $PROJECT_PREFIX  (--prefix)"
  else
    # Auto-derive from project label regardless of express mode,
    # then let the user confirm or change it interactively.
    local _derived_prefix
    _derived_prefix="$(printf '%s' "$PROJECT_LABEL" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cd 'a-z0-9_' \
      | sed 's/^[0-9_]*//')"
    [ -z "$_derived_prefix" ] && _derived_prefix="project"

    if [ "$EXPRESS" -eq 1 ]; then
      PROJECT_PREFIX="$_derived_prefix"
      ok "  Command prefix: $PROJECT_PREFIX  (auto-derived)"
    else
      echo
      info "  The command prefix becomes the verb in your git shortcuts."
      info "  For example, prefix 'theme' gives you: themepush, themepull, themestatus, etc."
      PROJECT_PREFIX="$(ask 'Command prefix' "$_derived_prefix")"
    fi
  fi

  if ! printf '%s' "$PROJECT_PREFIX" | grep -Eq '^[a-z][a-z0-9_]*$'; then
    err "Prefix must start with a lowercase letter and contain only [a-z0-9_]."
    exit 1
  fi

  # Expand marker templates now that prefix is known
  ZSHRC_START="${ZSHRC_MARK_START//__PREFIX__/$PROJECT_PREFIX}"
  ZSHRC_END="${ZSHRC_MARK_END//__PREFIX__/$PROJECT_PREFIX}"
  SSH_START="${SSH_MARK_START//__PREFIX__/$PROJECT_PREFIX}"
  SSH_END="${SSH_MARK_END//__PREFIX__/$PROJECT_PREFIX}"

  # Detect and handle an existing install with this prefix.
  # Use mktemp so the temp file has an unpredictable name — avoids the
  # predictable /tmp/.bootstrap-existing.$$ naming that could be abused
  # on a shared system (TOCTOU / symlink race).
  local _existing_tmp
  _existing_tmp="$(mktemp -t gdw-existing.XXXXXX)"
  if check_existing_setup "$PROJECT_PREFIX" >"$_existing_tmp" 2>&1; then
    section "Existing setup detected"
    cat "$_existing_tmp"
    rm -f "$_existing_tmp"
    if [ "$EXPRESS" -eq 1 ]; then
      info "  Express mode — replacing existing setup automatically."
    else
      echo
      info "  You can:"
      plan "  (r) replace — back up existing files, strip old blocks, reinstall with new answers."
      plan "  (a) abort   — pick a different prefix or run with --uninstall first."
      echo
      local choice
      read -r -p "  Choose [r/a]: " choice
      case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
        r|replace) info "  Will replace existing setup." ;;
        *)         warn "Aborted."; exit 0 ;;
      esac
    fi
  else
    rm -f "$_existing_tmp"
  fi

  # Local repo path — flag/from-init > express pwd shortcut > prompt
  local repo_path_default
  if [ -d "$(pwd)/.git" ] && [ "$(pwd)" != "$SCRIPT_DIR" ]; then
    repo_path_default="$(pwd)"
  else
    repo_path_default="$HOME/Code/$PROJECT_PREFIX"
  fi
  local resolved_local_path="${CLI_LOCAL_PATH:-${FROM_INIT_PATH:-}}"
  if [ -n "$resolved_local_path" ]; then
    REPO_PATH="$resolved_local_path"
    ok "  Local project path: $REPO_PATH"
  elif [ "$EXPRESS" -eq 1 ] && [ "$repo_path_default" = "$(pwd)" ]; then
    REPO_PATH="$repo_path_default"
    ok "  Local project path: $REPO_PATH  (current directory)"
  else
    info "  The folder on this computer where the project lives (where you run git commands)."
    REPO_PATH="$(ask 'Local project path' "$repo_path_default")"
  fi

  # Zip output path — flag > config default > prompt
  local zip_default
  if [ -n "${GDW_DEFAULT_ZIP_DIR:-}" ]; then
    zip_default="${GDW_DEFAULT_ZIP_DIR%/}/${PROJECT_PREFIX}-review.zip"
  else
    zip_default="$HOME/Downloads/${PROJECT_PREFIX}-review.zip"
  fi
  if [ -n "$CLI_ZIP_PATH" ]; then
    ZIP_PATH="$CLI_ZIP_PATH"
    ok "  Zip output path: $ZIP_PATH  (--zip-path)"
  elif [ -n "${GDW_DEFAULT_ZIP_DIR:-}" ] || [ "$EXPRESS" -eq 1 ]; then
    ZIP_PATH="$zip_default"
    ok "  Zip output path: $ZIP_PATH"
  else
    info "  Used by '${PROJECT_PREFIX}zip' to package the project for review or sharing."
    ZIP_PATH="$(ask 'Zip output path' "$zip_default")"
  fi

  # Server path (server mode only)
  SERVER_PATH=""
  if [ "$HAS_SERVER" -eq 1 ]; then
    if [ -n "$CLI_SERVER_PATH" ]; then
      SERVER_PATH="$CLI_SERVER_PATH"
      ok "  Server path: $SERVER_PATH  (--server-path)"
    else
      info "  The directory on the server where this project lives."
      info "  Examples:  /var/www/html/wp-content/themes/mytheme"
      info "             /home/deploy/apps/myproject"
      SERVER_PATH="$(ask 'Project path on the server' "/var/www/${PROJECT_PREFIX}")"
    fi
  fi

  # Derive output paths used when writing files
  WORKFLOW_DEST="$HOME/.${PROJECT_PREFIX}-workflow.zsh"
  ZSHRC_BLOCK_BODY="source \"$WORKFLOW_DEST\""
}

_collect_github_settings() {
  section "GitHub SSH"
  info "  The bootstrap checks for an existing GitHub SSH key and reuses it."
  info "  If none is found, it will create one and register it with your account."

  GITHUB_KEY=""
  ADD_GITHUB_HOST=1

  # GitHub hostname — flag > config > express default > prompt
  if [ -n "$CLI_GITHUB_HOST" ]; then
    GITHUB_HOST="$CLI_GITHUB_HOST"
    ok "  GitHub SSH host: $GITHUB_HOST  (--github-host)"
  elif [ -n "${GDW_DEFAULT_GITHUB_HOST:-}" ]; then
    GITHUB_HOST="$GDW_DEFAULT_GITHUB_HOST"
    ok "  GitHub SSH host: $GITHUB_HOST  (from ~/.gdw-config)"
  elif [ "$EXPRESS" -eq 1 ]; then
    GITHUB_HOST="github.com"
    ok "  GitHub SSH host: github.com  (express default)"
  else
    # Offer a single "use defaults" shortcut before asking individually.
    local _gh_default_host="github.com"
    local _gh_default_key="${CLI_GITHUB_KEY:-$HOME/.ssh/id_ed25519}"
    echo
    info "  Default settings (recommended for most users):"
    plan "    GitHub host : $_gh_default_host"
    plan "    SSH key     : $_gh_default_key"
    echo
    if confirm "  Use these defaults?"; then
      GITHUB_HOST="$_gh_default_host"
      GITHUB_KEY="$_gh_default_key"
      ok "  Using default GitHub SSH settings."
      if ssh_config_has_host "$GITHUB_HOST"; then
        EXISTING_GITHUB_KEY="$(ssh_config_get_host_field "$GITHUB_HOST" 'IdentityFile' || true)"
        EXISTING_GITHUB_KEY="$(expand_ssh_path "$EXISTING_GITHUB_KEY")"
        if [ -n "$EXISTING_GITHUB_KEY" ]; then
          info "  Found existing SSH config for $GITHUB_HOST — reusing it."
          GITHUB_KEY="$EXISTING_GITHUB_KEY"
          ADD_GITHUB_HOST=0
        else
          # Host exists but no IdentityFile — SSH may auth via a different agent
          # key, creating a disconnect between what GDW thinks it's using and what
          # actually works. Create a dedicated alias with an explicit key instead
          # of touching or duplicating the user's existing block.
          # Use github-${PROJECT_PREFIX} so each project gets its own alias and
          # two projects hitting this path never overwrite each other.
          warn "  Your existing Host $GITHUB_HOST block has no IdentityFile."
          warn "  GDW will add a dedicated 'github-${PROJECT_PREFIX}' alias with"
          warn "  an explicit key so the workflow always uses a known key reliably."
          GITHUB_HOST="github-${PROJECT_PREFIX}"
          ADD_GITHUB_HOST=1
        fi
      else
        ADD_GITHUB_HOST=1
      fi
      return 0
    fi
    echo
    GITHUB_HOST="$(ask 'GitHub hostname' "$_gh_default_host")"
  fi

  if ssh_config_has_host "$GITHUB_HOST"; then
    EXISTING_GITHUB_KEY="$(ssh_config_get_host_field "$GITHUB_HOST" 'IdentityFile' || true)"
    EXISTING_GITHUB_KEY="$(expand_ssh_path "$EXISTING_GITHUB_KEY")"
    if [ -n "$EXISTING_GITHUB_KEY" ]; then
      # Existing block has a key — reuse it as-is.
      info "  Found existing SSH config for $GITHUB_HOST — reusing it."
      GITHUB_KEY="${CLI_GITHUB_KEY:-$EXISTING_GITHUB_KEY}"
      ok "  Using existing GitHub SSH key: $GITHUB_KEY"
      ADD_GITHUB_HOST=0
      info "  Skipping duplicate SSH config entry."
    else
      # Host exists but has no IdentityFile. If ADD_GITHUB_HOST=0 here, GDW
      # selects a key but SSH ignores it — auth passes via agent or fails for
      # the wrong reason and breaks the moment agent isn't running.
      # Fix: create a dedicated alias with an explicit IdentityFile instead
      # of patching or duplicating the user's existing block.
      warn "  Existing SSH config for $GITHUB_HOST has no IdentityFile."
      warn "  GDW will create a dedicated 'github-${PROJECT_PREFIX}' Host alias"
      warn "  with an explicit IdentityFile so the workflow uses a known key reliably."
      local gh_key_fallback="${CLI_GITHUB_KEY:-$HOME/.ssh/id_ed25519}"
      if [ -n "$CLI_GITHUB_KEY" ] || [ "$EXPRESS" -eq 1 ]; then
        GITHUB_KEY="$gh_key_fallback"
        ok "  GitHub key: $GITHUB_KEY"
      else
        GITHUB_KEY="$(ask 'Path for GitHub SSH key' "$gh_key_fallback")"
      fi
      GITHUB_HOST="github-${PROJECT_PREFIX}"
      ADD_GITHUB_HOST=1
      info "  Will add a dedicated Host github-${PROJECT_PREFIX} alias with IdentityFile set."
    fi
  else
    # Custom hostname chosen — no existing config for it.
    info "  No existing SSH config for $GITHUB_HOST — will create one."
    local gh_key_default="${CLI_GITHUB_KEY:-$HOME/.ssh/id_ed25519}"
    if [ -n "$CLI_GITHUB_KEY" ]; then
      GITHUB_KEY="$gh_key_default"
      ok "  GitHub SSH key: $GITHUB_KEY"
    else
      GITHUB_KEY="$(ask 'Path for GitHub SSH key' "$gh_key_default")"
    fi
    ADD_GITHUB_HOST=1
  fi
}

_collect_server_settings() {
  # Server SSH host alias
  section "Production server SSH"
  SSH_HOST="" SSH_HOSTNAME="" SSH_USER="" SSH_PORT=""
  SERVER_KEY="" SERVER_GITHUB_ALIAS="" SERVER_REMOTE=""
  ADD_SERVER_HOST=0

  local ssh_host_default="${PROJECT_PREFIX}-prod"
  if [ -n "$CLI_SSH_HOST" ]; then
    SSH_HOST="$CLI_SSH_HOST"
    ok "  SSH host alias: $SSH_HOST  (--ssh-host)"
  elif [ -n "${GDW_DEFAULT_SSH_HOST:-}" ]; then
    SSH_HOST="$GDW_DEFAULT_SSH_HOST"
    ok "  SSH host alias: $SSH_HOST  (from ~/.gdw-config)"
  elif [ "$EXPRESS" -eq 1 ]; then
    SSH_HOST="$ssh_host_default"
    ok "  SSH host alias: $SSH_HOST  (express default)"
  else
    info "  A short nickname for your server stored in ~/.ssh/config."
    info "  Once set, 'ssh $ssh_host_default' connects without typing the IP."
    SSH_HOST="$(ask 'SSH host alias' "$ssh_host_default")"
  fi

  if ssh_config_has_host "$SSH_HOST"; then
    # Read existing SSH config for this host
    info "  Found existing Host $SSH_HOST in $SSH_CONFIG."
    SSH_HOSTNAME="$(ssh_config_get_host_field "$SSH_HOST" 'HostName' || true)"
    SSH_USER="$(ssh_config_get_host_field "$SSH_HOST" 'User' || true)"
    SSH_PORT="$(ssh_config_get_host_field "$SSH_HOST" 'Port' || true)"
    SERVER_KEY="$(ssh_config_get_host_field "$SSH_HOST" 'IdentityFile' || true)"
    SERVER_KEY="$(expand_ssh_path "$SERVER_KEY")"
    [ -z "$SSH_HOSTNAME" ] && SSH_HOSTNAME="$SSH_HOST"
    [ -z "$SSH_USER" ]     && SSH_USER="$(whoami)"
    [ -z "$SSH_PORT" ]     && SSH_PORT="22"
    ok "  Using existing server SSH config:"
    plan "HostName: $SSH_HOSTNAME"
    plan "User:     $SSH_USER"
    plan "Port:     $SSH_PORT"
    if [ -n "$SERVER_KEY" ]; then
      SERVER_KEY="${CLI_SERVER_KEY:-$SERVER_KEY}"
      plan "Key:      $SERVER_KEY"
    else
      warn "  Host $SSH_HOST exists but has no IdentityFile."
      local srv_key_fallback="${CLI_SERVER_KEY:-$HOME/.ssh/${PROJECT_PREFIX}_server}"
      if [ -n "$CLI_SERVER_KEY" ] || [ "$EXPRESS" -eq 1 ]; then
        SERVER_KEY="$srv_key_fallback"; ok "  Server key: $SERVER_KEY"
      else
        SERVER_KEY="$(ask 'Server key path to use or create' "$srv_key_fallback")"
      fi
    fi
    ADD_SERVER_HOST=0
    info "  Skipping duplicate server SSH config entry."
  else
    # No existing config — collect what we need to build a new host block
    warn "  No Host $SSH_HOST block found in $SSH_CONFIG."
    info "  Tell us how to reach your server:"
    echo
    if [ -n "$CLI_SSH_HOSTNAME" ]; then
      SSH_HOSTNAME="$CLI_SSH_HOSTNAME"
      ok "  SSH hostname: $SSH_HOSTNAME  (--ssh-hostname)"
    else
      SSH_HOSTNAME="$(ask 'Server hostname or IP' 'example.com')"
    fi
    local srv_user_default="${CLI_SSH_USER:-$(whoami)}"
    local srv_port_default="${CLI_SSH_PORT:-22}"
    local srv_key_default="${CLI_SERVER_KEY:-$HOME/.ssh/${PROJECT_PREFIX}_server}"
    if [ -n "$CLI_SSH_USER" ] || [ -n "$CLI_SSH_PORT" ] || \
       [ -n "$CLI_SERVER_KEY" ] || [ "$EXPRESS" -eq 1 ]; then
      SSH_USER="$srv_user_default"; SSH_PORT="$srv_port_default"; SERVER_KEY="$srv_key_default"
      ok "  SSH user: $SSH_USER  port: $SSH_PORT  key: $SERVER_KEY"
    else
      SSH_USER="$(ask 'Server SSH user' "$srv_user_default")"
      SSH_PORT="$(ask 'Server SSH port' "$srv_port_default")"
      SERVER_KEY="$(ask 'Server key path to use or create' "$srv_key_default")"
    fi
    ADD_SERVER_HOST=1
  fi

  # Server-side GitHub SSH alias (for the per-repo deploy key)
  section "Server-side GitHub deploy key"
  info "  The server needs its own separate key to pull from GitHub."
  info "  It gets a unique SSH alias so each project has its own read-only access."
  echo
  local alias_default="github-${PROJECT_PREFIX}"
  [ -n "${GDW_DEFAULT_SERVER_GITHUB_ALIAS:-}" ] && \
    alias_default="${GDW_DEFAULT_SERVER_GITHUB_ALIAS//__PREFIX__/$PROJECT_PREFIX}"

  if [ -n "$CLI_SERVER_GITHUB_ALIAS" ]; then
    SERVER_GITHUB_ALIAS="$CLI_SERVER_GITHUB_ALIAS"
    ok "  Server-side GitHub alias: $SERVER_GITHUB_ALIAS  (--server-github-alias)"
  elif [ "$EXPRESS" -eq 1 ] || [ -n "${GDW_DEFAULT_SERVER_GITHUB_ALIAS:-}" ]; then
    SERVER_GITHUB_ALIAS="$alias_default"
    ok "  Server-side GitHub alias: $SERVER_GITHUB_ALIAS  (auto-derived)"
  else
    info "  Recommended naming: github-<prefix>  (e.g. github-theme)."
    info "  The bootstrap writes this alias to the SERVER's ~/.ssh/config for you."
    echo
    SERVER_GITHUB_ALIAS="$(ask 'Server-side GitHub host alias' "$alias_default")"
  fi

  # Server-side remote URL — derive from local origin when possible
  local local_origin=""
  [ -d "$REPO_PATH/.git" ] && \
    local_origin="$(cd "$REPO_PATH" && git config --get remote.origin.url 2>/dev/null || true)"

  local server_remote_default=""
  if [ -n "$local_origin" ]; then
    if printf '%s' "$local_origin" | grep -qE '^git@github\.com:'; then
      server_remote_default="$(printf '%s' "$local_origin" \
        | sed "s|@github\.com:|@${SERVER_GITHUB_ALIAS}:|")"
    elif printf '%s' "$local_origin" | grep -qE '^https://github\.com/'; then
      local repo_part="${local_origin#https://github.com/}"
      server_remote_default="git@${SERVER_GITHUB_ALIAS}:${repo_part}"
    fi
  fi
  [ -z "$server_remote_default" ] && \
    server_remote_default="git@${SERVER_GITHUB_ALIAS}:<you>/<repo>.git"

  local remote_is_derived=0
  [ -n "$local_origin" ] && \
  [ "$server_remote_default" != "git@${SERVER_GITHUB_ALIAS}:<you>/<repo>.git" ] && \
    remote_is_derived=1

  if [ -n "$CLI_SERVER_REMOTE" ]; then
    SERVER_REMOTE="$CLI_SERVER_REMOTE"
    ok "  Server-side remote: $SERVER_REMOTE  (--server-remote)"
  elif [ "$remote_is_derived" -eq 1 ] && [ "$EXPRESS" -eq 1 ]; then
    SERVER_REMOTE="$server_remote_default"
    ok "  Server-side remote: $SERVER_REMOTE  (auto-derived from local origin)"
  elif [ "$remote_is_derived" -eq 1 ]; then
    ok "  Detected server-side remote from local origin: $server_remote_default"
    local override_remote=""
    read -r -p "  Server-side GitHub remote URL [$server_remote_default]: " override_remote
    SERVER_REMOTE="${override_remote:-$server_remote_default}"
  else
    info "  Replace <you>/<repo> with your GitHub username and repo name."
    info "  Example: git@${SERVER_GITHUB_ALIAS}:joeseverino/mytheme.git"
    SERVER_REMOTE="$(ask 'Server-side GitHub remote URL' "$server_remote_default")"
  fi
}

# ---------------------------------------------------------------------
# Install flow — apply steps
# ---------------------------------------------------------------------

_show_install_plan() {
  section "Plan"
  plan "Workflow file:   $WORKFLOW_DEST"
  plan "Functions:       ${PROJECT_PREFIX}pull/push/branch/revert/status/zip/help"
  plan "Patch ~/.zshrc:  add 1 source block"

  local ssh_plan_parts=""
  [ "$ADD_GITHUB_HOST" -eq 1 ] && ssh_plan_parts="Host $GITHUB_HOST"
  if [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; then
    [ -n "$ssh_plan_parts" ] && ssh_plan_parts+=" + "
    ssh_plan_parts+="Host $SSH_HOST"
  fi
  if [ -n "$ssh_plan_parts" ]; then
    plan "Patch ~/.ssh/config: add $ssh_plan_parts"
  else
    plan "Patch ~/.ssh/config: no changes needed"
  fi

  plan "SSH keys:        GitHub: $GITHUB_KEY"
  [ "$HAS_SERVER" -eq 1 ] && plan "                 Server: $SERVER_KEY"
  plan "                 Existing keys are reused; missing keys are created."
  if [ "$HAS_SERVER" -eq 1 ]; then
    plan "Server-side:     deploy key + Host $SERVER_GITHUB_ALIAS in remote ~/.ssh/config"
    plan "Server remote:   $SERVER_REMOTE"
  fi
  echo
}

_generate_project_keys() {
  section "Checking SSH keys"
  info "  Existing keys are reused. Missing keys will be created now."
  generate_key "$GITHUB_KEY" "$(whoami)@$(hostname -s 2>/dev/null || echo local)" "github"
  if [ "$HAS_SERVER" -eq 1 ]; then
    generate_key "$SERVER_KEY" "$(whoami)@$(hostname -s 2>/dev/null || echo local) — ${PROJECT_LABEL}" "server"
  fi
}

_patch_ssh_config() {
  section "Patching ~/.ssh/config"
  if [ "$ADD_GITHUB_HOST" -eq 1 ] || { [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; }; then
    if [ -f "$SSH_CONFIG" ] && grep -Fq "$SSH_START" "$SSH_CONFIG"; then
      warn "  ~/.ssh/config already has a block for this project — replacing it."
      local backup
      backup="$(backup_file "$SSH_CONFIG")"
      [ -n "${backup:-}" ] && info "  Backup: $backup"
      strip_block "$SSH_CONFIG" "$SSH_START" "$SSH_END"
    fi
    local ssh_block_body=""
    if [ "$ADD_GITHUB_HOST" -eq 1 ]; then
      ssh_block_body="$(build_github_block "$GITHUB_HOST" "$GITHUB_KEY")"
    fi
    if [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; then
      [ -n "$ssh_block_body" ] && ssh_block_body+=$'\n\n' || true
      ssh_block_body+="$(build_server_block "$SSH_HOST" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT" "$SERVER_KEY")"
    fi
    append_block "$SSH_CONFIG" "$SSH_START" "$SSH_END" "$ssh_block_body"
    chmod 600 "$SSH_CONFIG"
    ok "  Updated: $SSH_CONFIG"
  else
    info "  Existing SSH config already has all needed host entries — no changes made."
  fi
}

# Copy the server SSH public key into the server's authorized_keys so all
# subsequent SSH connections in this bootstrap (and every future deploy) use
# key auth instead of a password. Runs once, after the local key and
# ~/.ssh/config block are in place. Skipped if key auth already works.
_install_server_key() {
  [ "$HAS_SERVER" -eq 0 ] && return 0
  [ -z "$SSH_HOST" ] && return 0

  section "Server key authentication"

  # Quick key-auth test. BatchMode=yes means "never prompt for a password" so
  # the test fails fast and cleanly when password auth would otherwise be needed.
  if ssh -o BatchMode=yes -o ConnectTimeout=8 \
         -o StrictHostKeyChecking=accept-new \
         "$SSH_HOST" "echo ok" >/dev/null 2>&1; then
    ok "  Key-based SSH to $SSH_HOST is already working."
    return 0
  fi

  info "  Key auth to $SSH_HOST isn't set up yet."
  info "  Running ssh-copy-id copies your public key to the server's authorized_keys."
  info "  You'll type your server password once — then all remaining SSH steps"
  info "  (deploy key setup, initial deploy, and every future push) will be password-free."
  echo

  local _do_copy=1
  if [ "$EXPRESS" -eq 0 ]; then
    if ! confirm "  Install server key now? (recommended)"; then
      _do_copy=0
      warn "  Skipped — you'll be prompted for your server password during setup steps."
    fi
  fi

  if [ "$_do_copy" -eq 1 ]; then
    if command -v ssh-copy-id >/dev/null 2>&1; then
      if ssh-copy-id -i "$SERVER_KEY" "$SSH_HOST"; then
        echo
        ok "  Server key installed. All remaining SSH steps will be password-free."
      else
        echo
        warn "  ssh-copy-id encountered an error — you may still be prompted for"
        warn "  your server password during the remaining setup steps."
      fi
    else
      # ssh-copy-id missing (unusual but possible in minimal environments).
      # Fall back to piping the public key via a plain SSH command.
      warn "  ssh-copy-id not found — falling back to manual key install..."
      if ssh "$SSH_HOST" "mkdir -p ~/.ssh && chmod 700 ~/.ssh && \
           cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
           < "${SERVER_KEY}.pub"; then
        echo
        ok "  Server key installed."
      else
        echo
        warn "  Could not install server key — you may be prompted for your password."
      fi
    fi
  fi
  echo
}


_switch_origin_to_ssh() {
  # If origin was set to HTTPS (e.g. by `gh repo create`), switch it to
  # SSH now that the key is verified. This ensures <prefix>push always
  # uses SSH and never needs a credential helper.
  [ -d "$REPO_PATH/.git" ] || return 0
  local cur_origin=""
  cur_origin="$(cd "$REPO_PATH" && git config --get remote.origin.url 2>/dev/null || true)"
  printf '%s' "$cur_origin" | grep -qE '^https://github\.com/' || return 0
  local ssh_origin
  ssh_origin="$(printf '%s' "$cur_origin" \
    | sed 's|https://github\.com/|git@github.com:|' \
    | sed 's|\.git$||').git"
  cd "$REPO_PATH" && git remote set-url origin "$ssh_origin"
  ok "  Switched origin remote to SSH: $ssh_origin"
}

_push_if_needed() {
  # If the local repo has commits that haven't landed on origin/main yet
  # (e.g. init-project created the GitHub repo but the SSH push failed),
  # offer to push now while the key is freshly verified.
  [ -d "$REPO_PATH/.git" ] || return 0
  local _has_local=""
  _has_local="$(cd "$REPO_PATH" && git rev-parse --verify HEAD 2>/dev/null || true)"
  [ -z "$_has_local" ] && return 0
  local _has_remote=""
  _has_remote="$(cd "$REPO_PATH" && git rev-parse --verify origin/main 2>/dev/null || true)"
  [ -n "$_has_remote" ] && return 0

  echo
  info "  Your GitHub repo exists but the initial commit hasn't been pushed yet."
  if confirm "  Push now?"; then
    if (cd "$REPO_PATH" && git push -u origin main); then
      ok "  Pushed to GitHub."
    else
      warn "  Push failed — retry after reloading your shell:"
      echo "       git push -u origin main"
    fi
  fi
}

_write_workflow_file() {
  section "Rendering workflow file"
  render_workflow "$PROJECT_PREFIX" "$PROJECT_LABEL" "$REPO_PATH" \
    "$SSH_HOST" "$SERVER_PATH" "$ZIP_PATH" "$SERVER_REMOTE" >"$WORKFLOW_DEST"
  chmod 644 "$WORKFLOW_DEST"
  ok "  Wrote: $WORKFLOW_DEST"
}

_patch_zshrc() {
  section "Patching ~/.zshrc"
  local backup
  backup="$(backup_file "$ZSHRC")"
  [ -n "${backup:-}" ] && info "  Backup: $backup"
  if [ -f "$ZSHRC" ] && grep -Fq "$ZSHRC_START" "$ZSHRC"; then
    warn "  ~/.zshrc already has a block for prefix '$PROJECT_PREFIX' — replacing it."
    strip_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END"
  fi
  append_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END" "$ZSHRC_BLOCK_BODY"
  ok "  Updated: $ZSHRC"
}

_install_gdw_alias() {
  local boot_alias_start="# >>> gdw-bootstrap alias >>>"
  local boot_alias_end="# <<< gdw-bootstrap alias <<<"
  [ -f "$ZSHRC" ] && grep -Fq "$boot_alias_start" "$ZSHRC" && return 0
  section "Convenience alias"
  info "  Adding 'gdw-bootstrap' alias so you can re-run from anywhere."
  if [ -f "$ZSHRC" ]; then
    local boot_backup="${ZSHRC}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$ZSHRC" "$boot_backup"
    info "  Backed up to: $boot_backup"
  fi
  {
    [ -f "$ZSHRC" ] && cat "$ZSHRC"
    printf '\n%s\nalias gdw-bootstrap=%s\n%s\n' \
      "$boot_alias_start" \
      "'bash \"$SCRIPT_DIR/bootstrap-deploy.sh\"'" \
      "$boot_alias_end"
  } > "${ZSHRC}.new"
  mv "${ZSHRC}.new" "$ZSHRC"
  ok "  Added: alias gdw-bootstrap='bash \"$SCRIPT_DIR/bootstrap-deploy.sh\"'"
}

_show_next_steps() {
  section "Done — next steps"
  echo
  echo "  1) Reload your shell:"
  echo "       exec zsh"
  echo "       ${PROJECT_PREFIX}help"
  echo

  # If the repo exists locally but nothing has landed on origin/main yet
  # (e.g. init-project created the GitHub repo but the SSH push failed),
  # remind the user to push before anything else.
  if [ -d "$REPO_PATH/.git" ]; then
    local _has_local_commits=""
    _has_local_commits="$(cd "$REPO_PATH" && git rev-parse --verify HEAD 2>/dev/null || true)"
    local _has_remote_main=""
    _has_remote_main="$(cd "$REPO_PATH" && git rev-parse --verify origin/main 2>/dev/null || true)"
    if [ -n "$_has_local_commits" ] && [ -z "$_has_remote_main" ]; then
      warn "  ⚠  Your local repo has commits that haven't been pushed yet."
      echo "     Run this first (after reloading your shell):"
      echo "       git -C \"$REPO_PATH\" push -u origin main"
      echo
    fi
  fi

  if [ "$HAS_SERVER" -eq 1 ]; then
    if [ "${SERVER_SETUP_COMPLETE:-0}" -eq 1 ]; then
      cat <<EOF
  2) Push your first deploy:
       ${PROJECT_PREFIX}push "first deploy"

EOF
    else
      cat <<EOF
  Manual server-side steps (run these if you skipped the interactive setup):

       ssh $SSH_HOST
       ssh-keygen -t ed25519 -N '' -C "$PROJECT_LABEL deploy" \\
         -f ~/.ssh/${PROJECT_PREFIX}_github_deploy
       cat ~/.ssh/${PROJECT_PREFIX}_github_deploy.pub
       # Paste THAT key at https://github.com/<you>/<repo>/settings/keys
       # Leave "Allow write access" unchecked.

  Server-side ~/.ssh/config entry (the bootstrap writes this automatically):

       Host github-${PROJECT_PREFIX}
         HostName github.com
         User git
         IdentityFile ~/.ssh/${PROJECT_PREFIX}_github_deploy
         IdentitiesOnly yes

  Test from the server:
       ssh -T git@github-${PROJECT_PREFIX}

  2) Then push your first deploy from your laptop:
       ${PROJECT_PREFIX}push "first deploy"

EOF
    fi
  else
    cat <<EOF
  2) Push your first commit:
       ${PROJECT_PREFIX}push "first commit"
       # No server configured — push commits to GitHub only.

  To add a server later, re-run bootstrap with the same prefix
  and choose "replace" — it adds the server piece without losing your config.

EOF
  fi
}

_offer_initial_deploy() {
  if [ "$HAS_SERVER" -eq 0 ] || [ "$DRY_RUN" -eq 1 ]; then return 0; fi
  echo
  info "  The workflow is ready. Want to run the initial server deploy now?"
  info "  This SSHes into $SSH_HOST and clones/pulls the repo at $SERVER_PATH."
  if confirm "  Run deploy-${PROJECT_PREFIX} now?"; then
    info "  → Running deploy-${PROJECT_PREFIX}..."
    if zsh -c "source '${WORKFLOW_DEST}' && deploy-${PROJECT_PREFIX}"; then
      ok "  Initial deploy complete."
    else
      warn "  Deploy encountered an error — check output above."
      warn "  After reloading your shell you can retry with:"
      echo "       exec zsh && deploy-${PROJECT_PREFIX}"
    fi
  fi
}

_remind_reload_shell() {
  echo
  _color "1;33" "  ⚠  RELOAD YOUR SHELL to activate the new commands:"
  echo "       exec zsh"
  echo "     (or open a new terminal tab)"
  echo
}

# ---------------------------------------------------------------------
# Install flow
# ---------------------------------------------------------------------

install_flow() {
  if [ ! -f "$TEMPLATE" ]; then
    err "Could not find workflow template at $TEMPLATE"
    err "Run this script from inside the cloned repo."
    exit 1
  fi

  echo
  info "git-deploy-workflow bootstrap"
  [ "$EXPRESS" -eq 1 ] && info "  (express mode — confirmations skipped; settings auto-derived)"
  [ "$FROM_INIT" -eq 1 ] && info "  (chained from gdw-init — local path already confirmed)"
  if [ "$EXPRESS" -eq 0 ]; then
    echo
    info "  This sets up an edit → commit → push → deploy workflow for a project."
    info "  Nothing is written until you confirm the plan below."
    info "  ~/.zshrc and ~/.ssh/config are backed up before any modification."
  fi

  # Collect all settings before writing anything
  _detect_server_mode
  _collect_project_info
  if [ "$HAS_SERVER" -eq 1 ]; then
    _collect_server_settings
  fi
  _collect_github_settings

  # Show the plan and get confirmation
  _show_install_plan
  [ "$DRY_RUN" -eq 1 ] && { info "DRY-RUN: stopping here. Re-run without --dry-run to apply."; return 0; }
  confirm "Proceed?" || { warn "Cancelled."; return 0; }

  # Apply — in order
  section "Installing shared library"
  install_shared_lib

  _generate_project_keys
  _patch_ssh_config
  _install_server_key
  verify_github_auth "$GITHUB_HOST" "$GITHUB_KEY"
  _switch_origin_to_ssh
  _push_if_needed
  _write_workflow_file
  _patch_zshrc
  _install_gdw_alias
  SERVER_SETUP_COMPLETE=0
  if [ "$HAS_SERVER" -eq 1 ]; then
    server_side_setup_offer
  fi

  # Wrap up — deploy first so "Done" really means done
  _offer_initial_deploy
  _show_next_steps

  ok "Bootstrap complete."
  _remind_reload_shell
}


# ---------------------------------------------------------------------
# Uninstall flow
# ---------------------------------------------------------------------

uninstall_flow() {
  if [ -n "$CLI_PREFIX" ]; then
    PROJECT_PREFIX="$CLI_PREFIX"
    ok "  Prefix: $PROJECT_PREFIX"
  else
    PROJECT_PREFIX="$(ask 'Prefix to remove (the one you used during bootstrap)' '')"
  fi
  if [ -z "$PROJECT_PREFIX" ]; then
    err "Prefix is required."
    exit 1
  fi

  ZSHRC_START="${ZSHRC_MARK_START//__PREFIX__/$PROJECT_PREFIX}"
  ZSHRC_END="${ZSHRC_MARK_END//__PREFIX__/$PROJECT_PREFIX}"
  SSH_START="${SSH_MARK_START//__PREFIX__/$PROJECT_PREFIX}"
  SSH_END="${SSH_MARK_END//__PREFIX__/$PROJECT_PREFIX}"
  WORKFLOW_DEST="$HOME/.${PROJECT_PREFIX}-workflow.zsh"

  section "Plan"
  plan "Strip block from ~/.zshrc       (markers: $ZSHRC_START / $ZSHRC_END)"
  plan "Strip block from ~/.ssh/config  (markers: $SSH_START / $SSH_END)"
  plan "Server-side: remove deploy key + SSH alias block"
  plan "Server-side: delete project folder"
  plan "GitHub: delete repo via gh CLI  (type repo name to confirm)"
  plan "Workflow file, SSH keys, shared lib left for manual cleanup"
  echo

  if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY-RUN: stopping here."
    return 0
  fi

  if ! confirm "Proceed?"; then
    warn "Cancelled."
    return 0
  fi

  local backup=""
  if [ -f "$ZSHRC" ]; then
    backup="$(backup_file "$ZSHRC")"
    [ -n "${backup:-}" ] && info "  Backup: $backup"
    strip_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END"
    ok "  Cleaned: $ZSHRC"
  fi

  if [ -f "$SSH_CONFIG" ]; then
    backup="$(backup_file "$SSH_CONFIG")"
    [ -n "${backup:-}" ] && info "  Backup: $backup"
    strip_block "$SSH_CONFIG" "$SSH_START" "$SSH_END"
    ok "  Cleaned: $SSH_CONFIG"
  fi

  echo
  ok "Local uninstall complete."

  # ----- Server-side cleanup ------------------------------------------
  # Read server details from the workflow file (if it still exists) so
  # we know which host to SSH into and what path to offer to delete.
  local uninstall_ssh_host="" uninstall_server_path="" uninstall_server_alias=""
  local uninstall_server_remote=""
  if [ -f "$WORKFLOW_DEST" ]; then
    # Strip KEY= prefix then leading/trailing quote. Handles both the
    # single-quoted format written by current bootstrap ('value') and the
    # double-quoted format written by older versions ("value").
    uninstall_ssh_host="$(grep -E '^\s*GDW_SSH_HOST=' "$WORKFLOW_DEST" \
      | sed -E "s/^[[:space:]]*GDW_SSH_HOST=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
    uninstall_server_path="$(grep -E '^\s*GDW_SERVER_PATH=' "$WORKFLOW_DEST" \
      | sed -E "s/^[[:space:]]*GDW_SERVER_PATH=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
    uninstall_server_remote="$(grep -E '^\s*GDW_SERVER_REMOTE=' "$WORKFLOW_DEST" \
      | sed -E "s/^[[:space:]]*GDW_SERVER_REMOTE=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
    # Extract the SSH alias from git@<alias>:owner/repo.git
    if [ -n "$uninstall_server_remote" ]; then
      uninstall_server_alias="$(printf '%s' "$uninstall_server_remote" \
        | sed -E 's|git@([^:]+):.*|\1|')"
    fi
    # Fall back to the conventional alias name.
    [ -z "$uninstall_server_alias" ] && uninstall_server_alias="github-${PROJECT_PREFIX}"
  fi

  if [ -n "$uninstall_ssh_host" ]; then
    section "Server-side cleanup  (${uninstall_ssh_host})"

    # --- Deploy key removal ---
    echo
    info "  The bootstrap created a read-only deploy key on $uninstall_ssh_host:"
    echo "      ~/.ssh/${PROJECT_PREFIX}_github_deploy  (and .pub)"
    echo "      Host ${uninstall_server_alias} block in server ~/.ssh/config"
    echo
    if confirm "  Remove the deploy key and SSH alias from $uninstall_ssh_host?"; then
      local remote_key="~/.ssh/${PROJECT_PREFIX}_github_deploy"
      local srv_marker_start="# >>> ${PROJECT_PREFIX} ${uninstall_server_alias} alias >>>"
      local srv_marker_end="# <<< ${PROJECT_PREFIX} ${uninstall_server_alias} alias <<<"
      if ssh "$uninstall_ssh_host" "
        set -e
        removed=0
        if [ -f $remote_key ]; then
          rm -f $remote_key ${remote_key}.pub
          echo 'Removed deploy key: $remote_key'
          removed=1
        else
          echo 'Deploy key not found (already removed?): $remote_key'
        fi
        if [ -f \$HOME/.ssh/config ] && grep -Fq '$srv_marker_start' \$HOME/.ssh/config; then
          awk -v s='$srv_marker_start' -v e='$srv_marker_end' '
            BEGIN{skip=0}
            \$0==s{skip=1;next}
            skip && \$0==e{skip=0;next}
            !skip{print}
          ' \$HOME/.ssh/config > \$HOME/.ssh/config.new \
            && mv \$HOME/.ssh/config.new \$HOME/.ssh/config
          chmod 600 \$HOME/.ssh/config
          echo 'Removed Host ${uninstall_server_alias} block from server ~/.ssh/config'
        else
          echo 'No Host ${uninstall_server_alias} block found in server ~/.ssh/config'
        fi
      "; then
        ok "  Server-side deploy key cleaned up."
      else
        warn "  SSH command failed — you may need to clean up manually on $uninstall_ssh_host."
      fi
    fi

    # --- Server project folder removal ---
    if [ -n "$uninstall_server_path" ]; then
      echo
      warn "  Server project folder: ${uninstall_ssh_host}:${uninstall_server_path}"
      if confirm "  Delete the project folder on the server?"; then
        warn "  ⚠  This permanently deletes: ${uninstall_ssh_host}:${uninstall_server_path}"
        if confirm "  Confirm — delete ${uninstall_server_path} on ${uninstall_ssh_host}?"; then
          # _sq() ensures paths with spaces or single quotes are safely quoted.
          if ssh "$uninstall_ssh_host" "rm -rf $(_sq "$uninstall_server_path")"; then
            ok "  Deleted: ${uninstall_server_path} on ${uninstall_ssh_host}"
          else
            warn "  Deletion failed — check permissions on $uninstall_ssh_host."
          fi
        else
          info "  Folder deletion skipped."
        fi
      fi
    fi
  fi

  # ----- GitHub repo deletion -----------------------------------------
  # Derive owner/repo slug from the workflow file so we can offer a
  # `gh repo delete` step.  Tries GDW_SERVER_REMOTE first (always present
  # after bootstrap); falls back to reading the local git origin.
  local uninstall_gh_repo=""
  if [ -f "$WORKFLOW_DEST" ]; then
    if [ -n "${uninstall_server_remote:-}" ]; then
      # git@github-alias:owner/repo.git  →  owner/repo
      uninstall_gh_repo="$(printf '%s' "$uninstall_server_remote" \
        | sed -E 's|git@[^:]+:(.+)|\1|' | sed -E 's|\.git$||')"
    fi
    # Fallback: read origin from the local clone
    if [ -z "$uninstall_gh_repo" ]; then
      local uninstall_local_path
      uninstall_local_path="$(grep -E '^\s*GDW_REPO=' "$WORKFLOW_DEST" \
        | sed -E "s/^[[:space:]]*GDW_REPO=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
      if [ -n "$uninstall_local_path" ] && [ -d "$uninstall_local_path" ]; then
        local local_origin_url
        local_origin_url="$(cd "$uninstall_local_path" \
          && git config --get remote.origin.url 2>/dev/null || true)"
        uninstall_gh_repo="$(printf '%s' "$local_origin_url" \
          | sed -E 's|git@github\.com:(.+)|\1|;s|https://github\.com/(.+)|\1|' \
          | sed -E 's|\.git$||')"
      fi
    fi
  fi

  if [ -n "$uninstall_gh_repo" ]; then
    echo
    section "GitHub repo cleanup"
    info "  Repository: github.com/${uninstall_gh_repo}"
    echo
    if confirm "  Delete the GitHub repo (gh repo delete)?"; then
      if confirm_repo "$uninstall_gh_repo"; then
        if command -v gh >/dev/null 2>&1; then
          if gh repo delete "$uninstall_gh_repo" --yes; then
            ok "  GitHub repo deleted: ${uninstall_gh_repo}"
          else
            warn "  gh repo delete failed — delete manually at:"
            echo "      https://github.com/${uninstall_gh_repo}/settings"
          fi
        else
          warn "  gh CLI not found — delete the repo manually at:"
          echo "      https://github.com/${uninstall_gh_repo}/settings"
        fi
      fi
    fi
  fi

  # ----- Local remaining cleanup hints --------------------------------
  section "Remaining local files  (manual)"
  info "Workflow file:"
  echo "    rm $WORKFLOW_DEST"

  # Count marker blocks still in ~/.zshrc. If zero remain, no project
  # is sourcing the lib anymore, so we can suggest removing it.
  local other_projects=0
  if [ -f "$ZSHRC" ]; then
    other_projects=$(grep -cE '^# >>> [a-z][a-z0-9_]* git deploy workflow >>>' "$ZSHRC" 2>/dev/null | tr -d ' \n' || echo 0)
  fi

  if [ -f "$LIB_DEST" ] && [ "$other_projects" -eq 0 ]; then
    info "Shared library (no other projects using it):"
    echo "    rm $LIB_DEST"
  elif [ -f "$LIB_DEST" ]; then
    info "Shared library left in place ($other_projects other project(s) still use it)."
  fi
}


# ---------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------

usage() {
  cat <<EOF
bootstrap-deploy.sh — install a customized git deploy workflow.

Usage:
  bash bootstrap-deploy.sh [options]

Modes:
  (default)              Interactive install.
  --dry-run              Preview every planned change; write nothing.
  --uninstall            Remove a previous bootstrap from ~/.zshrc, ~/.ssh/config,
                         the server (deploy key + folder), and GitHub repo.
  --express              Auto-yes all confirmation prompts; runs every step without pausing.
                         In uninstall mode, the only prompt is typing the GitHub repo name
                         to confirm deletion (GitHub-style safety gate).
                         Combine with flags below for a fully non-interactive install/uninstall.

Project flags:
  --prefix <p>           Command prefix  (e.g. theme → themepull / themepush)
  --label <l>            Human-readable project name
  --local-path <path>    Local clone path of the project (skips that prompt)
  --server-path <path>   Project path on the production server
  --zip-path <path>      Full path for zip review archives
  --no-server            No-server mode: commit + push only, no deploy step

GitHub flags:
  --github-host <host>   GitHub SSH hostname  (default: github.com)
  --github-key <path>    Path to the local GitHub SSH key

Server SSH flags:
  --ssh-host <alias>     SSH host alias in your local ~/.ssh/config
  --ssh-hostname <host>  Actual server hostname or IP (when adding a new SSH block)
  --ssh-user <user>      Server SSH user
  --ssh-port <port>      Server SSH port  (default: 22)
  --server-key <path>    Path to the server SSH key

Deploy key flags:
  --server-github-alias <alias>  Server-side GitHub SSH alias  (default: github-<prefix>)
  --server-remote <url>          Server-side GitHub remote URL

Other:
  --from-init <path>     Set by gdw-init automatically; skips the local-path prompt.
  --help, -h             Show this message.

Examples:
  # Fully non-interactive install:
  bash bootstrap-deploy.sh --express \\
    --prefix theme --server-path /var/www/html/wp-content/themes/mytheme \\
    --ssh-host myserver --server-remote git@github-theme:you/theme.git

  # Express install with SSH host already in ~/.ssh/config:
  bash bootstrap-deploy.sh --express --prefix theme --server-path /var/www/mytheme

  # Express uninstall (one prompt only — type the GitHub repo name to confirm):
  bash bootstrap-deploy.sh --uninstall --express --prefix theme
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)    DRY_RUN=1 ;;
    --uninstall)  UNINSTALL=1 ;;
    --express)    EXPRESS=1 ;;
    --from-init)          shift; FROM_INIT=1; FROM_INIT_PATH="${1:-}" ;;
    --prefix)             shift; CLI_PREFIX="${1:-}" ;;
    --label)              shift; CLI_LABEL="${1:-}" ;;
    --local-path)         shift; CLI_LOCAL_PATH="${1:-}" ;;
    --server-path)        shift; CLI_SERVER_PATH="${1:-}" ;;
    --zip-path)           shift; CLI_ZIP_PATH="${1:-}" ;;
    --no-server)          CLI_NO_SERVER=1 ;;
    --github-host)        shift; CLI_GITHUB_HOST="${1:-}" ;;
    --github-key)         shift; CLI_GITHUB_KEY="${1:-}" ;;
    --ssh-host)           shift; CLI_SSH_HOST="${1:-}" ;;
    --ssh-hostname)       shift; CLI_SSH_HOSTNAME="${1:-}" ;;
    --ssh-user)           shift; CLI_SSH_USER="${1:-}" ;;
    --ssh-port)           shift; CLI_SSH_PORT="${1:-}" ;;
    --server-key)         shift; CLI_SERVER_KEY="${1:-}" ;;
    --server-github-alias) shift; CLI_SERVER_GITHUB_ALIAS="${1:-}" ;;
    --server-remote)      shift; CLI_SERVER_REMOTE="${1:-}" ;;
    --help|-h)    usage; exit 0 ;;
    *)            err "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

if [ "$UNINSTALL" -eq 1 ]; then
  uninstall_flow
else
  install_flow
fi

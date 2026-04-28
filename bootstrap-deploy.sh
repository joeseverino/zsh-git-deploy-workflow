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
#   - Register your personal GitHub SSH key automatically (you paste
#     ~/.ssh/<prefix>_github.pub into github.com/settings/keys yourself).
#   - Require GitHub CLI; if gh is unavailable or lacks the right scope,
#     it falls back to a manual deploy-key paste flow.
#   - Replace existing user-managed SSH config blocks.
#
# Tested on macOS (bash 3.2 / 5.x) and Linux (bash 4.x+). No external
# dependencies; uses only sed, awk, ssh-keygen, ssh, and standard tools.

set -euo pipefail

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
  awk -v prefix="$prefix" -v label="$label" \
      -v repo="$repo" -v host="$ssh_host" \
      -v server="$server_path" -v zip="$zip_path" \
      -v server_remote="$server_remote" '
    /^  GDW_PREFIX=/        { print "  GDW_PREFIX=\""prefix"\""; next }
    /^  GDW_LABEL=/         { print "  GDW_LABEL=\""label"\""; next }
    /^  GDW_REPO=/          { print "  GDW_REPO=\""repo"\""; next }
    /^  GDW_SSH_HOST=/      { print "  GDW_SSH_HOST=\""host"\""; next }
    /^  GDW_SERVER_PATH=/   { print "  GDW_SERVER_PATH='\''"server"'\''"; next }
    /^  GDW_ZIP_OUTPUT=/    { print "  GDW_ZIP_OUTPUT=\""zip"\""; next }
    /^  GDW_SERVER_REMOTE=/ { print "  GDW_SERVER_REMOTE=\""server_remote"\""; next }
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

# generate_key <key_path> <comment>
generate_key() {
  local key_path="$1" comment="$2"

  if [ -z "$key_path" ]; then
    warn "  Empty key path — skipped."
    return 0
  fi

  if [ -f "$key_path" ]; then
    warn "  Key already exists at $key_path — skipped."
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    plan "Would create SSH key: $key_path  (comment: $comment)"
    return 0
  fi

  mkdir -p "$(dirname "$key_path")"
  chmod 700 "$(dirname "$key_path")"
  ssh-keygen -t ed25519 -f "$key_path" -C "$comment"
  ok "  Created: $key_path"
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
  echo
  cat <<EOF
  3) Server-side deploy key + SSH alias
EOF
  echo

  if ! confirm "     Set up the server-side deploy key + SSH alias on $SSH_HOST now?"; then
    info "  Skipping — see manual commands below."
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
      ssh-keygen -t ed25519 -N '' -C '$PROJECT_LABEL deploy' -f $remote_key
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
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
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
  return 0
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
  if [ "$EXPRESS" -eq 1 ]; then
    info "  (express mode — only essential prompts; everything else is auto-derived)"
  fi
  if [ "$FROM_INIT" -eq 1 ]; then
    info "  (chained from gdw-init — local clone path already confirmed)"
  fi
  if [ "$EXPRESS" -eq 0 ]; then
    cat <<'EOF'
This will set up an edit/commit/push workflow for a project, with an
optional deploy step for projects that live on a remote server.

Nothing is written until you confirm the plan. ~/.zshrc and ~/.ssh/config
are backed up before modification.
EOF
  fi

  # ----- Mode: with-server vs. no-server ----------------------
  section "Mode"

  HAS_SERVER=1
  if [ "$CLI_NO_SERVER" -eq 1 ]; then
    HAS_SERVER=0
    info "  No-server mode  (--no-server)"
  else
    if [ "$EXPRESS" -eq 0 ]; then
      cat <<'EOF'
Some projects deploy to a remote server when you push, such as WordPress
plugins, WordPress themes, Django apps, and static sites. Others are just
GitHub repos where you only want the local git aliases.
EOF
      echo
    fi
    if ! confirm "Does this project deploy to a remote server?"; then
      HAS_SERVER=0
      info "  No-server mode: push commands will commit + push only, no deploy."
    fi
  fi

  # ----- Project identity -------------------------------------
  # Project name is auto-derived from the current directory if we're
  # running inside one (or from the --from-init path). Otherwise prompt.
  section "Project info"
  local pwd_basename
  pwd_basename="$(basename "$(pwd)")"

  if [ -n "$CLI_LABEL" ]; then
    PROJECT_LABEL="$CLI_LABEL"
    ok "  Project name: $PROJECT_LABEL  (--label)"
  elif [ "$FROM_INIT" -eq 1 ] && [ -n "$FROM_INIT_PATH" ]; then
    PROJECT_LABEL="$(basename "$FROM_INIT_PATH")"
    info "  Project name: $PROJECT_LABEL    (from gdw-init)"
  elif [ -d "$(pwd)/.git" ] || [ "$pwd_basename" != "$(basename "$SCRIPT_DIR")" ]; then
    PROJECT_LABEL="$pwd_basename"
    info "  Project name: $PROJECT_LABEL    (from current directory)"
  else
    # Running from inside the workflow repo itself — ask.
    PROJECT_LABEL="$(ask 'Project name (human-readable)' 'My Project')"
  fi

  if [ -n "$CLI_PREFIX" ]; then
    PROJECT_PREFIX="$CLI_PREFIX"
    ok "  Command prefix: $PROJECT_PREFIX  (--prefix)"
  elif [ "$EXPRESS" -eq 1 ]; then
    # Auto-derive from project label: lowercase, strip anything not [a-z0-9_],
    # then strip any leading digits/underscores so it starts with a letter.
    PROJECT_PREFIX="$(printf '%s' "$PROJECT_LABEL" \
      | tr '[:upper:]' '[:lower:]' \
      | tr -cd 'a-z0-9_' \
      | sed 's/^[0-9_]*//')"
    [ -z "$PROJECT_PREFIX" ] && PROJECT_PREFIX="project"
    ok "  Command prefix: $PROJECT_PREFIX  (auto-derived from project name)"
  else
    PROJECT_PREFIX="$(ask 'Command prefix (lowercase; e.g. theme gives themepull/themepush)' 'mp')"
  fi

  if ! printf '%s' "$PROJECT_PREFIX" | grep -Eq '^[a-z][a-z0-9_]*$'; then
    err "Prefix must start with a lowercase letter and contain only [a-z0-9_]."
    exit 1
  fi

  ZSHRC_START="${ZSHRC_MARK_START//__PREFIX__/$PROJECT_PREFIX}"
  ZSHRC_END="${ZSHRC_MARK_END//__PREFIX__/$PROJECT_PREFIX}"
  SSH_START="${SSH_MARK_START//__PREFIX__/$PROJECT_PREFIX}"
  SSH_END="${SSH_MARK_END//__PREFIX__/$PROJECT_PREFIX}"

  # ----- Pre-flight: existing setup with this prefix? ---------
  if check_existing_setup "$PROJECT_PREFIX" >/tmp/.bootstrap-existing.$$ 2>&1; then
    section "Existing setup detected"
    cat /tmp/.bootstrap-existing.$$
    rm -f /tmp/.bootstrap-existing.$$
    if [ "$EXPRESS" -eq 1 ]; then
      info "  Express mode — replacing existing setup automatically."
    else
      echo
      cat <<EOF
You can:
  (r) replace — back up existing files, strip old marker blocks,
      and reinstall with the new answers.
  (a) abort  — pick a different prefix or run with --uninstall first.
EOF
      echo
      local choice
      read -r -p "  Choose [r/a]: " choice
      case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]')" in
        r|replace) info "  Will replace existing setup." ;;
        *)         warn "Aborted."; exit 0 ;;
      esac
    fi
  else
    rm -f /tmp/.bootstrap-existing.$$
  fi

  # ----- Project paths ----------------------------------------
  # If we're running inside what looks like a project repo (has .git
  # and isn't this very tool), default REPO_PATH to $PWD. Otherwise
  # fall back to the conventional ~/Code/<prefix>.
  local repo_path_default
  if [ -d "$(pwd)/.git" ] && [ "$(pwd)" != "$SCRIPT_DIR" ]; then
    repo_path_default="$(pwd)"
  else
    repo_path_default="$HOME/Code/$PROJECT_PREFIX"
  fi

  # --local-path flag and --from-init both set the repo path without prompting.
  local resolved_local_path="${CLI_LOCAL_PATH:-${FROM_INIT_PATH:-}}"
  if [ -n "$resolved_local_path" ]; then
    REPO_PATH="$resolved_local_path"
    ok "  Local clone path: $REPO_PATH"
  elif [ "$EXPRESS" -eq 1 ] && [ "$repo_path_default" = "$(pwd)" ]; then
    REPO_PATH="$repo_path_default"
    ok "  Local clone path: $REPO_PATH  (current directory)"
  else
    REPO_PATH="$(ask 'Local clone path of the project' "$repo_path_default")"
  fi

  # Zip output path — CLI flag > config default > prompt.
  local zip_default
  if [ -n "${GDW_DEFAULT_ZIP_DIR:-}" ]; then
    zip_default="${GDW_DEFAULT_ZIP_DIR%/}/${PROJECT_PREFIX}-review.zip"
  else
    zip_default="$HOME/Downloads/${PROJECT_PREFIX}-review.zip"
  fi
  if [ -n "$CLI_ZIP_PATH" ]; then
    ZIP_PATH="$CLI_ZIP_PATH"
    ok "  Zip output path:  $ZIP_PATH  (--zip-path)"
  elif [ -n "${GDW_DEFAULT_ZIP_DIR:-}" ] || [ "$EXPRESS" -eq 1 ]; then
    ZIP_PATH="$zip_default"
    ok "  Zip output path:  $ZIP_PATH"
  else
    ZIP_PATH="$(ask 'Local zip output path (for review/distribution)' "$zip_default")"
  fi

  # Server-mode-only fields. In no-server mode these stay empty so the
  # rendered workflow knows there is nothing to deploy.
  SERVER_PATH=""
  SSH_HOST=""
  SSH_HOSTNAME=""
  SSH_USER=""
  SSH_PORT=""
  SERVER_KEY=""
  SERVER_GITHUB_ALIAS=""
  SERVER_REMOTE=""
  ADD_SERVER_HOST=0

  if [ "$HAS_SERVER" -eq 1 ]; then
    if [ -n "$CLI_SERVER_PATH" ]; then
      SERVER_PATH="$CLI_SERVER_PATH"
      ok "  Server path: $SERVER_PATH  (--server-path)"
    else
      SERVER_PATH_DEFAULT='$HOME/path/to/'"$PROJECT_PREFIX"
      SERVER_PATH="$(ask 'Project path on the server' "$SERVER_PATH_DEFAULT")"
    fi
  fi

  # ----- GitHub SSH -------------------------------------------
  section "GitHub SSH"
  if [ -n "$CLI_GITHUB_HOST" ]; then
    GITHUB_HOST="$CLI_GITHUB_HOST"
    ok "  GitHub SSH host: $GITHUB_HOST  (--github-host)"
  elif [ -n "${GDW_DEFAULT_GITHUB_HOST:-}" ]; then
    GITHUB_HOST="$GDW_DEFAULT_GITHUB_HOST"
    ok "  Using GitHub SSH host from ~/.gdw-config: $GITHUB_HOST"
  elif [ "$EXPRESS" -eq 1 ]; then
    GITHUB_HOST="github.com"
    ok "  GitHub SSH host: github.com  (express default)"
  else
    GITHUB_HOST="$(ask 'GitHub SSH host' 'github.com')"
  fi
  GITHUB_KEY=""
  ADD_GITHUB_HOST=1

  if ssh_config_has_host "$GITHUB_HOST"; then
    info "  Found existing Host $GITHUB_HOST in $SSH_CONFIG."
    EXISTING_GITHUB_KEY="$(ssh_config_get_host_field "$GITHUB_HOST" 'IdentityFile' || true)"
    EXISTING_GITHUB_KEY="$(expand_ssh_path "$EXISTING_GITHUB_KEY")"

    if [ -n "$EXISTING_GITHUB_KEY" ]; then
      GITHUB_KEY="${CLI_GITHUB_KEY:-$EXISTING_GITHUB_KEY}"
      ok "  Using existing GitHub key: $GITHUB_KEY"
    else
      warn "  Host $GITHUB_HOST exists, but no IdentityFile was found."
      local gh_key_fallback="${CLI_GITHUB_KEY:-$HOME/.ssh/id_ed25519}"
      if [ -n "$CLI_GITHUB_KEY" ] || [ "$EXPRESS" -eq 1 ]; then
        GITHUB_KEY="$gh_key_fallback"
        ok "  GitHub key: $GITHUB_KEY"
      else
        GITHUB_KEY="$(ask 'GitHub key path to use or create' "$gh_key_fallback")"
      fi
    fi

    ADD_GITHUB_HOST=0
    info "  Skipping duplicate GitHub SSH config setup."
  else
    warn "  No Host $GITHUB_HOST block found in $SSH_CONFIG."
    local gh_key_default="${CLI_GITHUB_KEY:-$HOME/.ssh/${PROJECT_PREFIX}_github}"
    if [ -n "$CLI_GITHUB_KEY" ] || [ "$EXPRESS" -eq 1 ]; then
      GITHUB_KEY="$gh_key_default"
      ok "  GitHub key: $GITHUB_KEY"
    else
      GITHUB_KEY="$(ask 'GitHub key path to use or create' "$gh_key_default")"
    fi
    ADD_GITHUB_HOST=1
  fi

  # ----- Production server SSH --------------------------------
  if [ "$HAS_SERVER" -eq 1 ]; then
    section "Production server SSH"
    local ssh_host_default="${PROJECT_PREFIX}-prod"
    if [ -n "$CLI_SSH_HOST" ]; then
      SSH_HOST="$CLI_SSH_HOST"
      ok "  SSH host alias: $SSH_HOST  (--ssh-host)"
    elif [ -n "${GDW_DEFAULT_SSH_HOST:-}" ]; then
      SSH_HOST="$GDW_DEFAULT_SSH_HOST"
      ok "  Using SSH host from ~/.gdw-config: $SSH_HOST"
    elif [ "$EXPRESS" -eq 1 ]; then
      SSH_HOST="$ssh_host_default"
      ok "  SSH host alias: $SSH_HOST  (express default)"
    else
      SSH_HOST="$(ask 'SSH host alias to use locally' "$ssh_host_default")"
    fi

    if ssh_config_has_host "$SSH_HOST"; then
      info "  Found existing Host $SSH_HOST in $SSH_CONFIG."

      SSH_HOSTNAME="$(ssh_config_get_host_field "$SSH_HOST" 'HostName' || true)"
      SSH_USER="$(ssh_config_get_host_field "$SSH_HOST" 'User' || true)"
      SSH_PORT="$(ssh_config_get_host_field "$SSH_HOST" 'Port' || true)"
      SERVER_KEY="$(ssh_config_get_host_field "$SSH_HOST" 'IdentityFile' || true)"
      SERVER_KEY="$(expand_ssh_path "$SERVER_KEY")"

      [ -z "$SSH_HOSTNAME" ] && SSH_HOSTNAME="$SSH_HOST"
      [ -z "$SSH_USER" ] && SSH_USER="$(whoami)"
      [ -z "$SSH_PORT" ] && SSH_PORT="22"

      ok "  Using existing server SSH config:"
      plan "HostName: $SSH_HOSTNAME"
      plan "User:     $SSH_USER"
      plan "Port:     $SSH_PORT"

      if [ -n "$SERVER_KEY" ]; then
        SERVER_KEY="${CLI_SERVER_KEY:-$SERVER_KEY}"
        plan "Key:      $SERVER_KEY"
      else
        warn "  Host $SSH_HOST exists, but no IdentityFile was found."
        local srv_key_fallback="${CLI_SERVER_KEY:-$HOME/.ssh/${PROJECT_PREFIX}_server}"
        if [ -n "$CLI_SERVER_KEY" ] || [ "$EXPRESS" -eq 1 ]; then
          SERVER_KEY="$srv_key_fallback"
          ok "  Server key: $SERVER_KEY"
        else
          SERVER_KEY="$(ask 'Server key path to use or create' "$srv_key_fallback")"
        fi
      fi

      ADD_SERVER_HOST=0
      info "  Skipping duplicate server SSH config setup."
    else
      warn "  No Host $SSH_HOST block found in $SSH_CONFIG."
      # Hostname is the one field that can't be safely guessed; ask unless
      # --ssh-hostname was provided.
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
        SSH_USER="$srv_user_default"
        SSH_PORT="$srv_port_default"
        SERVER_KEY="$srv_key_default"
        ok "  SSH user: $SSH_USER  port: $SSH_PORT  key: $SERVER_KEY"
      else
        SSH_USER="$(ask 'Server SSH user' "$srv_user_default")"
        SSH_PORT="$(ask 'Server SSH port' "$srv_port_default")"
        SERVER_KEY="$(ask 'Server key path to use or create' "$srv_key_default")"
      fi
      ADD_SERVER_HOST=1
    fi

    # ----- Server-side GitHub alias (per-repo deploy key) ------------
    section "Server-side GitHub deploy key"

    # Compute the alias. GDW_DEFAULT_SERVER_GITHUB_ALIAS supports a
    # __PREFIX__ placeholder that is substituted at runtime, e.g.
    #   GDW_DEFAULT_SERVER_GITHUB_ALIAS="github-__PREFIX__"
    local alias_default="github-${PROJECT_PREFIX}"
    if [ -n "${GDW_DEFAULT_SERVER_GITHUB_ALIAS:-}" ]; then
      alias_default="${GDW_DEFAULT_SERVER_GITHUB_ALIAS//__PREFIX__/$PROJECT_PREFIX}"
    fi

    if [ -n "$CLI_SERVER_GITHUB_ALIAS" ]; then
      SERVER_GITHUB_ALIAS="$CLI_SERVER_GITHUB_ALIAS"
      ok "  Server-side GitHub alias: $SERVER_GITHUB_ALIAS  (--server-github-alias)"
    elif [ "$EXPRESS" -eq 1 ] || [ -n "${GDW_DEFAULT_SERVER_GITHUB_ALIAS:-}" ]; then
      SERVER_GITHUB_ALIAS="$alias_default"
      ok "  Server-side GitHub alias: $SERVER_GITHUB_ALIAS  (auto-derived)"
    else
      cat <<'EOF'
The server fetches the repo through a unique SSH alias so each repo
can have its own read-only deploy key. The alias lives in the SERVER's
~/.ssh/config (the bootstrap will write it there for you), so it does
NOT need to exist on this Mac and your local origin URL is unchanged.

Recommended naming: github-<prefix>  (e.g. github-theme).
EOF
      echo
      SERVER_GITHUB_ALIAS="$(ask 'Server-side GitHub host alias' "$alias_default")"
    fi

    # Try to derive the server remote URL from the local repo's origin.
    # Handle both SSH and HTTPS origin URLs:
    #   git@github.com:user/repo.git       -> git@<alias>:user/repo.git
    #   https://github.com/user/repo.git   -> git@<alias>:user/repo.git
    local local_origin=""
    if [ -d "$REPO_PATH/.git" ]; then
      local_origin="$(cd "$REPO_PATH" && git config --get remote.origin.url 2>/dev/null || true)"
    fi
    local server_remote_default=""
    if [ -n "$local_origin" ]; then
      if printf '%s' "$local_origin" | grep -qE '^git@github\.com:'; then
        server_remote_default="$(printf '%s' "$local_origin" | sed "s|@github\.com:|@${SERVER_GITHUB_ALIAS}:|")"
      elif printf '%s' "$local_origin" | grep -qE '^https://github\.com/'; then
        local repo_part="${local_origin#https://github.com/}"
        server_remote_default="git@${SERVER_GITHUB_ALIAS}:${repo_part}"
      fi
    fi
    if [ -z "$server_remote_default" ]; then
      server_remote_default="git@${SERVER_GITHUB_ALIAS}:<you>/<repo>.git"
    fi

    # Auto-use the derived URL when it looks complete (i.e. came from the
    # local repo's origin rather than being the placeholder fallback).
    local remote_is_derived=0
    if [ -n "$local_origin" ] && \
       [ "$server_remote_default" != "git@${SERVER_GITHUB_ALIAS}:<you>/<repo>.git" ]; then
      remote_is_derived=1
    fi

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
      SERVER_REMOTE="$(ask 'Server-side GitHub remote URL (uses the alias above)' "$server_remote_default")"
    fi
  fi

  WORKFLOW_DEST="$HOME/.${PROJECT_PREFIX}-workflow.zsh"
  ZSHRC_BLOCK_BODY="source \"$WORKFLOW_DEST\""

  # ----- Plan -------------------------------------------------
  section "Plan"
  plan "Workflow file:   $WORKFLOW_DEST"
  plan "Functions:       ${PROJECT_PREFIX}pull, ${PROJECT_PREFIX}push, ${PROJECT_PREFIX}branch, ${PROJECT_PREFIX}revert, ${PROJECT_PREFIX}status, ${PROJECT_PREFIX}zip, ${PROJECT_PREFIX}help"
  plan "Patch ~/.zshrc:  add 1 source block"

  ssh_plan_parts=""
  if [ "$ADD_GITHUB_HOST" -eq 1 ]; then
    ssh_plan_parts="Host $GITHUB_HOST"
  fi
  if [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; then
    if [ -n "$ssh_plan_parts" ]; then
      ssh_plan_parts="$ssh_plan_parts + Host $SSH_HOST"
    else
      ssh_plan_parts="Host $SSH_HOST"
    fi
  fi

  if [ -n "$ssh_plan_parts" ]; then
    plan "Patch ~/.ssh/config: add $ssh_plan_parts"
  else
    plan "Patch ~/.ssh/config: no changes"
  fi

  plan "SSH keys:        GitHub: $GITHUB_KEY"
  if [ "$HAS_SERVER" -eq 1 ]; then
    plan "                 Server: $SERVER_KEY"
  fi
  plan "                 Existing keys are reused; missing keys are created."

  if [ "$HAS_SERVER" -eq 1 ]; then
    plan "Server-side:     deploy key + Host $SERVER_GITHUB_ALIAS in remote ~/.ssh/config"
    plan "                 (set up interactively after the local install)"
    plan "Server remote:   $SERVER_REMOTE"
  fi
  echo

  if [ "$DRY_RUN" -eq 1 ]; then
    info "DRY-RUN: stopping here. Re-run without --dry-run to apply."
    return 0
  fi

  if [ "$EXPRESS" -eq 0 ] && ! confirm "Proceed?"; then
    warn "Cancelled."
    return 0
  fi

  # ----- Apply ------------------------------------------------
  section "Installing shared library"
  install_shared_lib

  section "Checking SSH keys"
  info "  Existing local SSH keys are reused. Missing local keys will be created interactively."
  generate_key "$GITHUB_KEY" "${PROJECT_LABEL} — github"
  if [ "$HAS_SERVER" -eq 1 ]; then
    generate_key "$SERVER_KEY" "${PROJECT_LABEL} — server ssh"
  fi

  # ssh-config patching: only run if there is actually something to add.
  section "Patching ~/.ssh/config"
  if [ "$ADD_GITHUB_HOST" -eq 1 ] || { [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; }; then
    if [ -f "$SSH_CONFIG" ] && grep -Fq "$SSH_START" "$SSH_CONFIG"; then
      warn "  ~/.ssh/config already has a block for this project — replacing it."
      backup="$(backup_file "$SSH_CONFIG")"
      [ -n "${backup:-}" ] && info "  Backup: $backup"
      strip_block "$SSH_CONFIG" "$SSH_START" "$SSH_END"
    fi

    ssh_block_body=""

    if [ "$ADD_GITHUB_HOST" -eq 1 ]; then
      ssh_block_body="$(build_github_block "$GITHUB_HOST" "$GITHUB_KEY")"
    fi

    if [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; then
      [ -n "$ssh_block_body" ] && ssh_block_body+=$'\n\n'
      ssh_block_body+="$(build_server_block "$SSH_HOST" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT" "$SERVER_KEY")"
    fi

    append_block "$SSH_CONFIG" "$SSH_START" "$SSH_END" "$ssh_block_body"
    chmod 600 "$SSH_CONFIG"
    ok "  Updated: $SSH_CONFIG"
  else
    info "  Existing SSH config already has the needed host entries — no changes made."
  fi

  section "Rendering workflow file"
  render_workflow "$PROJECT_PREFIX" "$PROJECT_LABEL" "$REPO_PATH" "$SSH_HOST" "$SERVER_PATH" "$ZIP_PATH" "$SERVER_REMOTE" >"$WORKFLOW_DEST"
  chmod 644 "$WORKFLOW_DEST"
  ok "  Wrote: $WORKFLOW_DEST"

  section "Patching ~/.zshrc"
  backup="$(backup_file "$ZSHRC")"
  [ -n "${backup:-}" ] && info "  Backup: $backup"
  if [ -f "$ZSHRC" ] && grep -Fq "$ZSHRC_START" "$ZSHRC"; then
    warn "  ~/.zshrc already has a block for prefix '$PROJECT_PREFIX' — replacing it."
    strip_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END"
  fi
  append_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END" "$ZSHRC_BLOCK_BODY"
  ok "  Updated: $ZSHRC"

  # ----- Next steps -------------------------------------------
  section "Done — next steps"
  echo
  echo "  1) Reload your shell, then verify:"
  echo "       exec zsh"
  echo "       ${PROJECT_PREFIX}help"
  echo
  echo "  2) Confirm your GitHub SSH key is registered with GitHub:"
  echo "       cat $GITHUB_KEY.pub"
  echo "       # If this key is not already in GitHub, paste it at:"
  echo "       # https://github.com/settings/keys"
  echo

  if [ "$HAS_SERVER" -eq 1 ]; then
    server_side_setup_offer
    cat <<EOF
  Manual server-side commands if you skipped or need to redo it:

       ssh $SSH_HOST
       # -N '' generates the key WITHOUT a passphrase. This is standard
       # for read-only deploy keys and required for non-interactive deploy.
       ssh-keygen -t ed25519 -N '' -C "$PROJECT_LABEL deploy" -f ~/.ssh/${PROJECT_PREFIX}_github_deploy
       cat ~/.ssh/${PROJECT_PREFIX}_github_deploy.pub
       # paste THAT public key at https://github.com/<you>/<repo>/settings/keys
       # IMPORTANT: leave "Allow write access" unchecked.

  Optional server-side ~/.ssh/config snippet:

       Host github-${PROJECT_PREFIX}
         HostName github.com
         User git
         IdentityFile ~/.ssh/${PROJECT_PREFIX}_github_deploy
         IdentitiesOnly yes

  Then clone with:
       git clone git\@github-${PROJECT_PREFIX}:you/your-repo.git

  Only use Host github.com if this server has exactly one repo/deploy key.
  For multiple repos, use a unique alias per repo (as shown above) so each
  can carry its own deploy key without interfering with the others.

  Test from the server:
       ssh -T git\@github-${PROJECT_PREFIX}

  Clone or initialize the repo at:
       $SERVER_PATH

  Then on your laptop:
       ${PROJECT_PREFIX}pull
       # ... edit ...
       ${PROJECT_PREFIX}push "first deploy"

EOF
  else
    cat <<EOF
  3) Use the workflow:
       ${PROJECT_PREFIX}pull
       # ... edit ...
       ${PROJECT_PREFIX}push "first commit"
       # In no-server mode, ${PROJECT_PREFIX}push is commit + push only.

  If you add a server later, re-run this bootstrap with the same prefix
  and choose "replace" — it will add the server piece without losing
  your config.

EOF
  fi

  ok "Bootstrap complete."

  # ----- Optional: run the initial server deploy ----------------------
  # After bootstrap, the server has a deploy key and the workflow is
  # installed. Offer to do the first server-side clone/pull right now
  # by sourcing the rendered workflow in a new zsh process and calling
  # deploy-${PROJECT_PREFIX} (which runs _gdw_deploy — handles both
  # fresh clone and pull-on-existing-repo transparently).
  if [ "$HAS_SERVER" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    echo
    info "  The workflow is ready. Want to run the initial server deploy now?"
    info "  This SSHes into $SSH_HOST and clones/pulls the repo at $SERVER_PATH."
    if confirm "  Run deploy-${PROJECT_PREFIX} (initial server-side deploy) now?"; then
      info "  → Running deploy-${PROJECT_PREFIX}..."
      if zsh -c "source '${WORKFLOW_DEST}' && deploy-${PROJECT_PREFIX}"; then
        ok "  Initial deploy complete."
      else
        warn "  Deploy encountered an error — check output above."
        warn "  After reloading your shell you can retry with:"
        echo "       exec zsh && deploy-${PROJECT_PREFIX}"
      fi
    fi
  fi

  # Auto-install gdw-bootstrap alias on first run, same pattern as
  # init-project's gdw-init alias.
  local boot_alias_start="# >>> gdw-bootstrap alias >>>"
  local boot_alias_end="# <<< gdw-bootstrap alias <<<"
  if [ ! -f "$ZSHRC" ] || ! grep -Fq "$boot_alias_start" "$ZSHRC"; then
    section "Convenience alias"
    info "  Adding 'gdw-bootstrap' alias so you can re-run this from anywhere."
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
  fi

  echo
  _color "1;33" "  ⚠  RELOAD YOUR SHELL to pick up the new functions:"
  echo "       exec zsh"
  echo "     (or open a new terminal tab — same effect)"
  echo
  echo "     Already-running shells have the OLD function bodies cached."
  echo "     Without the reload, ${PROJECT_PREFIX}push will silently use stale code"
  echo "     and may behave unexpectedly."
  echo
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
    uninstall_ssh_host="$(grep -E '^\s*GDW_SSH_HOST=' "$WORKFLOW_DEST" \
      | sed -E 's/.*="(.*)"/\1/' | head -1)"
    uninstall_server_path="$(grep -E '^\s*GDW_SERVER_PATH=' "$WORKFLOW_DEST" \
      | sed -E "s/.*='(.*)'/\1/;s/.*=\"(.*)\"/\1/" | head -1)"
    uninstall_server_remote="$(grep -E '^\s*GDW_SERVER_REMOTE=' "$WORKFLOW_DEST" \
      | sed -E 's/.*="(.*)"/\1/' | head -1)"
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
          if ssh "$uninstall_ssh_host" "rm -rf '${uninstall_server_path}'"; then
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
        | sed -E "s/.*='(.*)'/\1/;s/.*=\"(.*)\"/\1/" | head -1)"
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

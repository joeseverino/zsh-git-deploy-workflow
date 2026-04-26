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
#   - Register SSH keys with GitHub automatically.
#   - Add deploy keys to a GitHub repo automatically.
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

# Marker blocks — used so we can find/remove our additions later.
# __PREFIX__ is replaced at runtime so multiple projects can coexist.
ZSHRC_MARK_START="# >>> __PREFIX__ git deploy workflow >>>"
ZSHRC_MARK_END="# <<< __PREFIX__ git deploy workflow <<<"
SSH_MARK_START="# >>> __PREFIX__ deploy hosts >>>"
SSH_MARK_END="# <<< __PREFIX__ deploy hosts <<<"

DRY_RUN=0
UNINSTALL=0


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

# confirm "Question" -> returns 0 (yes) or 1 (no)
confirm() {
  local raw=""
  read -r -p "  $1 [Y/n]: " raw
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    n|no) return 1 ;;
    *)    return 0 ;;
  esac
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

build_github_block() {
  local github_host="$1" github_key="$2"
  cat <<EOF
Host $github_host
  User git
  AddKeysToAgent yes
  UseKeychain yes
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
  AddKeysToAgent yes
  UseKeychain yes
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
#   2. Generate ~/.ssh/<prefix>_github_deploy with a passphrase prompt
#      (skipped if the key already exists).
#   3. Append a marker-bracketed `Host <SERVER_GITHUB_ALIAS>` block to
#      ~/.ssh/config pointing at the new key (skipped if the marker is
#      already there).
#   4. Tighten permissions on the key files and ssh config.
#   5. Print the public key for manual paste into GitHub Deploy Keys.
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

  local remote_key="\$HOME/.ssh/${PROJECT_PREFIX}_github_deploy"
  local marker_start="# >>> ${PROJECT_PREFIX} ${SERVER_GITHUB_ALIAS} alias >>>"
  local marker_end="# <<< ${PROJECT_PREFIX} ${SERVER_GITHUB_ALIAS} alias <<<"

  echo
  info "  → SSHing into $SSH_HOST..."
  info "    If a new key needs to be generated, ssh-keygen will prompt"
  info "    for a passphrase. Pick a strong one."
  echo

  # Single SSH session that does everything. -t allocates a TTY so the
  # passphrase prompt works. Each step checks for existing state and is
  # safe to re-run.
  if ! ssh -t "$SSH_HOST" "
    set -e

    # 1. ~/.ssh exists with correct permissions
    mkdir -p \$HOME/.ssh
    chmod 700 \$HOME/.ssh

    # 2. Deploy key — only generate if missing
    if [ -f $remote_key ]; then
      echo 'Deploy key already exists at $remote_key — leaving it alone.'
      echo '(Delete it first if you want a fresh one.)'
    else
      ssh-keygen -t ed25519 -C '$PROJECT_LABEL deploy' -f $remote_key
    fi
    chmod 600 $remote_key
    chmod 644 ${remote_key}.pub

    # 3. Add Host alias block to ~/.ssh/config (idempotent via marker)
    touch \$HOME/.ssh/config
    chmod 600 \$HOME/.ssh/config
    if grep -Fq '$marker_start' \$HOME/.ssh/config; then
      echo 'Host alias block for $SERVER_GITHUB_ALIAS already present — leaving it alone.'
    else
      printf '\n%s\nHost %s\n  HostName github.com\n  User git\n  IdentityFile %s\n  IdentitiesOnly yes\n%s\n' \
        '$marker_start' '$SERVER_GITHUB_ALIAS' '$remote_key' '$marker_end' \
        >> \$HOME/.ssh/config
      echo 'Added Host $SERVER_GITHUB_ALIAS block to ~/.ssh/config.'
    fi
  "; then
    err "  Server-side setup failed."
    return 1
  fi

  echo
  info "  → Reading the public key..."
  echo
  echo "  ─── Copy everything between the lines ───"
  echo
  ssh "$SSH_HOST" "cat $remote_key.pub" || {
    err "  Could not read the public key from the server."
    return 1
  }
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
EOF

  if command -v open >/dev/null 2>&1; then
    echo
    if confirm "     Open GitHub in your browser?"; then
      open "https://github.com/" 2>/dev/null || true
    fi
  fi

  echo
  if ! confirm "     Done adding the key on GitHub? Test the alias from the server now?"; then
    info "  Skipping the test."
    return 0
  fi

  echo
  info "  → Testing 'ssh -T git@$SERVER_GITHUB_ALIAS' from the server..."
  info "    Expected output: 'Hi <you>/<repo>! You've successfully authenticated...'"
  info "    (The non-zero exit is normal — GitHub doesn't allow shell access.)"
  ssh "$SSH_HOST" "ssh -T -o BatchMode=no git@$SERVER_GITHUB_ALIAS" || true

  echo
  ok "  Server-side setup complete. Read the output above for the GitHub SSH test result."
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
  cat <<'EOF'
This will set up an edit/commit/push workflow for a project, with an
optional deploy step for projects that live on a remote server.

Nothing is written until you confirm the plan. ~/.zshrc and ~/.ssh/config
are backed up before modification.
EOF

  # ----- Mode: with-server vs. no-server ----------------------
  section "Mode"
  cat <<'EOF'
Some projects deploy to a remote server when you push, such as WordPress
plugins, WordPress themes, Django apps, and static sites. Others are just
GitHub repos where you only want the local git aliases.
EOF
  echo

  HAS_SERVER=1
  if ! confirm "Does this project deploy to a remote server?"; then
    HAS_SERVER=0
    info "  No-server mode: push commands will commit + push only, no deploy."
  fi

  # ----- Project identity -------------------------------------
  section "Project info"
  PROJECT_LABEL="$(ask 'Project name (human-readable)' 'My Project')"
  PROJECT_PREFIX="$(ask 'Command prefix (lowercase; e.g. theme gives themepull/themepush)' 'mp')"

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
  else
    rm -f /tmp/.bootstrap-existing.$$
  fi

  # ----- Project paths ----------------------------------------
  REPO_PATH="$(ask 'Local clone path of the project' "$HOME/Code/$PROJECT_PREFIX")"
  ZIP_PATH="$(ask 'Local zip output path (for review/distribution)' "$HOME/Downloads/${PROJECT_PREFIX}-review.zip")"

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
    SERVER_PATH_DEFAULT='$HOME/path/to/'"$PROJECT_PREFIX"
    SERVER_PATH="$(ask 'Project path on the server' "$SERVER_PATH_DEFAULT")"
  fi

  # ----- GitHub SSH -------------------------------------------
  section "GitHub SSH"
  GITHUB_HOST="$(ask 'GitHub SSH host' 'github.com')"
  GITHUB_KEY=""
  ADD_GITHUB_HOST=1

  if ssh_config_has_host "$GITHUB_HOST"; then
    info "  Found existing Host $GITHUB_HOST in $SSH_CONFIG."
    EXISTING_GITHUB_KEY="$(ssh_config_get_host_field "$GITHUB_HOST" 'IdentityFile' || true)"
    EXISTING_GITHUB_KEY="$(expand_ssh_path "$EXISTING_GITHUB_KEY")"

    if [ -n "$EXISTING_GITHUB_KEY" ]; then
      GITHUB_KEY="$EXISTING_GITHUB_KEY"
      ok "  Using existing GitHub key: $GITHUB_KEY"
    else
      warn "  Host $GITHUB_HOST exists, but no IdentityFile was found."
      GITHUB_KEY="$(ask 'GitHub key path to use or create' "$HOME/.ssh/id_ed25519")"
    fi

    ADD_GITHUB_HOST=0
    info "  Skipping duplicate GitHub SSH config setup."
  else
    warn "  No Host $GITHUB_HOST block found in $SSH_CONFIG."
    GITHUB_KEY="$(ask 'GitHub key path to use or create' "$HOME/.ssh/${PROJECT_PREFIX}_github")"
    ADD_GITHUB_HOST=1
  fi

  # ----- Production server SSH --------------------------------
  if [ "$HAS_SERVER" -eq 1 ]; then
    section "Production server SSH"
    SSH_HOST="$(ask 'SSH host alias to use locally' "${PROJECT_PREFIX}-prod")"

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
        plan "Key:      $SERVER_KEY"
      else
        warn "  Host $SSH_HOST exists, but no IdentityFile was found."
        SERVER_KEY="$(ask 'Server key path to use or create' "$HOME/.ssh/${PROJECT_PREFIX}_server")"
      fi

      ADD_SERVER_HOST=0
      info "  Skipping duplicate server SSH config setup."
    else
      warn "  No Host $SSH_HOST block found in $SSH_CONFIG."
      SSH_HOSTNAME="$(ask 'Server hostname or IP' 'example.com')"
      SSH_USER="$(ask 'Server SSH user' 'deploy')"
      SSH_PORT="$(ask 'Server SSH port' '22')"
      SERVER_KEY="$(ask 'Server key path to use or create' "$HOME/.ssh/${PROJECT_PREFIX}_server")"
      ADD_SERVER_HOST=1
    fi

    # ----- Server-side GitHub alias (per-repo deploy key) ------------
    section "Server-side GitHub deploy key"
    cat <<'EOF'
The server fetches the repo through a unique SSH alias so each repo
can have its own read-only deploy key. The alias lives in the SERVER's
~/.ssh/config (the bootstrap will write it there for you), so it does
NOT need to exist on this Mac and your local origin URL is unchanged.

Recommended naming: github-<prefix>  (e.g. github-theme).
EOF
    echo
    SERVER_GITHUB_ALIAS="$(ask 'Server-side GitHub host alias' "github-${PROJECT_PREFIX}")"

    # Try to derive the server remote URL from the local repo's origin.
    local local_origin=""
    if [ -d "$REPO_PATH/.git" ]; then
      local_origin="$(cd "$REPO_PATH" && git config --get remote.origin.url 2>/dev/null || true)"
    fi
    local server_remote_default=""
    if [ -n "$local_origin" ]; then
      # Swap github.com for the alias to produce e.g.
      #   git@github.com:user/repo.git  ->  git@github-theme:user/repo.git
      server_remote_default="$(printf '%s' "$local_origin" | sed "s|@github\.com:|@${SERVER_GITHUB_ALIAS}:|")"
    fi
    if [ -z "$server_remote_default" ]; then
      server_remote_default="git@${SERVER_GITHUB_ALIAS}:<you>/<repo>.git"
    fi
    SERVER_REMOTE="$(ask 'Server-side GitHub remote URL (uses the alias above)' "$server_remote_default")"
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

  if ! confirm "Proceed?"; then
    warn "Cancelled."
    return 0
  fi

  # ----- Apply ------------------------------------------------
  section "Installing shared library"
  install_shared_lib

  section "Checking SSH keys"
  info "  Existing keys are reused. Missing keys will be created with a passphrase prompt."
  generate_key "$GITHUB_KEY" "${PROJECT_LABEL} — github"
  if [ "$HAS_SERVER" -eq 1 ]; then
    generate_key "$SERVER_KEY" "${PROJECT_LABEL} — server ssh"
  fi

  # ssh-config patching: only run if there is actually something to add.
  if [ "$ADD_GITHUB_HOST" -eq 1 ] || { [ "$HAS_SERVER" -eq 1 ] && [ "$ADD_SERVER_HOST" -eq 1 ]; }; then
    section "Patching ~/.ssh/config"

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
    section "Patching ~/.ssh/config"
    info "  Existing SSH config already has the needed host entries — no changes made."
  fi

  section "Rendering workflow file"
  render_workflow "$PROJECT_PREFIX" "$PROJECT_LABEL" "$REPO_PATH" "$SSH_HOST" "$SERVER_PATH" "$ZIP_PATH" "$SERVER_REMOTE" >"$WORKFLOW_DEST"
  chmod 644 "$WORKFLOW_DEST"
  ok "  Wrote: $WORKFLOW_DEST"

  section "Patching ~/.zshrc"
  if [ -f "$ZSHRC" ] && grep -Fq "$ZSHRC_START" "$ZSHRC"; then
    warn "  ~/.zshrc already has a block for prefix '$PROJECT_PREFIX' — replacing it."
    backup="$(backup_file "$ZSHRC")"
    [ -n "${backup:-}" ] && info "  Backup: $backup"
    strip_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END"
  else
    backup="$(backup_file "$ZSHRC")"
    [ -n "${backup:-}" ] && info "  Backup: $backup"
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
       ssh-keygen -t ed25519 -C "$PROJECT_LABEL deploy" -f ~/.ssh/${PROJECT_PREFIX}_github_deploy
       cat ~/.ssh/${PROJECT_PREFIX}_github_deploy.pub
       # paste THAT public key at https://github.com/<you>/<repo>/settings/keys
       # IMPORTANT: leave "Allow write access" unchecked.

  Optional server-side ~/.ssh/config snippet:

       Host github.com
         User git
         IdentityFile ~/.ssh/${PROJECT_PREFIX}_github_deploy
         IdentitiesOnly yes

  If the server already has a Host github.com block for another repo,
  use a unique alias instead so each repo can carry its own deploy key:

       Host github-${PROJECT_PREFIX}
         HostName github.com
         User git
         IdentityFile ~/.ssh/${PROJECT_PREFIX}_github_deploy
         IdentitiesOnly yes

  Then clone with: git clone git\@github-${PROJECT_PREFIX}:you/your-repo.git

  Test from the server:
       ssh -T git@github.com         # or your alias

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
}


# ---------------------------------------------------------------------
# Uninstall flow
# ---------------------------------------------------------------------

uninstall_flow() {
  PROJECT_PREFIX="$(ask 'Prefix to remove (the one you used during bootstrap)' '')"
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
  plan "Workflow file at $WORKFLOW_DEST will be left in place"
  plan "SSH keys will be left in place (delete manually if desired)"
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
  ok "Uninstall complete."
  info "If you also want to remove the workflow file:"
  echo "    rm $WORKFLOW_DEST"

  # Count marker blocks still in ~/.zshrc. If zero remain, no project
  # is sourcing the lib anymore, so we can suggest removing it.
  local other_projects=0
  if [ -f "$ZSHRC" ]; then
    other_projects=$(grep -cE '^# >>> [a-z][a-z0-9_]* git deploy workflow >>>' "$ZSHRC" 2>/dev/null | tr -d ' \n' || echo 0)
  fi

  if [ -f "$LIB_DEST" ] && [ "$other_projects" -eq 0 ]; then
    info "No other projects are sourcing the shared library. You can remove it:"
    echo "    rm $LIB_DEST"
  elif [ -f "$LIB_DEST" ]; then
    info "Shared library left in place ($other_projects other project(s) still use it)."
  fi

  info "And the SSH keys, if you generated them:"
  echo "    rm ~/.ssh/${PROJECT_PREFIX}_github  ~/.ssh/${PROJECT_PREFIX}_github.pub"
  echo "    rm ~/.ssh/${PROJECT_PREFIX}_server  ~/.ssh/${PROJECT_PREFIX}_server.pub"
}


# ---------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------

usage() {
  cat <<EOF
bootstrap-deploy.sh — install a customized git deploy workflow.

Usage:
  bash bootstrap-deploy.sh              # install
  bash bootstrap-deploy.sh --dry-run    # preview without changes
  bash bootstrap-deploy.sh --uninstall  # remove a previous bootstrap
  bash bootstrap-deploy.sh --help

Options:
  --dry-run     Print every planned change but write nothing.
  --uninstall   Strip a previous bootstrap's blocks from ~/.zshrc and ~/.ssh/config.
                Leaves your workflow file and SSH keys in place.
  --help, -h    Show this message.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)   DRY_RUN=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --help|-h)   usage; exit 0 ;;
    *)           err "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done

if [ "$UNINSTALL" -eq 1 ]; then
  uninstall_flow
else
  install_flow
fi

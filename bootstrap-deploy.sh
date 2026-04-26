#!/usr/bin/env bash
#
# bootstrap-deploy.sh — install a customized git deploy workflow.
#
# Interactively bootstraps a complete edit → commit → push → deploy loop
# for any project. Customizes the workflow's command names to your
# project, generates two SSH keys (one for GitHub, one for the server),
# patches ~/.ssh/config, and adds the workflow source line to ~/.zshrc.
#
# Usage
# -----
#   bash bootstrap-deploy.sh              # interactive install
#   bash bootstrap-deploy.sh --dry-run    # preview every change, write nothing
#   bash bootstrap-deploy.sh --uninstall  # cleanly remove a previous bootstrap
#   bash bootstrap-deploy.sh --help
#
# What this DOES
#   1. Prompts for project name, command prefix, GitHub repo, and the
#      production server SSH details.
#   2. Generates two ed25519 SSH keys locally (one for GitHub, one for
#      the production server) unless they already exist.
#   3. Adds two host blocks to ~/.ssh/config (github.com + your server),
#      using marker blocks so they're easy to remove later.
#   4. Renders a customized copy of git-deploy-workflow.zsh into
#      ~/.{prefix}-workflow.zsh with your function names.
#   5. Adds one source line to ~/.zshrc.
#   6. Prints the next steps you have to do off-machine: register the
#      GitHub deploy key, clone the repo on the server, etc.
#
# What this does NOT do (because it can't, securely)
#   - Generate the SERVER's deploy key (run that on the server itself).
#   - Register your local public key with GitHub (paste it manually into
#     GitHub Settings → SSH and GPG keys).
#   - Add the server's deploy key as a Deploy Key on the GitHub repo
#     (paste it manually into Repo Settings → Deploy keys).
#
# Tested on macOS (bash 3.2 / 5.x) and Linux (bash 4.x+). No external
# dependencies; uses only sed, awk, ssh-keygen, and standard tools.

set -euo pipefail

# ---------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/git-deploy-workflow.zsh"

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
# Workflow file rendering
# ---------------------------------------------------------------------

# Render the template with project-specific names + paths.
# render_workflow <prefix> <project_label> <repo_path> <ssh_host>
#                 <server_path> <zip_path>
render_workflow() {
  local prefix="$1" label="$2" repo="$3" ssh_host="$4"
  local server_path="$5" zip_path="$6"
  local upper_prefix
  upper_prefix="$(printf '%s' "$prefix" | tr '[:lower:]' '[:upper:]')"

  # The template uses the `ship` prefix throughout. Substitute the
  # user's chosen prefix in: function names, internal helpers, variables.
  # Do `_ship_` and `SHIP_` first so we don't double-rewrite.
  sed \
    -e "s/_ship_/_${prefix}_/g" \
    -e "s/SHIP_/${upper_prefix}_/g" \
    -e "s/shippull/${prefix}pull/g" \
    -e "s/shippush/${prefix}push/g" \
    -e "s/shipbranch/${prefix}branch/g" \
    -e "s/shiprevert/${prefix}revert/g" \
    -e "s/shipstatus/${prefix}status/g" \
    -e "s/shipzip/${prefix}zip/g" \
    -e "s/shiphelp/${prefix}help/g" \
    -e "s/deploy-ship/deploy-${prefix}/g" \
    "$TEMPLATE" |
  awk -v repo="$repo" -v host="$ssh_host" \
      -v server="$server_path" -v zip="$zip_path" \
      -v upper="$upper_prefix" -v label="$label" '
    {
      if ($0 ~ "^"upper"_REPO=") {
        print upper"_REPO=\""repo"\""
      } else if ($0 ~ "^"upper"_SSH_HOST=") {
        print upper"_SSH_HOST=\""host"\""
      } else if ($0 ~ "^"upper"_SERVER_PATH=") {
        print upper"_SERVER_PATH='\''"server"'\''"
      } else if ($0 ~ "^"upper"_ZIP_OUTPUT=") {
        print upper"_ZIP_OUTPUT=\""zip"\""
      } else {
        print
      }
    }
  '
}


# ---------------------------------------------------------------------
# SSH key generation
# ---------------------------------------------------------------------

# generate_key <key_path> <comment>
generate_key() {
  local key_path="$1" comment="$2"
  if [ -f "$key_path" ]; then
    warn "  Key already exists at $key_path — skipped (delete it first if you want a new one)."
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
# SSH config block builder
# ---------------------------------------------------------------------

build_github_block() {
  local github_key="$1"
  cat <<EOF
Host github.com
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

# Returns 0 if ~/.ssh/config already has a `Host github.com` line OUTSIDE
# any of our marker blocks (i.e. a pre-existing user-managed github config).
ssh_config_has_external_github() {
  [ -f "$SSH_CONFIG" ] || return 1
  # Strip every marker block we've ever added, then check what's left.
  awk '
    BEGIN { skip = 0 }
    /^# >>> .* (git deploy workflow|deploy hosts) >>>/ { skip = 1; next }
    skip && /^# <<< .* (git deploy workflow|deploy hosts) <<</ { skip = 0; next }
    !skip { print }
  ' "$SSH_CONFIG" | grep -Eq '^[Hh]ost\s+github\.com\b'
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
This will set up an edit/commit/push (and optional /deploy) workflow for
a project. Nothing is written until you confirm the plan; ~/.zshrc and
~/.ssh/config are backed up before any modification.
EOF

  # ----- Mode: with-server vs. no-server ----------------------
  section "Mode"
  cat <<'EOF'
Some projects deploy to a remote server when you push (WordPress
plugins, Django apps, static sites). Others — private repos, libraries,
research code — don't have a server to deploy to and you just want the
git aliases.
EOF
  echo
  HAS_SERVER=1
  if ! confirm "Do you have a remote server to deploy to?"; then
    HAS_SERVER=0
    info "  No-server mode: shippush will commit + push only, no deploy."
  fi

  # ----- Project identity -------------------------------------
  section "Project info"
  PROJECT_LABEL="$(ask 'Project name (human-readable)' 'My Project')"
  PROJECT_PREFIX="$(ask 'Command prefix (lowercase; e.g. mp gives mppull/mppush)' 'mp')"

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
  (r) replace — back up the existing files, strip the old marker
      blocks, and reinstall with the new answers.
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
  # rendered workflow knows there's nothing to deploy.
  SERVER_PATH=""
  SSH_HOST=""
  SSH_HOSTNAME=""
  SSH_USER=""
  SSH_PORT=""
  SERVER_KEY=""

  if [ "$HAS_SERVER" -eq 1 ]; then
    SERVER_PATH_DEFAULT='$HOME/path/to/'"$PROJECT_PREFIX"
    SERVER_PATH="$(ask 'Project path on the server (single quotes preserve $HOME)' "$SERVER_PATH_DEFAULT")"

    section "Production server SSH"
    SSH_HOST="$(ask 'SSH host alias to use locally' "${PROJECT_PREFIX}-prod")"
    SSH_HOSTNAME="$(ask 'Server hostname or IP' 'example.com')"
    SSH_USER="$(ask 'Server SSH user' 'deploy')"
    SSH_PORT="$(ask 'Server SSH port' '22')"
  fi

  # ----- SSH keys ---------------------------------------------
  section "SSH keys"
  GITHUB_KEY="$(ask 'GitHub key path (will be created if missing)' "$HOME/.ssh/${PROJECT_PREFIX}_github")"
  if [ "$HAS_SERVER" -eq 1 ]; then
    SERVER_KEY="$(ask 'Server key path (will be created if missing)' "$HOME/.ssh/${PROJECT_PREFIX}_server")"
  fi

  # ----- Existing github.com block? ---------------------------
  ADD_GITHUB_HOST=1
  if ssh_config_has_external_github; then
    section "Existing github.com config detected"
    cat <<'EOF'
Your ~/.ssh/config already has a `Host github.com` block managed
outside this tool. Adding another one is usually harmless (SSH merges
multiple blocks), but it can be confusing.
EOF
    echo
    if ! confirm "Add our github.com block anyway?"; then
      ADD_GITHUB_HOST=0
      info "  Skipping the github.com block — your existing config will be used."
    fi
  fi

  WORKFLOW_DEST="$HOME/.${PROJECT_PREFIX}-workflow.zsh"
  ZSHRC_BLOCK_BODY="source \"$WORKFLOW_DEST\""

  # ----- Plan -------------------------------------------------
  section "Plan"
  plan "Workflow file:   $WORKFLOW_DEST"
  plan "Functions:       ${PROJECT_PREFIX}pull, ${PROJECT_PREFIX}push, ${PROJECT_PREFIX}branch, ${PROJECT_PREFIX}revert, ${PROJECT_PREFIX}status, ${PROJECT_PREFIX}zip, ${PROJECT_PREFIX}help"
  plan "Patch ~/.zshrc:  add 1 source line"
  if [ "$ADD_GITHUB_HOST" -eq 1 ] && [ "$HAS_SERVER" -eq 1 ]; then
    plan "Patch ~/.ssh/config: add Host github.com + Host $SSH_HOST"
  elif [ "$ADD_GITHUB_HOST" -eq 1 ]; then
    plan "Patch ~/.ssh/config: add Host github.com"
  elif [ "$HAS_SERVER" -eq 1 ]; then
    plan "Patch ~/.ssh/config: add Host $SSH_HOST"
  else
    plan "Patch ~/.ssh/config: (nothing to add — no server, existing github)"
  fi
  if [ "$HAS_SERVER" -eq 1 ]; then
    plan "Generate keys:   $GITHUB_KEY, $SERVER_KEY  (skipped if they exist)"
  else
    plan "Generate keys:   $GITHUB_KEY  (skipped if it exists)"
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
  section "Generating SSH keys"
  generate_key "$GITHUB_KEY" "${PROJECT_LABEL} — github"
  if [ "$HAS_SERVER" -eq 1 ]; then
    generate_key "$SERVER_KEY" "${PROJECT_LABEL} — server deploy"
  fi

  # ssh-config patching: only run if there's actually something to add
  if [ "$ADD_GITHUB_HOST" -eq 1 ] || [ "$HAS_SERVER" -eq 1 ]; then
    section "Patching ~/.ssh/config"
    if [ -f "$SSH_CONFIG" ] && grep -Fq "$SSH_START" "$SSH_CONFIG"; then
      warn "  ~/.ssh/config already has a block for this project — replacing it."
      backup="$(backup_file "$SSH_CONFIG")"
      [ -n "${backup:-}" ] && info "  Backup: $backup"
      strip_block "$SSH_CONFIG" "$SSH_START" "$SSH_END"
    fi

    ssh_block_body=""
    if [ "$ADD_GITHUB_HOST" -eq 1 ]; then
      ssh_block_body+="$(build_github_block "$GITHUB_KEY")"
    fi
    if [ "$HAS_SERVER" -eq 1 ]; then
      [ -n "$ssh_block_body" ] && ssh_block_body+=$'\n\n'
      ssh_block_body+="$(build_server_block "$SSH_HOST" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT" "$SERVER_KEY")"
    fi
    append_block "$SSH_CONFIG" "$SSH_START" "$SSH_END" "$ssh_block_body"
    chmod 600 "$SSH_CONFIG"
    ok "  Updated: $SSH_CONFIG"
  fi

  section "Rendering workflow file"
  render_workflow "$PROJECT_PREFIX" "$PROJECT_LABEL" "$REPO_PATH" "$SSH_HOST" "$SERVER_PATH" "$ZIP_PATH" >"$WORKFLOW_DEST"
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
  echo "  2) Add your GitHub key to your GitHub account:"
  echo "       cat $GITHUB_KEY.pub"
  echo "       # then paste at https://github.com/settings/keys"
  echo

  if [ "$HAS_SERVER" -eq 1 ]; then
    cat <<EOF
  3) On your production server (one-time):
       ssh $SSH_HOST
       ssh-keygen -t ed25519 -C "$PROJECT_LABEL deploy" -f ~/.ssh/${PROJECT_PREFIX}_github_deploy -N ""
       cat ~/.ssh/${PROJECT_PREFIX}_github_deploy.pub
       # paste THAT public key at https://github.com/<you>/<repo>/settings/keys
       # IMPORTANT: leave "Allow write access" UNCHECKED (read-only).

  4) Then on the server, add this to ~/.ssh/config:
       Host github.com
         User git
         IdentityFile ~/.ssh/${PROJECT_PREFIX}_github_deploy
         IdentitiesOnly yes

  5) Test from the server:
       ssh -T git@github.com

  6) Clone (or initialize) the repo on the server at:
       $SERVER_PATH

  7) Back on your laptop, you're ready:
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
       # In no-server mode, ${PROJECT_PREFIX}push is just commit + push to GitHub.

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
  info "And the SSH keys (if you generated them):"
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

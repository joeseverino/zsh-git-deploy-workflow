# ============================================================
# Git deploy workflow — sourceable zsh function library
#
# Source this file (don't execute it) from your ~/.zshrc to get the
# `shippull`, `shippush`, `shipbranch`, `shiprevert`, `shipstatus`,
# `shipzip`, and `shiphelp` commands.
#
#   # ~/.zshrc
#   source "$HOME/path/to/git-deploy-workflow.zsh"
#
# Then run `shiphelp` for an overview of every command.
#
# This is a TEMPLATE. You can either:
#   (a) Run bootstrap-deploy.sh to generate a configured copy with
#       your own prefix/paths/SSH host, or
#   (b) Edit the SHIP_* variables below by hand and source this file.
# ============================================================


# ------------------------------------------------------------
# Configuration — edit these for your environment
# ------------------------------------------------------------

# Local path to your project repository.
SHIP_REPO="$HOME/path/to/your-project"

# SSH host alias from ~/.ssh/config.
#
# Recommended SSH hygiene:
# - Separate keys for GitHub vs. the production server.
# - IdentitiesOnly yes so SSH offers only the explicitly assigned key.
# - AddKeysToAgent yes + UseKeychain yes (macOS) so passphrases are cached.
# - The server's GitHub key should be a READ-ONLY deploy key (so the
#   server can pull updates but cannot push back).
#
# See the project README for a full ~/.ssh/config example.
SHIP_SSH_HOST="example-host"

# Project directory on the server.
#
# IMPORTANT: keep the single quotes. They prevent local $HOME expansion
# so the variable expands REMOTELY when SSHed in (where $HOME is the
# server user's home, not yours).
SHIP_SERVER_PATH='$HOME/path/to/your-project'

# Optional zip output path for review/upload testing.
SHIP_ZIP_OUTPUT="$HOME/Downloads/your-project-review.zip"


# ------------------------------------------------------------
# Internal helpers (prefixed with _ship_ — not for direct use)
# ------------------------------------------------------------

# Print a green success line.
_ship_ok() {
  printf "\033[32m%s\033[0m\n" "$1"
}

# Print a red failure line.
_ship_err() {
  printf "\033[31m%s\033[0m\n" "$1"
}

# Print a yellow warning line.
_ship_warn() {
  printf "\033[33m%s\033[0m\n" "$1"
}

# Returns 0 (clean) or 1 (dirty). Reports nothing — caller handles output.
_ship_repo_is_clean() {
  git diff --quiet \
    && git diff --cached --quiet \
    && [ -z "$(git ls-files --others --exclude-standard)" ]
}

# Print a "you have local changes" report and a list of recovery options.
_ship_report_dirty() {
  _ship_warn "Local changes or untracked files detected."
  git status --short
  echo ""
  echo "Next options:"
  echo '  shippush "commit message"      # commit/push/deploy current edits if on main'
  echo '  shipbranch branch-name         # move current edits onto a new branch'
  echo "  git restore .                  # discard tracked edits"
  echo "  git clean -fd                  # remove untracked files"
}


# ------------------------------------------------------------
# Public commands
# ------------------------------------------------------------

# Pull latest main branch safely, but refuse to overwrite local work.
shippull() {
  cd "$SHIP_REPO" || return 1

  git fetch origin || return 1

  if ! _ship_repo_is_clean; then
    _ship_report_dirty
    return 1
  fi

  git checkout main || return 1
  git pull --ff-only || return 1

  _ship_ok "Local repo is clean and up to date."
}


# Create a new branch from the current local state.
shipbranch() {
  cd "$SHIP_REPO" || return 1

  if [ -z "$1" ]; then
    echo "Usage: shipbranch branch-name"
    return 1
  fi

  git checkout -b "$1"
}


# Deploy the approved GitHub version to the live server.
# Sends one non-interactive SSH command — does not open a shell session.
deploy-ship() {
  echo "Deploying to server..."

  if ssh "$SHIP_SSH_HOST" "cd $SHIP_SERVER_PATH && git pull --ff-only"; then
    _ship_ok "Deployment successful."
  else
    _ship_err "Deployment failed. Check server connection or Git status."
    return 1
  fi
}


# Commit, push, and deploy from main in one repeatable command.
shippush() {
  cd "$SHIP_REPO" || return 1

  if [ -z "$1" ]; then
    echo 'Usage: shippush "commit message"'
    return 1
  fi

  local current_branch
  current_branch="$(git branch --show-current)"

  if [ "$current_branch" != "main" ]; then
    _ship_warn "shippush only deploys from main. Current branch: $current_branch"
    echo "Use: git push -u origin $current_branch"
    return 1
  fi

  git add -A

  if git diff --cached --quiet; then
    echo "No staged changes to commit. Nothing pushed or deployed."
    return 0
  fi

  git status --short
  git commit -m "$1" || return 1
  git push || return 1
  deploy-ship
}


# Revert the latest main commit, push the revert, and redeploy.
shiprevert() {
  cd "$SHIP_REPO" || return 1

  local current_branch
  current_branch="$(git branch --show-current)"

  if [ "$current_branch" != "main" ]; then
    _ship_warn "shiprevert only runs from main. Current branch: $current_branch"
    return 1
  fi

  git fetch origin || return 1

  if ! _ship_repo_is_clean; then
    _ship_warn "Local changes or untracked files detected. Commit, stash, or discard them before reverting."
    git status --short
    return 1
  fi

  git pull --ff-only || return 1

  echo "About to revert the latest commit:"
  git log -1 --oneline
  echo ""

  local confirm
  read -r "confirm?Type YES to continue: "

  if [ "$confirm" != "YES" ]; then
    echo "Revert cancelled."
    return 1
  fi

  git revert --no-edit HEAD || return 1
  git push || return 1
  deploy-ship
}


# Quick local repo status helper.
shipstatus() {
  cd "$SHIP_REPO" || return 1
  git status --short
  echo ""
  echo "Branch: $(git branch --show-current)"
}


# Create a clean zip from the current Git commit.
# Uses git archive so ignored runtime files, vendor files, and local
# artifacts stay out of the bundle.
shipzip() {
  cd "$SHIP_REPO" || return 1

  git archive --format=zip --output "$SHIP_ZIP_OUTPUT" HEAD || return 1

  if [ -f "$SHIP_ZIP_OUTPUT" ]; then
    ls -lh "$SHIP_ZIP_OUTPUT"
    # Reveal in Finder on macOS; harmless no-op on Linux.
    open -R "$SHIP_ZIP_OUTPUT" 2>/dev/null || true
  else
    _ship_err "ZIP was not created."
    return 1
  fi
}


# Print a quick reference of every command in this workflow.
shiphelp() {
  cat <<'EOF'
Git deploy workflow — available commands

  shippull                     Pull latest main; refuses if you have local edits
  shipbranch <branch-name>     Create a new branch from your current state
  shippush "<commit message>"  Commit, push, and deploy from main
  shiprevert                   Revert the latest main commit (with confirmation) and redeploy
  shipstatus                   Show repo status and current branch
  shipzip                      Build a clean release zip from the current commit
  deploy-ship                  Run the deploy step alone (server git pull)
  shiphelp                     This message

Configured for:
EOF
  echo "  Repo:        $SHIP_REPO"
  echo "  SSH host:    $SHIP_SSH_HOST"
  echo "  Server path: $SHIP_SERVER_PATH"
  echo "  Zip output:  $SHIP_ZIP_OUTPUT"
}

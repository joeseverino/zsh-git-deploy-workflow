# ============================================================
# git-deploy-workflow — shared library
#
# This file is sourced exactly once per shell. It defines the GENERIC
# workflow functions (`_gdw_pull`, `_gdw_push`, etc.) that read their
# project-specific configuration from environment variables:
#
#   GDW_PREFIX       Command prefix for messages and help text.
#   GDW_LABEL        Human-readable project label.
#   GDW_REPO         Local clone path.
#   GDW_SSH_HOST     SSH host alias for the production server.
#                    Empty = no-server mode (deploy step is skipped).
#   GDW_SERVER_PATH  Path to the project on the server.
#   GDW_ZIP_OUTPUT   Where to write the release zip.
#
# A per-project file (`~/.<prefix>-workflow.zsh`) sets these variables
# and defines thin wrappers that call into here. This keeps the
# workflow logic in one auditable place no matter how many projects
# you bootstrap.
# ============================================================


# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------

_gdw_ok()   { printf "\033[32m%s\033[0m\n" "$1"; }
_gdw_err()  { printf "\033[31m%s\033[0m\n" "$1"; }
_gdw_warn() { printf "\033[33m%s\033[0m\n" "$1"; }


# ------------------------------------------------------------
# State checks
# ------------------------------------------------------------

# Returns 0 (clean) or 1 (dirty). Reports nothing — caller handles output.
_gdw_repo_is_clean() {
  git diff --quiet \
    && git diff --cached --quiet \
    && [ -z "$(git ls-files --others --exclude-standard)" ]
}

_gdw_report_dirty() {
  _gdw_warn "Local changes or untracked files detected."
  git status --short
  echo ""
  echo "Next options:"
  printf '  %spush "commit message"        # commit/push/deploy current edits if on main\n' "$GDW_PREFIX"
  printf '  %sbranch branch-name           # move current edits onto a new branch\n' "$GDW_PREFIX"
  echo "  git restore .                  # discard tracked edits"
  echo "  git clean -fd                  # remove untracked files"
}


# ------------------------------------------------------------
# Public commands (called by per-project wrappers)
# ------------------------------------------------------------

# Pull latest main; refuse if local edits exist.
_gdw_pull() {
  cd "$GDW_REPO" || return 1

  git fetch origin || return 1

  if ! _gdw_repo_is_clean; then
    _gdw_report_dirty
    return 1
  fi

  git checkout main || return 1
  git pull --ff-only || return 1

  _gdw_ok "Local repo is clean and up to date."
}


# Create a new branch from the current local state.
_gdw_branch() {
  cd "$GDW_REPO" || return 1

  if [ -z "$1" ]; then
    printf 'Usage: %sbranch branch-name\n' "$GDW_PREFIX"
    return 1
  fi

  git checkout -b "$1"
}


# SSH into the server and deploy the current GitHub repo.
# If the server path does not exist yet, create the parent directory and clone.
# If the server path exists and is already a Git repo, pull --ff-only.
# If the server path exists but is not a Git repo, stop safely.
# No-op if no server is configured.
_gdw_deploy() {
  if [ -z "$GDW_SSH_HOST" ] || [ -z "$GDW_SERVER_PATH" ]; then
    return 0
  fi
  local remote_url
  remote_url="$(git config --get remote.origin.url)"
  if [ -z "$remote_url" ]; then
    _gdw_err "Deployment failed. No origin remote found in local repo."
    return 1
  fi
  echo "Deploying to server..."
  if ssh "$GDW_SSH_HOST" "
    set -e
    server_path='$GDW_SERVER_PATH'
    remote_url='$remote_url'
    if [ ! -d \"\$server_path\" ]; then
      echo \"Server path does not exist. Creating parent directory and cloning...\"
      mkdir -p \"\$(dirname \"\$server_path\")\"
      git clone \"\$remote_url\" \"\$server_path\"
      cd \"\$server_path\"
      git checkout main
      echo \"Initial server checkout complete.\"
      exit 0
    fi
    if [ ! -d \"\$server_path/.git\" ]; then
      echo \"Server path exists but is not a Git repo:\"
      echo \"  \$server_path\"
      echo \"Refusing to overwrite it automatically.\"
      echo \"Move it aside manually, then rerun deploy.\"
      exit 1
    fi
    cd \"\$server_path\"
    git fetch origin
    git checkout main
    git pull --ff-only
  "; then
    _gdw_ok "Deployment successful."
  else
    _gdw_err "Deployment failed. Check server path, Git status, or deploy key access."
    return 1
  fi
}


# Commit, push, and (if a server is configured) deploy from main.
_gdw_push() {
  cd "$GDW_REPO" || return 1

  if [ -z "$1" ]; then
    printf 'Usage: %spush "commit message"\n' "$GDW_PREFIX"
    return 1
  fi

  local current_branch
  current_branch="$(git branch --show-current)"

  if [ "$current_branch" != "main" ]; then
    _gdw_warn "${GDW_PREFIX}push only runs from main. Current branch: $current_branch"
    echo "Use: git push -u origin $current_branch"
    return 1
  fi

  git add -A

  if git diff --cached --quiet; then
    echo "No staged changes to commit. Nothing pushed."
    return 0
  fi

  git status --short
  git commit -m "$1" || return 1
  git push || return 1
  _gdw_deploy
}


# Revert the latest main commit, push the revert, and redeploy.
_gdw_revert() {
  cd "$GDW_REPO" || return 1

  local current_branch
  current_branch="$(git branch --show-current)"

  if [ "$current_branch" != "main" ]; then
    _gdw_warn "${GDW_PREFIX}revert only runs from main. Current branch: $current_branch"
    return 1
  fi

  git fetch origin || return 1

  if ! _gdw_repo_is_clean; then
    _gdw_warn "Local changes or untracked files detected. Commit, stash, or discard them before reverting."
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
  _gdw_deploy
}


# Quick repo status helper.
_gdw_status() {
  cd "$GDW_REPO" || return 1
  git status --short
  echo ""
  echo "Branch: $(git branch --show-current)"
}


# Build a clean zip from the current Git commit.
_gdw_zip() {
  cd "$GDW_REPO" || return 1

  git archive --format=zip --output "$GDW_ZIP_OUTPUT" HEAD || return 1

  if [ -f "$GDW_ZIP_OUTPUT" ]; then
    ls -lh "$GDW_ZIP_OUTPUT"
    # Reveal in Finder on macOS; no-op on Linux.
    open -R "$GDW_ZIP_OUTPUT" 2>/dev/null || true
  else
    _gdw_err "ZIP was not created."
    return 1
  fi
}


# Print a quick reference of every command for this project.
_gdw_help() {
  cat <<EOF
${GDW_LABEL:-Project} workflow — available commands

  ${GDW_PREFIX}pull                     Pull latest main; refuses if you have local edits
  ${GDW_PREFIX}branch <branch-name>     Create a new branch from your current state
  ${GDW_PREFIX}push "<message>"         Commit, push, and deploy from main
  ${GDW_PREFIX}revert                   Revert the latest main commit (with confirmation) and redeploy
  ${GDW_PREFIX}status                   Show repo status and current branch
  ${GDW_PREFIX}zip                      Build a clean release zip from the current commit
  deploy-${GDW_PREFIX}                  Run the deploy step alone (server git pull)
  ${GDW_PREFIX}help                     This message

Configured for:
  Repo:        $GDW_REPO
EOF
  if [ -n "$GDW_SSH_HOST" ]; then
    echo "  SSH host:    $GDW_SSH_HOST"
    echo "  Server path: $GDW_SERVER_PATH"
  else
    echo "  Deploy:      (no server configured — ${GDW_PREFIX}push is commit + push only)"
  fi
  echo "  Zip output:  $GDW_ZIP_OUTPUT"
}

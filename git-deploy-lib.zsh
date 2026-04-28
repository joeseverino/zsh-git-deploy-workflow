# ============================================================
# git-deploy-workflow — shared library
#
# This file is sourced exactly once per shell. It defines the GENERIC
# workflow functions (`_gdw_pull`, `_gdw_push`, etc.) that read their
# project-specific configuration from environment variables:
#
#   GDW_PREFIX         Command prefix for messages and help text.
#   GDW_LABEL          Human-readable project label.
#   GDW_REPO           Local clone path.
#   GDW_SSH_HOST       SSH host alias for the production server.
#                      Empty = no-server mode (deploy step is skipped).
#   GDW_SERVER_PATH    Path to the project on the server.
#   GDW_SERVER_REMOTE  (optional) Git remote URL the server should use
#                      to clone/pull. Use a server-side SSH alias here
#                      (e.g. git@github-theme:user/repo.git) when the
#                      server's deploy key is registered under a host
#                      alias rather than the bare github.com host.
#                      If empty, falls back to the local origin URL.
#   GDW_ZIP_OUTPUT     Where to write the release zip.
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

# Shell-safe single-quoting for values embedded in remote SSH commands.
# Wraps $1 in single quotes, escaping any embedded single quotes as '\''
# (the POSIX portable approach). Mirrors _sq() in bootstrap-deploy.sh.
_gdw_sq() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\''/g")"
}


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
#
# Resolves the remote URL the SERVER will use in this order:
#   1. $GDW_SERVER_REMOTE if set (typical when the server uses a
#      repo-specific SSH alias like github-theme).
#   2. The local repo's `remote.origin.url` (typical when the server
#      has a generic Host github.com block pointing at a deploy key).
#
# Behavior at the destination:
#   - If $GDW_SERVER_PATH does not exist: create the parent dir and
#     `git clone` the resolved remote_url into place.
#   - If it exists and is a Git repo: `git fetch && git checkout main
#     && git pull --ff-only`.
#   - If it exists but is NOT a Git repo: refuse to touch it. The
#     operator must move it aside manually first.
#
# No-op if no server is configured.
_gdw_deploy() {
  if [ -z "$GDW_SSH_HOST" ] || [ -z "$GDW_SERVER_PATH" ]; then
    return 0
  fi

  local remote_url
  remote_url="${GDW_SERVER_REMOTE:-$(git config --get remote.origin.url)}"

  if [ -z "$remote_url" ]; then
    _gdw_err "Deployment failed. No remote URL found (neither GDW_SERVER_REMOTE nor local origin)."
    return 1
  fi

  # Pre-escape both values for safe embedding in the remote command string.
  # GDW_SERVER_PATH and remote_url are user-supplied and may contain single
  # quotes; _gdw_sq() wraps them so the remote shell always parses correctly.
  local server_path_sq remote_url_sq
  server_path_sq="$(_gdw_sq "$GDW_SERVER_PATH")"
  remote_url_sq="$(_gdw_sq "$remote_url")"

  echo ""
  echo "Deploying to server..."

  if ssh "$GDW_SSH_HOST" "
    set -e
    server_path=${server_path_sq}
    remote_url=${remote_url_sq}
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
    echo ""
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
  git push -u origin main || return 1
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
  git push -u origin main || return 1
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


# List every project bootstrapped on this machine. Reads marker
# blocks out of ~/.zshrc and prints a small table of prefix, label,
# repo path, and SSH host. Always available (not project-scoped).
gdw-list() {
  local zshrc="$HOME/.zshrc"
  if [ ! -f "$zshrc" ]; then
    echo "No ~/.zshrc found."
    return 1
  fi

  local prefixes
  prefixes=$(grep -oE '^# >>> [a-z][a-z0-9_]+ git deploy workflow >>>' "$zshrc" 2>/dev/null \
    | sed -E 's/^# >>> ([a-z][a-z0-9_]+) git deploy workflow >>>$/\1/' \
    | sort -u)

  if [ -z "$prefixes" ]; then
    echo "No git-deploy-workflow projects found in $zshrc."
    echo "Run 'bash <repo>/bootstrap-deploy.sh' from a cloned project to add one."
    return 0
  fi

  printf "Configured git-deploy-workflow projects:\n\n"
  local prefix wf label repo host
  while IFS= read -r prefix; do
    [ -z "$prefix" ] && continue
    wf="$HOME/.${prefix}-workflow.zsh"
    if [ -f "$wf" ]; then
      # Strip KEY= prefix then leading/trailing quote. Handles both the
      # single-quoted format written by current bootstrap ('value') and
      # the double-quoted format written by older versions ("value").
      label="$(grep -E '^[[:space:]]*GDW_LABEL=' "$wf" \
        | sed -E "s/^[[:space:]]*GDW_LABEL=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
      repo="$(grep -E '^[[:space:]]*GDW_REPO=' "$wf" \
        | sed -E "s/^[[:space:]]*GDW_REPO=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
      host="$(grep -E '^[[:space:]]*GDW_SSH_HOST=' "$wf" \
        | sed -E "s/^[[:space:]]*GDW_SSH_HOST=//;s/^['\"]//;s/['\"][^'\"]*$//" | head -1)"
      printf '  \033[1m%-12s\033[0m %s\n' "$prefix" "${label:-(no label)}"
      printf '  %-12s repo:    %s\n' '' "${repo:-(unknown)}"
      if [ -n "$host" ]; then
        printf '  %-12s server:  %s\n' '' "$host"
      else
        printf '  %-12s server:  (no-server mode)\n' ''
      fi
      printf '\n'
    else
      printf '  \033[1m%-12s\033[0m (workflow file missing at %s!)\n\n' "$prefix" "$wf"
    fi
  done <<< "$prefixes"

  echo "Run <prefix>help for the full command list of a specific project."
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
    if [ -n "$GDW_SERVER_REMOTE" ]; then
      echo "  Server remote: $GDW_SERVER_REMOTE"
    fi
  else
    echo "  Deploy:      (no server configured — ${GDW_PREFIX}push is commit + push only)"
  fi
  echo "  Zip output:  $GDW_ZIP_OUTPUT"
}

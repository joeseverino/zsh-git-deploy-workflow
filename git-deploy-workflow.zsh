# ============================================================
# Severino Labs Security Layer Git workflow
# Reusable template: update the variables below for your setup.
# ============================================================

# Local path to your plugin repository.
SL_REPO="$HOME/path/to/severino-labs-security-layer"

# SSH host alias from ~/.ssh/config.
#
# Security notes:
# - Use separate SSH keys for GitHub and the web server.
# - Use IdentitiesOnly yes so SSH offers only the key you explicitly assign.
# - Use AddKeysToAgent yes and UseKeychain yes on macOS so passphrases are stored
#   in the local keychain/agent instead of being typed for every deploy.
# - Give the production server a read-only deploy key in GitHub so it can pull
#   updates but cannot push changes back.
#
# Example ~/.ssh/config:
#
# Host github.com
#   User git
#   AddKeysToAgent yes
#   UseKeychain yes
#   IdentityFile ~/.ssh/id_ed25519
#   IdentitiesOnly yes
#
# Host example-site
#   HostName example.com
#   User username
#   Port 22
#   IdentityFile ~/.ssh/example_site_deploy
#   IdentitiesOnly yes
#   AddKeysToAgent yes
#   UseKeychain yes
SL_SSH_HOST="example-site"

# Absolute or shell-expanded path to the plugin directory on the server.
SL_SERVER_PATH='$HOME/public_html/wp-content/plugins/severino-labs-security-layer'

# Optional zip output path for review/upload testing.
SL_ZIP_OUTPUT="$HOME/Downloads/severino-labs-security-layer-review.zip"


# Pull latest main branch safely, but refuse to overwrite local work.
slpull() {
  cd "$SL_REPO" || return 1

  git fetch origin || return 1

  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "Local changes or untracked files detected. Nothing was pulled."
    git status --short
    echo ""
    echo "Next options:"
    echo '  slpush "commit message"        # commit/push/deploy current edits if on main'
    echo '  slbranch branch-name           # move current edits onto a new branch'
    echo "  git restore .                  # discard tracked edits"
    echo "  git clean -fd                  # remove untracked files"
    return 1
  fi

  git checkout main || return 1
  git pull --ff-only || return 1

  printf "\033[32m%s\033[0m\n" "Local repo is clean and up to date."
}


# Create a new branch from the current local state.
slbranch() {
  cd "$SL_REPO" || return 1

  if [ -z "$1" ]; then
    echo "Usage: slbranch branch-name"
    return 1
  fi

  git checkout -b "$1"
}


# Deploy the approved GitHub version to the live server.
# This sends one non-interactive SSH command and does not open a shell session.
deploy-sl() {
  echo "Deploying to server..."

  if ssh "$SL_SSH_HOST" "cd $SL_SERVER_PATH && git pull --ff-only"; then
    printf "\033[32m%s\033[0m\n" "Deployment successful."
  else
    printf "\033[31m%s\033[0m\n" "Deployment failed. Check server connection or Git status."
    return 1
  fi
}


# Commit, push, and deploy from main in one repeatable command.
slpush() {
  cd "$SL_REPO" || return 1

  if [ -z "$1" ]; then
    echo 'Usage: slpush "commit message"'
    return 1
  fi

  current_branch="$(git branch --show-current)"

  if [ "$current_branch" != "main" ]; then
    echo "slpush only deploys from main. Current branch: $current_branch"
    echo 'Use: git push -u origin '"$current_branch"''
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
  deploy-sl
}


# Revert the latest main commit, push the revert, and redeploy.
slrevert() {
  cd "$SL_REPO" || return 1

  current_branch="$(git branch --show-current)"

  if [ "$current_branch" != "main" ]; then
    echo "slrevert only runs from main. Current branch: $current_branch"
    return 1
  fi

  git fetch origin || return 1

  if ! git diff --quiet || ! git diff --cached --quiet || [ -n "$(git ls-files --others --exclude-standard)" ]; then
    echo "Local changes or untracked files detected. Commit, stash, or discard them before reverting."
    git status --short
    return 1
  fi

  git pull --ff-only || return 1

  echo "About to revert the latest commit:"
  git log -1 --oneline
  echo ""
  echo "Type YES to continue:"
  read confirm

  if [ "$confirm" != "YES" ]; then
    echo "Revert cancelled."
    return 1
  fi

  git revert --no-edit HEAD || return 1
  git push || return 1
  deploy-sl
}


# Quick local repo status helper.
slstatus() {
  cd "$SL_REPO" || return 1
  git status --short
  git branch --show-current
}


# Create a clean zip from the current Git commit.
# Uses git archive so ignored runtime files, vendor files, and local artifacts stay out.
slzip() {
  cd "$SL_REPO" || return 1

  git archive --format=zip --output "$SL_ZIP_OUTPUT" HEAD || return 1

  if [ -f "$SL_ZIP_OUTPUT" ]; then
    ls -lh "$SL_ZIP_OUTPUT"
    open -R "$SL_ZIP_OUTPUT" 2>/dev/null || true
  else
    echo "ZIP was not created."
    return 1
  fi
}
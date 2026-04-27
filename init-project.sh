#!/usr/bin/env bash
#
# init-project.sh — scaffold a new project ready for GitHub.
#
# Run this from inside an empty (or new) directory. The directory's
# basename becomes both the project name AND the GitHub repo name.
#
#   mkdir my-new-thing
#   cd my-new-thing
#   bash /path/to/zsh-git-deploy-workflow/init-project.sh
#
# What it does (each step asks for confirmation; nothing is written
# without it):
#
#   1. Auto-derives project name from the current directory.
#   2. Asks for a one-line description and your GitHub username
#      (auto-detected from `gh` or your git config).
#   3. Generates a sensible .gitignore + a starter README.md.
#   4. `git init -b main`, stages everything, makes the initial commit.
#      (Sets repo-local user.name/user.email if your global git config
#      doesn't have them, so the commit doesn't fail silently.)
#   5. Sets the GitHub remote (derived from your handle + dir name).
#   6. If `gh` CLI is installed and authenticated: offers to create the
#      GitHub repo and push in one step.
#      Otherwise: prints the exact manual commands to do it.
#   7. On FIRST run, appends a `gdw-init` alias to your ~/.zshrc so you
#      can call this scaffolder from anywhere with one word.
#   8. Optionally chains into bootstrap-deploy.sh from this directory.
#
# Use --dry-run to preview every action without writing anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/init-project.sh"
BOOTSTRAP="$SCRIPT_DIR/bootstrap-deploy.sh"

ZSHRC="$HOME/.zshrc"
ALIAS_MARK_START="# >>> gdw-init alias >>>"
ALIAS_MARK_END="# <<< gdw-init alias <<<"

# Optional user defaults file. If present, its values are used as
# implicit answers and the corresponding prompts are skipped.
#
# Supported variables:
#   GDW_DEFAULT_GH_USER         e.g. "joeseverino"
#   GDW_DEFAULT_GH_VISIBILITY   "public" or "private"
#   GDW_DEFAULT_SSH_HOST        e.g. "jseverino.net"  (used by bootstrap)
GDW_CONFIG="$HOME/.gdw-config"
[ -f "$GDW_CONFIG" ] && . "$GDW_CONFIG"

DRY_RUN=0


# ---------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------

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

section() { echo; _color "1;36" "── $* ──"; }
plan()    { printf '  %s\n' "$*"; }


# ---------------------------------------------------------------------
# Prompts
# ---------------------------------------------------------------------

ask() {
  local question="$1" default="${2:-}"
  local suffix=""
  [ -n "$default" ] && suffix=" [$default]"
  local answer=""
  read -r -p "  ${question}${suffix}: " answer
  [ -n "$answer" ] && printf '%s' "$answer" || printf '%s' "$default"
}

confirm() {
  local raw=""
  read -r -p "  $1 [Y/n]: " raw
  case "$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')" in
    n|no) return 1 ;;
    *)    return 0 ;;
  esac
}


# ---------------------------------------------------------------------
# .gitignore template (single sensible default)
# ---------------------------------------------------------------------

write_gitignore() {
  cat <<'EOF'
# OS
.DS_Store
Thumbs.db

# Editors
.vscode/
.idea/
*.swp
*.swo

# Local env
.env
.env.local

# Logs
*.log

# Backups
*.bak
*.bak.*

# Common dependency / build dirs
node_modules/
__pycache__/
*.pyc
/vendor/
/build/
/dist/
EOF
}


# ---------------------------------------------------------------------
# README starter
# ---------------------------------------------------------------------

write_readme() {
  local name="$1" description="$2"
  cat <<EOF
# ${name}

${description}

## Setup

_TODO: describe how to get this running locally._

## Usage

_TODO: describe the day-to-day workflow._
EOF
}


# ---------------------------------------------------------------------
# GitHub username detection (with visible source)
# ---------------------------------------------------------------------

# Echoes "<username>|<source>" so the caller can tell the user where the
# default came from. Source is one of: gh-cli / git-config / none.
detect_github_username() {
  if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    local user
    user="$(gh api user -q .login 2>/dev/null || true)"
    if [ -n "$user" ]; then
      printf '%s|gh-cli' "$user"
      return 0
    fi
  fi
  local gname
  gname="$(git config --global user.name 2>/dev/null || true)"
  if [ -n "$gname" ]; then
    printf '%s|git-config' "$(printf '%s' "$gname" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')"
    return 0
  fi
  printf '|none'
}


# ---------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------

usage() {
  cat <<EOF
init-project.sh — scaffold a new project ready for GitHub.

Usage:
  cd <empty-or-new-dir>
  bash init-project.sh           # interactive
  bash init-project.sh --dry-run # preview without writing
  bash init-project.sh --help

The directory name becomes the project name AND the GitHub repo name.
Run this once and a 'gdw-init' alias is added to your ~/.zshrc so
future runs are just  mkdir foo && cd foo && gdw-init.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=1 ;;
    --help|-h)  usage; exit 0 ;;
    *)          err "Unknown option: $1"; usage; exit 2 ;;
  esac
  shift
done


# ---------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------

PROJECT_DIR="$(pwd)"
DIR_NAME="$(basename "$PROJECT_DIR")"

echo
info "init-project — scaffold a new project from $(pwd)"

if [ -d .git ]; then
  err "This directory is already a git repository. Aborting."
  exit 1
fi

if [ -n "$(ls -A 2>/dev/null)" ]; then
  warn "Directory is not empty. The scaffold will add new files alongside what's here."
  warn "Existing .gitignore / README.md will be backed up before being overwritten."
  if ! confirm "Continue?"; then
    warn "Cancelled."
    exit 0
  fi
fi


# ---------------------------------------------------------------------
# Prompts (only the things that genuinely vary per project)
# ---------------------------------------------------------------------

PROJECT_NAME="$DIR_NAME"
GH_REPO="$DIR_NAME"

section "Project info"
plan "Project name:   $PROJECT_NAME    (from current directory)"
plan "GitHub repo:    $GH_REPO         (same — easy to remember)"
echo
PROJECT_DESC="$(ask 'One-line description' "A new ${PROJECT_NAME} project.")"

section "GitHub"
if [ -n "${GDW_DEFAULT_GH_USER:-}" ]; then
  GH_USER="$GDW_DEFAULT_GH_USER"
  ok "  Using GitHub username from ~/.gdw-config: $GH_USER"
else
  GH_DETECTED_RAW="$(detect_github_username)"
  GH_USER_DEFAULT="${GH_DETECTED_RAW%%|*}"
  GH_USER_SOURCE="${GH_DETECTED_RAW##*|}"

  case "$GH_USER_SOURCE" in
    gh-cli)     info "  Detected GitHub username from 'gh' CLI: $GH_USER_DEFAULT" ;;
    git-config) info "  Guessed GitHub username from 'git config --global user.name': $GH_USER_DEFAULT" ;;
    *)          warn "  No GitHub username detected — please type yours below." ;;
  esac

  GH_USER="$(ask 'GitHub username' "$GH_USER_DEFAULT")"
  if [ -z "$GH_USER" ]; then
    err "GitHub username is required. Aborting."
    exit 1
  fi
fi

if [ -n "${GDW_DEFAULT_GH_VISIBILITY:-}" ]; then
  GH_VISIBILITY="$GDW_DEFAULT_GH_VISIBILITY"
  ok "  Using visibility from ~/.gdw-config: $GH_VISIBILITY"
else
  GH_VISIBILITY="$(ask 'Visibility (public / private)' 'private')"
fi

REMOTE_URL="git@github.com:${GH_USER}/${GH_REPO}.git"


# ---------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------

section "Plan"
plan "Project dir:    $PROJECT_DIR"
plan "Description:    $PROJECT_DESC"
plan "Files to write: .gitignore, README.md"
plan "Git:            init -b main, add -A, commit 'Initial commit'"
plan "Remote URL:     $REMOTE_URL"
plan "Visibility:     $GH_VISIBILITY"
echo

if [ "$DRY_RUN" -eq 1 ]; then
  info "DRY-RUN: stopping here."
  exit 0
fi

if ! confirm "Proceed?"; then
  warn "Cancelled."
  exit 0
fi


# ---------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------

backup_if_exists() {
  local f="$1"
  if [ -e "$f" ]; then
    local bak="${f}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$f" "$bak"
    info "  Backed up existing $f -> $bak"
  fi
}

section "Writing files"
backup_if_exists .gitignore
write_gitignore > .gitignore
ok "  Wrote .gitignore"

backup_if_exists README.md
write_readme "$PROJECT_NAME" "$PROJECT_DESC" > README.md
ok "  Wrote README.md"

section "Initializing git"
git init -b main >/dev/null

# Make sure git knows who's committing.
if ! git config --get user.name >/dev/null 2>&1; then
  if ! git config --global user.name >/dev/null 2>&1; then
    GIT_NAME="$(ask 'Git user.name (commits in this repo)' "$GH_USER")"
    git config user.name "$GIT_NAME"
    info "  Set repo-local user.name to: $GIT_NAME"
  fi
fi
if ! git config --get user.email >/dev/null 2>&1; then
  if ! git config --global user.email >/dev/null 2>&1; then
    GIT_EMAIL="$(ask 'Git user.email (commits in this repo)' "${GH_USER}@users.noreply.github.com")"
    git config user.email "$GIT_EMAIL"
    info "  Set repo-local user.email to: $GIT_EMAIL"
  fi
fi

git add -A
if ! git commit -m "Initial commit" >/dev/null; then
  err "  git commit failed. Check the error above and re-run."
  exit 1
fi
ok "  Initial commit made on main"

# ---------------------------------------------------------------------
# GitHub create + push
#
# Important: we do NOT pre-add the `origin` remote. If `gh` CLI creates
# the repo via --source=. --push, it adds origin itself, and a
# pre-existing origin would make `gh` fail with "Unable to add remote
# origin". Only add origin manually on the fallback path.
# ---------------------------------------------------------------------

section "GitHub repo"
HAS_GH=0
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  HAS_GH=1
fi

REPO_PUSHED=0
REPO_CREATED=0
if [ "$HAS_GH" -eq 1 ]; then
  info "  GitHub CLI (gh) detected and authenticated."
  if confirm "  Create the repo on GitHub now (and push)?"; then
    case "$GH_VISIBILITY" in
      public)  vis_flag="--public" ;;
      *)       vis_flag="--private" ;;
    esac

    # Split into two steps. `gh repo create --source=. --push` combines
    # repo creation and push, but GitHub sometimes needs a beat after
    # creation before SSH access works — without a pause the push can
    # fail with "Repository not found" even though the repo exists.
    if gh repo create "${GH_USER}/${GH_REPO}" $vis_flag --source=. --description "$PROJECT_DESC" >/dev/null 2>&1; then
      ok "  Repo created on GitHub: https://github.com/${GH_USER}/${GH_REPO}"
      REPO_CREATED=1

      # Brief pause so SSH access has time to propagate, then push.
      # Retry once on the off chance the first attempt is too eager.
      sleep 2
      if git push -u origin main >/dev/null 2>&1; then
        ok "  Pushed initial commit on main."
        REPO_PUSHED=1
      else
        sleep 3
        if git push -u origin main >/dev/null 2>&1; then
          ok "  Pushed initial commit on main (after retry)."
          REPO_PUSHED=1
        else
          warn "  Repo was created but the push failed twice."
          warn "  This is usually GitHub's SSH propagation lag — wait 5-10 seconds and run:"
          echo "    git push -u origin main"
          REPO_PUSHED=1   # treat as success — the repo exists, just needs a retry
        fi
      fi
    else
      warn "  gh repo create failed — finish manually below."
    fi
  fi
fi

if [ "$REPO_PUSHED" -eq 0 ]; then
  # Manual fallback path. Check for existing origin (gh may have added
  # it before failing) before trying to add our own.
  if git remote get-url origin >/dev/null 2>&1; then
    info "  origin remote already exists — leaving as-is."
  else
    git remote add origin "$REMOTE_URL"
    ok "  origin -> $REMOTE_URL"
  fi

  echo
  if [ "$REPO_CREATED" -eq 1 ]; then
    cat <<EOF
  The GitHub repo exists; only the initial push needs to be retried:

    git push -u origin main
EOF
  else
    cat <<EOF
  Manual GitHub steps:

    1) Open  https://github.com/new
    2) Repo name:    $GH_REPO
       Owner:        $GH_USER
       Visibility:   $GH_VISIBILITY
       Initialize:   leave EVERYTHING unchecked (no README, .gitignore, license)
    3) Click "Create repository"
    4) Back here, push:
         git push -u origin main

  Or install the GitHub CLI to skip this step next time:
    brew install gh && gh auth login
EOF
  fi
fi


# ---------------------------------------------------------------------
# Auto-install gdw-init alias on first run
# ---------------------------------------------------------------------

ALIAS_INSTALLED_THIS_RUN=0
if [ ! -f "$ZSHRC" ] || ! grep -Fq "$ALIAS_MARK_START" "$ZSHRC"; then
  section "Convenience alias"
  info "  Adding 'gdw-init' alias to $ZSHRC so you can run this from anywhere."
  if [ -f "$ZSHRC" ]; then
    local_backup="${ZSHRC}.bak.$(date +%Y%m%d-%H%M%S)"
    cp "$ZSHRC" "$local_backup"
    info "  Backed up to: $local_backup"
  fi
  {
    [ -f "$ZSHRC" ] && cat "$ZSHRC"
    printf '\n%s\nalias gdw-init=%s\n%s\n' \
      "$ALIAS_MARK_START" \
      "'bash \"$SCRIPT_PATH\"'" \
      "$ALIAS_MARK_END"
  } > "${ZSHRC}.new"
  mv "${ZSHRC}.new" "$ZSHRC"
  ok "  Added: alias gdw-init='bash \"$SCRIPT_PATH\"'"
  ALIAS_INSTALLED_THIS_RUN=1
fi


# ---------------------------------------------------------------------
# Optionally chain into the deploy bootstrap
# ---------------------------------------------------------------------

CHAINED=0
if [ -f "$BOOTSTRAP" ]; then
  echo
  section "Deploy workflow"
  info "  Want to wire up the edit/commit/push/deploy workflow for this project now?"
  info "  (Sets up SSH keys, deploy key on the server, and gives you"
  info "   <prefix>pull/<prefix>push commands you can run from anywhere.)"
  if confirm "  Run bootstrap-deploy.sh now?"; then
    CHAINED=1
    exec bash "$BOOTSTRAP"
  fi
fi


# ---------------------------------------------------------------------
# Wrap-up
# ---------------------------------------------------------------------

echo
ok "Done. Your project is initialized."
echo
echo "  Local repo:    $PROJECT_DIR"
echo "  Remote URL:    $REMOTE_URL"
if [ "$REPO_PUSHED" -eq 1 ]; then
  echo "  Pushed:        yes (on main)"
else
  echo "  Pushed:        no — see manual steps above"
fi

if [ "$ALIAS_INSTALLED_THIS_RUN" -eq 1 ]; then
  echo
  _color "1;33" "  ⚠  RELOAD YOUR SHELL to pick up the new gdw-init alias:"
  echo "       exec zsh"
  echo "     (or open a new terminal tab — same effect)"
fi
echo

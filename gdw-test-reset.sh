#!/usr/bin/env bash
#
# gdw-test-reset.sh — wipe everything gdw-init + bootstrap-deploy.sh created
#                     so you can run a clean test scenario from scratch.
#
# Usage:
#   bash gdw-test-reset.sh                    # interactive — asks for prefix
#   bash gdw-test-reset.sh --prefix theme     # skip the prefix prompt
#   bash gdw-test-reset.sh --prefix theme --project-dir ~/Code/theme
#   bash gdw-test-reset.sh --all-aliases      # also strip gdw-init / gdw-bootstrap aliases
#
# What it removes:
#   ~/.zshrc          — strips the <prefix> workflow source block
#   ~/.ssh/config     — strips the <prefix> deploy hosts block
#   ~/.<prefix>-workflow.zsh          — per-project workflow file
#   ~/.git-deploy-lib.zsh             — shared library (asks first)
#   ~/.ssh/id_ed25519[.pub]           — default GitHub SSH key (asks first)
#   ~/.ssh/<prefix>_server[.pub]      — server SSH key if present
#   <project-dir>                     — local project folder (asks first)
#   GitHub repo                       — deletes via gh if confirmed
#   gdw-init alias block in ~/.zshrc  — only with --all-aliases
#   gdw-bootstrap alias block         — only with --all-aliases
#
# Nothing is deleted without asking (unless you say Y to everything).
# No backups — this script is meant to be destructive. That's the point.

set -euo pipefail

# ── helpers ──────────────────────────────────────────────────────────────────

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
cyan()  { printf '\033[36m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

ask_yn() {
  # ask_yn "Question" → returns 0 for yes, 1 for no
  local answer
  printf '  %s [y/N]: ' "$1"
  read -r answer
  case "$(printf '%s' "${answer:-n}" | tr '[:upper:]' '[:lower:]')" in
    y|yes) return 0 ;;
    *)     return 1 ;;
  esac
}

strip_block() {
  # strip_block <file> <start-marker> <end-marker>
  local file="$1" start="$2" end="$3"
  [ -f "$file" ] || return 0
  local tmp
  tmp="$(mktemp)"
  awk -v s="$start" -v e="$end" '
    $0 == s { skip=1; next }
    skip && $0 == e { skip=0; next }
    !skip { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

removed() { green "  ✓ removed: $*"; }
skipped() { dim   "  – skipped: $*"; }
missing() { dim   "  – not found: $*"; }

# ── args ─────────────────────────────────────────────────────────────────────

PREFIX=""
PROJECT_DIR=""
ALL_ALIASES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --prefix)       shift; PREFIX="${1:-}" ;;
    --project-dir)  shift; PROJECT_DIR="${1:-}" ;;
    --all-aliases)  ALL_ALIASES=1 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

# ── intro ────────────────────────────────────────────────────────────────────

echo
bold "gdw-test-reset.sh"
cyan "  Wipes everything gdw-init + bootstrap-deploy created for one prefix."
echo "  Nothing is deleted without a confirmation prompt."
echo

# ── prefix ───────────────────────────────────────────────────────────────────

if [ -z "$PREFIX" ]; then
  printf '  Prefix to reset (e.g. testproject): '
  read -r PREFIX
fi

if [ -z "$PREFIX" ]; then
  red "Prefix is required. Aborting."
  exit 1
fi

echo
bold "  Resetting prefix: $PREFIX"
echo

# ── markers (must match bootstrap-deploy.sh constants) ───────────────────────

ZSHRC="$HOME/.zshrc"
SSH_CONFIG="$HOME/.ssh/config"
WORKFLOW_FILE="$HOME/.${PREFIX}-workflow.zsh"
SERVER_KEY="$HOME/.ssh/${PREFIX}_server"
GITHUB_KEY="$HOME/.ssh/id_ed25519"
LIB="$HOME/.git-deploy-lib.zsh"

ZSHRC_START="# >>> ${PREFIX} git deploy workflow >>>"
ZSHRC_END="# <<< ${PREFIX} git deploy workflow <<<"
SSH_START="# >>> ${PREFIX} deploy hosts >>>"
SSH_END="# <<< ${PREFIX} deploy hosts <<<"

BOOTSTRAP_ALIAS_START="# >>> gdw-bootstrap alias >>>"
BOOTSTRAP_ALIAS_END="# <<< gdw-bootstrap alias <<<"
INIT_ALIAS_START="# >>> gdw-init alias >>>"
INIT_ALIAS_END="# <<< gdw-init alias <<<"

# ── ~/.zshrc: workflow block ──────────────────────────────────────────────────

if [ -f "$ZSHRC" ] && grep -Fq "$ZSHRC_START" "$ZSHRC"; then
  if ask_yn "Strip $PREFIX workflow block from ~/.zshrc?"; then
    strip_block "$ZSHRC" "$ZSHRC_START" "$ZSHRC_END"
    removed "~/.zshrc ($PREFIX workflow block)"
  else
    skipped "~/.zshrc workflow block"
  fi
else
  missing "~/.zshrc ($PREFIX workflow block)"
fi

# ── ~/.ssh/config: deploy hosts block ────────────────────────────────────────

if [ -f "$SSH_CONFIG" ] && grep -Fq "$SSH_START" "$SSH_CONFIG"; then
  if ask_yn "Strip $PREFIX deploy hosts block from ~/.ssh/config?"; then
    strip_block "$SSH_CONFIG" "$SSH_START" "$SSH_END"
    removed "~/.ssh/config ($PREFIX deploy hosts block)"
  else
    skipped "~/.ssh/config block"
  fi
else
  missing "~/.ssh/config ($PREFIX deploy hosts block)"
fi

# ── per-project workflow file ────────────────────────────────────────────────

if [ -f "$WORKFLOW_FILE" ]; then
  if ask_yn "Delete $WORKFLOW_FILE?"; then
    rm -f "$WORKFLOW_FILE"
    removed "$WORKFLOW_FILE"
  else
    skipped "$WORKFLOW_FILE"
  fi
else
  missing "$WORKFLOW_FILE"
fi

# ── server SSH key ────────────────────────────────────────────────────────────

if [ -f "$SERVER_KEY" ] || [ -f "${SERVER_KEY}.pub" ]; then
  if ask_yn "Delete server SSH key $SERVER_KEY[.pub]?"; then
    rm -f "$SERVER_KEY" "${SERVER_KEY}.pub"
    removed "$SERVER_KEY[.pub]"
  else
    skipped "$SERVER_KEY"
  fi
else
  missing "$SERVER_KEY (no server key found)"
fi

# ── GitHub SSH key (shared — ask carefully) ───────────────────────────────────

if [ -f "$GITHUB_KEY" ] || [ -f "${GITHUB_KEY}.pub" ]; then
  echo
  cyan "  Note: $GITHUB_KEY is the default GitHub SSH key."
  cyan "  Only delete it if you want a completely fresh key on the next run."
  if ask_yn "Delete $GITHUB_KEY[.pub]?"; then
    # Also remove from ssh-agent so a cached key can't ghost-authenticate
    # after the file is gone (ssh-agent holds keys in memory across reboots).
    if command -v ssh-add >/dev/null 2>&1; then
      ssh-add -d "$GITHUB_KEY" >/dev/null 2>&1 || true
    fi
    rm -f "$GITHUB_KEY" "${GITHUB_KEY}.pub"
    removed "$GITHUB_KEY[.pub] (also removed from ssh-agent if present)"
  else
    skipped "$GITHUB_KEY"
  fi
  echo
else
  missing "$GITHUB_KEY"
fi

# ── shared library ────────────────────────────────────────────────────────────

if [ -f "$LIB" ]; then
  if ask_yn "Delete shared library $LIB?"; then
    rm -f "$LIB"
    removed "$LIB"
  else
    skipped "$LIB"
  fi
else
  missing "$LIB"
fi

# ── gdw-init / gdw-bootstrap aliases (optional) ──────────────────────────────

if [ "$ALL_ALIASES" -eq 1 ] && [ -f "$ZSHRC" ]; then
  if grep -Fq "$BOOTSTRAP_ALIAS_START" "$ZSHRC"; then
    strip_block "$ZSHRC" "$BOOTSTRAP_ALIAS_START" "$BOOTSTRAP_ALIAS_END"
    removed "~/.zshrc (gdw-bootstrap alias)"
  else
    missing "~/.zshrc (gdw-bootstrap alias)"
  fi
  if grep -Fq "$INIT_ALIAS_START" "$ZSHRC"; then
    strip_block "$ZSHRC" "$INIT_ALIAS_START" "$INIT_ALIAS_END"
    removed "~/.zshrc (gdw-init alias)"
  else
    missing "~/.zshrc (gdw-init alias)"
  fi
fi

# ── local project directory ───────────────────────────────────────────────────

if [ -z "$PROJECT_DIR" ]; then
  echo
  printf '  Local project directory to delete (leave blank to skip): '
  read -r PROJECT_DIR
fi

if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  if ask_yn "Delete local project directory $PROJECT_DIR?"; then
    rm -rf "$PROJECT_DIR"
    removed "$PROJECT_DIR"
  else
    skipped "$PROJECT_DIR"
  fi
elif [ -n "$PROJECT_DIR" ]; then
  missing "$PROJECT_DIR (directory not found)"
fi

# ── GitHub repo ───────────────────────────────────────────────────────────────

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  echo
  GH_USER="$(gh api user --jq '.login' 2>/dev/null || true)"
  if [ -n "$GH_USER" ]; then
    REPO_GUESS="${GH_USER}/${PREFIX}"
    printf '  GitHub repo to delete [%s] (leave blank to skip): ' "$REPO_GUESS"
    read -r REPO_INPUT
    REPO="${REPO_INPUT:-$REPO_GUESS}"
    if [ -n "$REPO" ]; then
      if ask_yn "Delete GitHub repo $REPO? (PERMANENT)"; then
        if gh repo delete "$REPO" --yes 2>/dev/null; then
          removed "GitHub repo: $REPO"
        else
          red "  Could not delete $REPO — may not exist or you may lack permission."
        fi
      else
        skipped "GitHub repo $REPO"
      fi
    fi
  fi
else
  dim "  gh not available or not signed in — skipping GitHub repo deletion."
fi

# ── done ─────────────────────────────────────────────────────────────────────

echo
green "Reset complete. Run 'exec zsh' to reload your shell, then retest."
echo

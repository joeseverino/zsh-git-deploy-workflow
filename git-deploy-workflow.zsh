# ============================================================
# Per-project workflow file
#
# This file is intentionally tiny. All the workflow logic lives in
# git-deploy-lib.zsh (a shared library at ~/.git-deploy-lib.zsh),
# which is sourced once and reused across every project you bootstrap.
# This file just sets the project-specific context and defines thin
# command wrappers around the library functions.
#
# Multiple projects can each have their own copy of this file with
# different prefixes; they all share the same underlying logic.
# ============================================================

# Where the shared library lives. The bootstrap copies it here.
GDW_LIB_PATH="${GDW_LIB_PATH:-$HOME/.git-deploy-lib.zsh}"

# Source the shared library if it isn't already loaded in this shell.
#
# Fallback path uses ${(%):-%N} (the Zsh prompt-expansion form for the
# current script's name) instead of $0. In sourced files, $0 is the
# parent shell's $0, not the file path you'd expect — %N reliably
# expands to the sourced file even when called from .zshrc.
if ! typeset -f _gdw_pull >/dev/null 2>&1; then
  if [ -f "$GDW_LIB_PATH" ]; then
    source "$GDW_LIB_PATH"
  else
    GDW_WORKFLOW_DIR="${${(%):-%N}:A:h}"
    source "$GDW_WORKFLOW_DIR/git-deploy-lib.zsh"
  fi
fi


# ------------------------------------------------------------
# Project context — set whenever a wrapper is invoked.
# ------------------------------------------------------------

_ship_ctx() {
  GDW_PREFIX="ship"
  GDW_LABEL="Your Project"
  GDW_REPO="$HOME/path/to/your-project"
  GDW_SSH_HOST="example-host"
  GDW_SERVER_PATH='$HOME/path/to/your-project'
  GDW_ZIP_OUTPUT="$HOME/Downloads/your-project-review.zip"

  # Optional. Set this when the server uses a repo-specific SSH alias
  # (e.g. github-yourproject) for its read-only deploy key. The alias
  # lives in the SERVER's ~/.ssh/config, not yours. If empty, the
  # deploy step uses the local repo's `remote.origin.url` instead.
  GDW_SERVER_REMOTE=""
}


# ------------------------------------------------------------
# Wrappers — each calls into the shared library with our context.
# ------------------------------------------------------------

shippull()    { _ship_ctx; _gdw_pull "$@"; }
shipbranch()  { _ship_ctx; _gdw_branch "$@"; }
shippush()    { _ship_ctx; _gdw_push "$@"; }
shiprevert()  { _ship_ctx; _gdw_revert "$@"; }
shipstatus()  { _ship_ctx; _gdw_status "$@"; }
shipzip()     { _ship_ctx; _gdw_zip "$@"; }
shiphelp()    { _ship_ctx; _gdw_help "$@"; }
deploy-ship() { _ship_ctx; _gdw_deploy "$@"; }

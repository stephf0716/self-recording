#!/bin/bash
# setup-history.sh -- give a vault version history without putting .git inside it.
#
#   bash setup-history.sh [/path/to/vault]
#
# Defaults to the parent of this script's directory, so once copied to
# <vault>/_tools/ it needs no arguments.
#
# Creates:
#   $HOME/<vault-name>-history.git   the git dir, OUTSIDE any cloud-synced folder
#   core.worktree                    pointing back at the vault
#   <vault>/_tools/vgit              wrapper, since plain git cannot find the repo
#   <vault>/.gitattributes           line-ending normalization (if absent)
#   <vault>/.gitignore               minimal sane defaults (if absent)
#
# WHY detached: a sync client (Dropbox/OneDrive/iCloud) writing git's index or
# object store, from two machines, can corrupt the repo. Keeping the git dir
# outside the synced tree removes that risk entirely, and leaves the vault free of
# tooling artifacts so it stays portable to any editor or AI client.
#
# Override the location with VAULT_GIT_DIR if you want it elsewhere.
#
# Idempotent: reports and changes nothing if the git dir already exists.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="${1:-$(dirname "$SCRIPT_DIR")}"
VAULT="$(cd "$VAULT" && pwd)" || { echo "ERROR: no such directory: $1" >&2; exit 1; }
VAULT_NAME="$(basename "$VAULT")"
GIT_DIR_PATH="${VAULT_GIT_DIR:-$HOME/${VAULT_NAME}-history.git}"

echo "Vault:   $VAULT"
echo "Git dir: $GIT_DIR_PATH"
echo

command -v git >/dev/null 2>&1 || {
  echo "ERROR: git not found on PATH." >&2
  echo "  Windows: install Git for Windows, then re-run this in Git Bash." >&2
  exit 1; }

if [ -d "$GIT_DIR_PATH" ]; then
  echo "Already set up. Nothing changed."
  git --git-dir="$GIT_DIR_PATH" log --oneline 2>/dev/null | head -3
  exit 0
fi

if [ -d "$VAULT/.git" ]; then
  echo "NOTE: $VAULT already contains a .git directory."
  echo "      If this folder is NOT cloud-synced, a normal git repo is simpler and"
  echo "      better -- you do not need this script. If it IS cloud-synced, migrate"
  echo "      deliberately rather than running both."
  exit 1
fi

# ---- line endings ---------------------------------------------------------
# Without this, an editor that saves LF will rewrite every CRLF file and produce
# whole-file diffs containing no actual change.
if [ ! -f "$VAULT/.gitattributes" ]; then
  cat > "$VAULT/.gitattributes" <<'EOF'
# Default: store every file byte-exact. Protects binaries.
* -text

# Markdown: normalize to LF on the way into git, so an editor saving LF (Obsidian
# does) never produces a diff containing no real change.
*.md text eol=lf
EOF
  echo "[+] .gitattributes"
fi

if [ ! -f "$VAULT/.gitignore" ]; then
  cat > "$VAULT/.gitignore" <<'EOF'
.DS_Store
Thumbs.db

# Obsidian per-machine UI state; churns on every pane move.
# Real settings (app.json, appearance.json) ARE tracked.
.obsidian/workspace.json
.obsidian/workspace-mobile.json

__pycache__/
*.pyc

# Add large binary trees here. NOTE: anything ignored is NOT recoverable from
# history -- snapshot it elsewhere before any cleanup.
EOF
  echo "[+] .gitignore"
fi

# ---- the wrapper ---------------------------------------------------------
mkdir -p "$VAULT/_tools"
if [ ! -f "$VAULT/_tools/vgit" ]; then
  cat > "$VAULT/_tools/vgit" <<EOF
#!/bin/bash
# vgit -- git for this vault.
#
# There is NO .git directory here. History lives in a detached git dir outside any
# cloud-synced folder, so the sync client can never corrupt git's index or object
# store. core.worktree points back at the vault, so this works from any directory.
#
#   _tools/vgit status
#   _tools/vgit log --oneline
#   _tools/vgit add -A && _tools/vgit commit -m "..."
#
# Optional alias for ~/.bashrc or ~/.zshrc:
#   alias vgit='git --git-dir="\\\$HOME/${VAULT_NAME}-history.git"'

set -eu
GIT_DIR_PATH="\${VAULT_GIT_DIR:-\$HOME/${VAULT_NAME}-history.git}"
if [ ! -d "\$GIT_DIR_PATH" ]; then
  echo "vgit: no git dir at \$GIT_DIR_PATH" >&2
  echo "vgit: run  bash _tools/setup-history.sh" >&2
  exit 1
fi
exec git --git-dir="\$GIT_DIR_PATH" "\$@"
EOF
  chmod +x "$VAULT/_tools/vgit"
  echo "[+] _tools/vgit"
fi

# ---- the repo ------------------------------------------------------------
mkdir -p "$(dirname "$GIT_DIR_PATH")" || exit 1
git init --bare -b main "$GIT_DIR_PATH" >/dev/null 2>&1 \
  || git init --bare "$GIT_DIR_PATH" >/dev/null || exit 1

g() { git --git-dir="$GIT_DIR_PATH" "$@"; }

g config core.bare false
g config core.worktree "$VAULT"
# .gitattributes decides line endings, not a global flag.
g config core.autocrlf false
g config core.safecrlf false

# Reuse the person's global identity rather than inventing one.
NAME="$(git config --global user.name  2>/dev/null || true)"
MAIL="$(git config --global user.email 2>/dev/null || true)"
[ -n "$NAME" ] && g config user.name  "$NAME"
[ -n "$MAIL" ] && g config user.email "$MAIL"
if [ -z "$NAME" ] || [ -z "$MAIL" ]; then
  echo
  echo "NOTE: no global git identity found. Set one, or commits will fail:"
  echo "  git --git-dir=\"$GIT_DIR_PATH\" config user.name  \"Your Name\""
  echo "  git --git-dir=\"$GIT_DIR_PATH\" config user.email \"you@example.com\""
fi

g add -A
g commit -q -m "Baseline on this machine

First commit of $VAULT_NAME from this machine. History lives at
$GIT_DIR_PATH -- outside the synced folder, so git internals never sync." \
  >/dev/null 2>&1 || true
g branch -M main 2>/dev/null

echo
echo "Done."
g log --oneline | head -3
cat <<EOF

  bash "$VAULT/_tools/vgit" status
  bash "$VAULT/_tools/vgit" log --oneline

NOTE: this history is local to THIS machine. Another machine editing the same
synced vault keeps its own separate history. The FILES sync; the commit logs do
not. Memory is complete everywhere; only undo granularity is per-machine.
EOF

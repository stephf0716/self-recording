#!/bin/bash
# dream-commit.sh -- commit boundary for the nightly consolidation ("dream") job.
#
#   bash dream-commit.sh begin /path/to/vault
#   bash dream-commit.sh end   /path/to/vault
#
# Install machine-locally as $HERMES_HOME/scripts/dream-commit.sh -- NOT in the
# vault's _tools/. Hermes cron refuses scripts on cloud-synced paths, including
# local wrappers that call into them (reference/pitfalls.md 4d), so this file is
# self-contained: git and POSIX tools only, nothing sourced from the vault.
# The vault path may also come from DREAM_VAULT.
#
#   begin  commits drift already in the vault as "pre-dream:", so tonight's
#          commit holds only the job's own changes, and records where the run
#          started. Exits non-zero with no history -- unlike the hooks, the dream
#          must not edit anything that cannot be reverted.
#   end    makes the one commit for the run, "dream: YYYY-MM-DD" (the date the
#          run began), and warns if any other commit landed mid-run, because then
#          a single revert no longer undoes the whole night.
#
# begin also copies the harness memory files (default $HERMES_HOME/memories, or
# DREAM_MEMORIES for a profile) to <that dir>/.dream-backup/YYYY-MM-DD-HHMMSS/,
# one directory per run so a same-day retry never overwrites the snapshot from
# before a bad rebuild, keeping the last 7 runs. They live outside the vault and
# its history, and the job rebuilds them, so this copy is their only undo.
#
# History: detached at $HOME/<vault>-history.git (or VAULT_GIT_DIR), or a plain
# .git inside the vault. Same default as hook-autocommit.sh.

set -u

MODE="${1:-}"
VAULT="${2:-${DREAM_VAULT:-}}"
case "$MODE" in begin|end) ;; *) echo "usage: dream-commit.sh begin|end /path/to/vault" >&2; exit 2 ;; esac
[ -n "$VAULT" ] || { echo "dream-commit: no vault path (argument or DREAM_VAULT)" >&2; exit 2; }
VAULT="$(cd "$VAULT" 2>/dev/null && pwd)" || { echo "dream-commit: no such vault: $VAULT" >&2; exit 1; }

if [ -d "$VAULT/.git" ]; then
  GIT_DIR_PATH="$VAULT/.git"
else
  GIT_DIR_PATH="${VAULT_GIT_DIR:-$HOME/$(basename "$VAULT")-history.git}"
fi
[ -d "$GIT_DIR_PATH" ] || {
  echo "dream-commit: no version history at $GIT_DIR_PATH -- stop; do not edit the vault." >&2
  exit 1; }

g() { git --git-dir="$GIT_DIR_PATH" --work-tree="$VAULT" "$@"; }
STATE="$GIT_DIR_PATH/dream-run"   # per-machine, never synced
dirty_count() { g status --porcelain -uall | grep -c .; }

if [ "$MODE" = "begin" ]; then
  if [ -f "$STATE" ]; then
    echo "dream-commit: warning: previous run never reached 'end' ($(cat "$STATE")); starting over." >&2
  fi
  n="$(dirty_count)"
  if [ "$n" -gt 0 ]; then
    g add -A && g commit -q -m "pre-dream: $n file(s) changed" \
      -m "Drift already in the vault when the nightly dream job started, committed separately so the dream commit holds only the job's changes." \
      || { echo "dream-commit: could not commit existing changes -- stop." >&2; exit 1; }
  fi
  MEM="${DREAM_MEMORIES:-${HERMES_HOME:-$HOME/.hermes}/memories}"
  if [ -d "$MEM" ]; then
    b="$MEM/.dream-backup/$(date '+%Y-%m-%d-%H%M%S')"
    mkdir -p "$b" && cp -p "$MEM"/*.md "$b"/ 2>/dev/null
    ls -1d "$MEM"/.dream-backup/*/ 2>/dev/null | sort | awk '{ a[NR] = $0 } END { for (i = 1; i <= NR - 7; i++) print a[i] }' | while IFS= read -r old; do rm -rf "$old"; done
    echo "backup: $b"
  fi
  head="$(g rev-parse HEAD 2>/dev/null)" || { echo "dream-commit: history has no commits -- stop." >&2; exit 1; }
  printf '%s %s\n' "$head" "$(date '+%Y-%m-%d')" > "$STATE"
  echo "begin: $(g log -1 --format=%h) (run date $(date '+%Y-%m-%d'))"
  exit 0
fi

# ---- end -----------------------------------------------------------------
start=""; day="$(date '+%Y-%m-%d')"
if [ -f "$STATE" ]; then
  read -r start day < "$STATE"
else
  echo "dream-commit: warning: no 'begin' recorded; committing anyway." >&2
fi

# Commits since begin that are not ours: a sweep or hook fired mid-run. Checked
# even when the tree is clean -- a sweep may have captured every write.
others=0
[ -n "$start" ] && others="$(g rev-list --count "$start..HEAD" 2>/dev/null || echo 0)"
warn_others() {
  [ "$others" -gt 0 ] || return 0
  echo "dream-commit: warning: $others other commit(s) landed during the run (a sweep or hook);" >&2
  echo "              part of tonight's work may be in them. Full undo: revert $(g rev-parse --short "$start")..HEAD" >&2
}

n="$(dirty_count)"
if [ "$n" -eq 0 ]; then
  echo "end: nothing to commit"
  warn_others
  rm -f "$STATE"
  exit 0
fi

g add -A
g commit -q -m "dream: $day" \
  -m "Nightly consolidation, $n file(s): journal entries appended from recent sessions, superseded markers, regenerated Current state blocks, and the run log in _agent/sessions/. Revert this one commit to undo the night (the harness memory files live outside the vault; begin backed them up under memories/.dream-backup/)." \
  || { echo "dream-commit: commit failed" >&2; exit 1; }

warn_others
rm -f "$STATE"
h="$(g log -1 --format=%h)"
echo "end: $h dream: $day"
echo "undo: revert $h"
exit 0

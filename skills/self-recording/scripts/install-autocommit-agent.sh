#!/bin/bash
# install-autocommit-agent.sh -- install a launchd timer that commits vault drift.
#
# Why: some AI clients are sandboxed to the vault folder. They can write inside
# the vault but are denied writes anywhere else on disk -- including the detached
# git dir, which is outside the vault BY DESIGN (so cloud sync never touches it).
# Such a client can edit the vault but cannot commit, and nothing it does is
# revertible until something else commits. Claude Code's hooks do that for Claude
# Code sessions only. This timer covers every other writer: sandboxed clients,
# Obsidian, cloud sync arriving from another machine, hand edits.
#
# The concrete case that produced this: Osaurus (macOS) in trusted-folder mode.
# `vgit log` works from inside the session; `vgit commit` fails with
# "Operation not permitted".
#
# What it installs: ~/Library/LaunchAgents/<label>.plist, running
# `hook-autocommit.sh sweep` every 120 s. The hook is a no-op on a clean tree, so
# the steady-state cost is one `git status`.
#
# Run this FROM A TERMINAL, as yourself. It cannot run from inside a sandboxed
# session -- writing to ~/Library/LaunchAgents is exactly the kind of write that
# is denied there. Idempotent: re-running replaces the agent.
#
#   bash _tools/install-autocommit-agent.sh            # install / reinstall
#   bash _tools/install-autocommit-agent.sh --uninstall
#   bash _tools/install-autocommit-agent.sh --status
#
# macOS only. On Windows the equivalent is a Task Scheduler job calling
# `bash _tools/hook-autocommit.sh sweep` -- not provided here.
#
# Paths derive from this script's location and the vault name; nothing is
# hardcoded. Override the git dir with VAULT_GIT_DIR, matching setup-history.sh.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="$(dirname "$SCRIPT_DIR")"
VAULT_NAME="$(basename "$VAULT")"
GIT_DIR_PATH="${VAULT_GIT_DIR:-$HOME/${VAULT_NAME}-history.git}"

# launchd labels are reverse-DNS by convention; the vault name is sanitized to
# [A-Za-z0-9-] so odd characters in a folder name cannot break the plist.
SAFE_NAME="$(printf '%s' "$VAULT_NAME" | tr -c 'A-Za-z0-9-' '-' | sed 's/-*$//')"
LABEL="local.${USER:-vault}.${SAFE_NAME}-autocommit"
TEMPLATE="$SCRIPT_DIR/launchd/autocommit.plist.template"
DEST_DIR="$HOME/Library/LaunchAgents"
DEST="$DEST_DIR/$LABEL.plist"
LOG="$(dirname "$GIT_DIR_PATH")/${SAFE_NAME}-autocommit.log"
DOMAIN="gui/$(id -u)"

if [ "$(uname)" != "Darwin" ]; then
  echo "This installer is macOS-only (launchd)." >&2
  exit 1
fi

fda_hint() {
  cat <<EOF

*** launchd job is loaded but cannot read the vault (Operation not permitted).
    This is macOS Full Disk Access, not a script bug. Terminal has your consent
    to read protected folders (iCloud Drive, ~/Library/CloudStorage, Desktop,
    Documents); a launchd job running /bin/bash does not. One-time fix:

    1. System Settings -> Privacy & Security -> Full Disk Access
    2. Click "+", press Cmd-Shift-G, type  /bin/bash  , Open, make sure it is ON
    3. Back here:  launchctl kickstart -k $DOMAIN/$LABEL
    4. Check:      bash _tools/install-autocommit-agent.sh --status

    Trade-off: any launchd/cron job that runs bash gets the same access. To stay
    narrow, copy /bin/bash to a private path, grant FDA to that copy, and change
    ProgramArguments[0] in the template -- untested, offered as an option.
EOF
}

case "${1:-}" in
  --status)
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
      echo "installed and loaded: $DEST"
      launchctl print "$DOMAIN/$LABEL" | grep -E 'state|last exit|run interval' | sed 's/^/  /'
    elif [ -f "$DEST" ]; then
      echo "plist present but not loaded: $DEST"
      exit 1
    else
      echo "not installed (label $LABEL)"
      exit 1
    fi
    echo "recent log ($LOG):"
    tail -n 5 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
    if tail -n 5 "$LOG" 2>/dev/null | grep -q "Operation not permitted"; then
      fda_hint
      exit 1
    fi
    exit 0
    ;;
  --uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null
    rm -f "$DEST"
    echo "removed $LABEL"
    exit 0
    ;;
  "") ;;
  *) echo "usage: $0 [--status|--uninstall]" >&2; exit 1 ;;
esac

[ -f "$TEMPLATE" ] || { echo "missing template: $TEMPLATE" >&2; exit 1; }
[ -f "$SCRIPT_DIR/hook-autocommit.sh" ] || { echo "missing hook-autocommit.sh" >&2; exit 1; }
[ -d "$GIT_DIR_PATH" ] || {
  echo "no git dir at $GIT_DIR_PATH -- run bash _tools/setup-history.sh first" >&2; exit 1; }

mkdir -p "$DEST_DIR" || { echo "cannot write $DEST_DIR (are you inside a sandboxed session? run from Terminal)" >&2; exit 1; }

# Unload any previous copy before overwriting.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null

# Render. '|' is the sed delimiter; refuse paths that contain it.
case "$VAULT$HOME$LOG$LABEL" in
  *'|'*) echo "ERROR: a path contains '|', which the template renderer cannot handle." >&2; exit 1 ;;
esac
sed -e "s|__LABEL__|$LABEL|g" -e "s|__VAULT__|$VAULT|g" -e "s|__HOME__|$HOME|g" -e "s|__LOG__|$LOG|g" \
  "$TEMPLATE" > "$DEST" || exit 1
plutil -lint "$DEST" >/dev/null || { echo "rendered plist is invalid" >&2; exit 1; }

launchctl bootstrap "$DOMAIN" "$DEST" || { echo "launchctl bootstrap failed" >&2; exit 1; }
launchctl kickstart "$DOMAIN/$LABEL" 2>/dev/null
sleep 3

# macOS TCC check. If the vault lives in a protected location, the job fails with
# "Operation not permitted" / exit 126 before the script even starts.
LAST_EXIT="$(launchctl print "$DOMAIN/$LABEL" 2>/dev/null | sed -n 's/.*last exit code = \([0-9]*\).*/\1/p' | head -1)"
if [ "${LAST_EXIT:-0}" = "126" ] || grep -q "Operation not permitted" "$LOG" 2>/dev/null; then
  fda_hint
  exit 2
fi

echo "installed $LABEL"
echo "  plist:    $DEST"
echo "  vault:    $VAULT"
echo "  git dir:  $GIT_DIR_PATH"
echo "  interval: 120 s (edit StartInterval in the template and re-run to change)"
echo "  log:      $LOG"
echo
echo "Verify in a couple of minutes: bash _tools/vgit log --oneline -3"
echo "Sweep commits are labelled 'sweep: N file(s) changed'."

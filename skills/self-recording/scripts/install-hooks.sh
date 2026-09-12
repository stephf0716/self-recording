#!/bin/bash
# install-hooks.sh -- register the auto-commit hooks in <vault>/.claude/settings.json
#
#   bash install-hooks.sh [/path/to/vault]
#
# Registers three events:
#   Stop          -> commit after every assistant turn (the primary mechanism)
#   SessionEnd    -> commit at clean exit
#   SessionStart  -> sweep drift from abrupt exits, inject the contract
#
# MERGES into any existing settings.json rather than overwriting it, and refuses if
# a Stop/SessionEnd/SessionStart hook is already present so it cannot silently
# clobber something the person set up themselves.
#
# The hook is invoked as  bash "$CLAUDE_PROJECT_DIR/_tools/hook-autocommit.sh"  with
# an explicit "shell": "bash". Both matter on Windows: without Git Bash, Claude Code
# falls back to PowerShell and a .sh hook dies.
#
# Scope caveat worth telling the person: project settings only load for sessions
# rooted at the vault. Starting a session inside a subfolder gets no automation.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="${1:-$(dirname "$SCRIPT_DIR")}"
VAULT="$(cd "$VAULT" && pwd)" || { echo "ERROR: no such directory: $1" >&2; exit 1; }
SETTINGS="$VAULT/.claude/settings.json"

[ -f "$VAULT/_tools/hook-autocommit.sh" ] || {
  echo "ERROR: $VAULT/_tools/hook-autocommit.sh not found." >&2
  echo "       Copy scripts/hook-autocommit.sh there first." >&2
  exit 1; }

PY=""
for c in python3 python py; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done

read -r -d '' HOOKJSON <<'EOF'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command",
                     "command": "bash \"$CLAUDE_PROJECT_DIR/_tools/hook-autocommit.sh\" turn 2>/dev/null || true",
                     "shell": "bash", "timeout": 30 } ] }
    ],
    "SessionEnd": [
      { "hooks": [ { "type": "command",
                     "command": "bash \"$CLAUDE_PROJECT_DIR/_tools/hook-autocommit.sh\" end 2>/dev/null || true",
                     "shell": "bash", "timeout": 30 } ] }
    ],
    "SessionStart": [
      { "hooks": [ { "type": "command",
                     "command": "bash \"$CLAUDE_PROJECT_DIR/_tools/hook-autocommit.sh\" start 2>/dev/null || true",
                     "shell": "bash", "timeout": 60 } ] }
    ]
  }
}
EOF

if [ -z "$PY" ]; then
  echo "No python found, so this cannot merge JSON safely."
  echo "Add this to $SETTINGS by hand (merging with what is already there):"
  echo
  printf '%s\n' "$HOOKJSON"
  exit 0
fi

mkdir -p "$VAULT/.claude"
printf '%s\n' "$HOOKJSON" > "$VAULT/.claude/.hooks-fragment.json"

"$PY" - "$SETTINGS" "$VAULT/.claude/.hooks-fragment.json" <<'PY'
import json, os, sys

target, fragment = sys.argv[1], sys.argv[2]
new = json.load(open(fragment))

if os.path.exists(target):
    try:
        cur = json.load(open(target))
    except ValueError:
        sys.exit(f"ERROR: {target} is not valid JSON. Fix it first -- a malformed "
                 "settings file silently disables EVERY setting in it.")
else:
    cur = {}

hooks = cur.setdefault("hooks", {})
for event, entries in new["hooks"].items():
    if event in hooks and hooks[event]:
        sys.exit(f"ERROR: a {event} hook already exists in {target}.\n"
                 f"       Refusing to overwrite it. Merge by hand:\n"
                 f"       {json.dumps(entries, indent=2)}")
    hooks[event] = entries

with open(target, "w") as f:
    json.dump(cur, f, indent=2)
    f.write("\n")

print(f"Merged Stop + SessionEnd + SessionStart hooks into {target}")
PY
rc=$?
rm -f "$VAULT/.claude/.hooks-fragment.json"
[ $rc -eq 0 ] || exit $rc

# Prove the hook runs before claiming it is installed.
echo
echo "Pipe-testing the hook (stdout must be valid JSON):"
if echo '{}' | bash "$VAULT/_tools/hook-autocommit.sh" start | "$PY" -c \
   "import json,sys; json.load(sys.stdin); print('  OK -- valid JSON')" 2>/dev/null; then
  :
else
  echo "  WARNING: the hook did not emit valid JSON. Run it directly to see why:"
  echo "    echo '{}' | bash \"$VAULT/_tools/hook-autocommit.sh\" start"
fi

cat <<EOF

Hooks are live for sessions started AT the vault root:

  cd "$VAULT" && claude

Starting inside a subfolder loads no project settings, so there is no automation
there. Mention this -- it is a silent loss, not an error.

If the hooks do not fire this session, the settings watcher only watches
directories that already had a settings file at startup. Restart to pick them up.

These hooks cover Claude Code sessions ONLY. If another AI client edits this
vault and is sandboxed to the folder (it cannot write to the git dir outside it),
its edits are unrevertible until something else commits. On macOS, install the
scheduled sweep:

  bash "$VAULT/_tools/install-autocommit-agent.sh"
EOF

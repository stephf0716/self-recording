#!/bin/bash
# archive-project.sh -- move a live project into _archive/, same folder name.
#
#   bash _tools/archive-project.sh <Folder-Name>
#
# Moves:
#   <Folder-Name>/  →  _archive/<Folder-Name>/
#
# Keeps the folder name so journal frontmatter `project:` still matches.
# Deliberately does NOT edit README/JOURNAL status, inbound pointers, or
# journals -- those are the operator's (or agent's) job after the move.
#
# Does not commit; the Stop/SessionEnd hook or the scheduled sweep picks it up.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="$(dirname "$SCRIPT_DIR")"

NAME="${1:-}"

if [ -z "$NAME" ]; then
  echo "usage: bash _tools/archive-project.sh <Folder-Name>" >&2
  exit 1
fi

case "$NAME" in
  .|.. ) echo "ERROR: '$NAME' is not a project folder." >&2; exit 1 ;;
  */* ) echo "ERROR: pass a top-level folder name, not a path." >&2; exit 1 ;;
  _* ) echo "ERROR: leading underscore is reserved for vault infrastructure (_agent, _tools, _archive)." >&2; exit 1 ;;
esac

DIR="$VAULT/$NAME"
if [ ! -d "$DIR" ]; then
  echo "ERROR: $NAME is not a top-level folder in the vault." >&2
  exit 1
fi
if [ ! -f "$DIR/JOURNAL.md" ]; then
  echo "ERROR: $NAME has no JOURNAL.md, so it is not a project." >&2
  exit 1
fi

mkdir -p "$VAULT/_archive" || exit 1

TARGET="$VAULT/_archive/$NAME"
if [ -e "$TARGET" ]; then
  echo "ERROR: _archive/$NAME already exists." >&2
  exit 1
fi

mv "$DIR" "$TARGET" || exit 1

echo "Moved:"
echo "  $NAME/  →  _archive/$NAME/"
cat <<EOF

The folder name is unchanged, so journal frontmatter project: still matches.

Still to do (this script does not):
  * Set README and JOURNAL frontmatter status: archived.
  * Update inbound path pointers in other projects.
  * Journal the move in _archive/$NAME/JOURNAL.md and in the vault's
    general/workspace journal if one exists.
  * Do not put a JOURNAL.md directly in _archive/.

To restore: move _archive/$NAME/ back to the vault root with the same name
and set status active. Do not delete unless the owner asks.
EOF

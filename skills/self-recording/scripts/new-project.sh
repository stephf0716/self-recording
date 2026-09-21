#!/bin/bash
# new-project.sh -- scaffold a new project folder in an AI memory vault.
#
#   bash _tools/new-project.sh <Folder-Name> ["one-line purpose"]
#
# Creates:
#   <Folder-Name>/JOURNAL.md   append-only memory, correct metadata from day one
#   <Folder-Name>/README.md    what this project is, for humans and agents
#
# Deliberately does NOT edit the root AGENTS.md. A top-level folder containing a
# JOURNAL.md IS a project by convention -- so there is no list to keep in sync and
# nothing that goes stale when a project is added.
#
# Does not commit; the Stop/SessionEnd hook or the scheduled sweep picks it up.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="$(dirname "$SCRIPT_DIR")"

NAME="${1:-}"
PURPOSE="${2:-TODO: one line on what this project delivers.}"

if [ -z "$NAME" ]; then
  echo "usage: bash _tools/new-project.sh <Folder-Name> [\"one-line purpose\"]" >&2
  exit 1
fi

# Windows-safe name check. Do this even on macOS -- vaults get synced to Windows
# machines, and a name that is legal here can break sync there.
case "$NAME" in
  *[\<\>:\"/\\\|\?\*]* ) echo "ERROR: name contains a character Windows rejects: <>:\"/\\|?*" >&2; exit 1 ;;
  *' ' ) echo "ERROR: trailing space in name." >&2; exit 1 ;;
  *. ) echo "ERROR: trailing dot in name." >&2; exit 1 ;;
  _* ) echo "ERROR: leading underscore is reserved for vault infrastructure (_agent, _tools, _archive)." >&2; exit 1 ;;
esac

UPPER="$(printf '%s' "$NAME" | tr '[:lower:]' '[:upper:]')"
case "$UPPER" in
  CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9] )
    echo "ERROR: '$NAME' is a reserved Windows device name." >&2; exit 1 ;;
esac

DIR="$VAULT/$NAME"
if [ -e "$DIR" ]; then
  echo "ERROR: $NAME already exists." >&2
  [ -f "$DIR/JOURNAL.md" ] && echo "       It already has a JOURNAL.md, so it is already a project." >&2
  exit 1
fi

TODAY="$(date '+%Y-%m-%d')"
OWNER="$(git config --global user.name 2>/dev/null || echo 'the owner')"

mkdir -p "$DIR" || exit 1

cat > "$DIR/JOURNAL.md" <<EOF
---
type: journal
project: $NAME
status: active
created: $TODAY
updated: $TODAY
---

# $NAME — journal

Append-only running record of decisions, changes of plan, and durable facts for
this project. **Newest entry at the top.**

Agents write here as work happens — no approval needed. Anything an agent wrote
carries \`confidence: probable\`; only ${OWNER}'s own statements are \`confirmed\`.
Entries are never deleted or rewritten; a superseded one is marked
\`status: superseded\` and left in place.

Format and field definitions: \`../AGENTS.md\` and \`../MEMORY-SCHEMA.md\`.

## Current state

<!-- current-state: $TODAY; decisions: 0 -->

Pointer summary of what is currently true. **Contains no primary information** —
every line cites the dated entry that established it. Rewritten in place (the one
exception to append-only); regenerate at the end of any session that adds a
\`decision\` entry. Keep under ~30 bullets. Check for drift with
\`bash _tools/check-current-state.sh\`.

- *(nothing settled yet)*

---

*(no entries yet)*
EOF

cat > "$DIR/README.md" <<EOF
---
type: project
status: active
created: $TODAY
updated: $TODAY
confidence: confirmed
owner: $OWNER
---

# $NAME

$PURPOSE

## Current objective

TODO

## Key dates

| Date | Commitment |
|---|---|
| TODO | TODO |

## Constraints an agent must know

TODO — safety gates, systems of record, decisions not open for rediscussion. If
this project has hard constraints, add an \`AGENTS.md\` here too; a folder's own
\`AGENTS.md\` overrides the root one.

## Running record

Decisions and changes of plan go in \`JOURNAL.md\`, newest first.
EOF

echo "Created:"
echo "  $NAME/JOURNAL.md"
echo "  $NAME/README.md"
cat <<EOF

It is already a project -- a top-level folder with a JOURNAL.md is recognized as
one, so there is no map to update.

Next:
  * Fill in README.md (objective, dates, constraints).
  * If it has hard safety or process constraints, add $NAME/AGENTS.md.
  * Just start working. Decisions land in $NAME/JOURNAL.md automatically.
EOF

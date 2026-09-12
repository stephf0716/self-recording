#!/bin/bash
# check-current-state.sh -- flag journals whose "Current state" block has drifted.
#
# A journal's `## Current state` block is a pointer summary that is rewritten in
# place -- the one exception to append-only. It drifts when a session appends a
# `decision` entry and does not regenerate the block. This script reports, for
# every project JOURNAL.md:
#
#   MISSING  -- no `<!-- current-state: YYYY-MM-DD -->` marker at all
#   STALE    -- a `type: decision` entry is dated after the marker
#   OK       -- marker present and no newer decision
#
# Read-only. Exit 1 if anything is MISSING or STALE, so it can gate a hook or a
# CI step. A STALE result is a warning to regenerate, not a data problem -- the
# dated entries are still authoritative.
#
# Usage:  bash _tools/check-current-state.sh              # all projects
#         bash _tools/check-current-state.sh Some-Project  # one project folder
#
# POSIX tools only (awk, grep, sort, find). Works on macOS and Windows/Git Bash.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="$(dirname "$SCRIPT_DIR")"
cd "$VAULT" || exit 1

if [ $# -gt 0 ]; then
  journals=""
  for p in "$@"; do
    if [ -f "$p/JOURNAL.md" ]; then
      journals="$journals $p/JOURNAL.md"
    else
      echo "skip: $p has no JOURNAL.md" >&2
    fi
  done
else
  # Any top-level folder containing a JOURNAL.md is a project. Underscore-prefixed
  # folders are vault infrastructure, not projects.
  journals="$(find . -maxdepth 2 -name JOURNAL.md -not -path './_*' | sort)"
fi

rc=0
for j in $journals; do
  proj="$(basename "$(dirname "$j")")"
  marker="$(grep -m1 -oE '<!-- current-state: [0-9]{4}-[0-9]{2}-[0-9]{2} -->' "$j" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"

  if [ -z "$marker" ]; then
    printf 'MISSING  %-24s no current-state marker\n' "$proj"
    rc=1
    continue
  fi

  # Newest decision date: entry headings are "## YYYY-MM-DD — title"; the type
  # line follows within a few lines. Track the heading date, emit it on decision.
  newest_decision="$(awk '
    /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { d = substr($2, 1, 10) }
    /\*\*type:\*\* *decision/                        { print d }
  ' "$j" | sort | tail -1)"

  # ISO dates compare correctly as strings.
  if [ -n "$newest_decision" ] && [ "$newest_decision" \> "$marker" ]; then
    printf 'STALE    %-24s marker %s, decision %s\n' "$proj" "$marker" "$newest_decision"
    rc=1
  else
    printf 'OK       %-24s marker %s\n' "$proj" "$marker"
  fi
done

exit $rc

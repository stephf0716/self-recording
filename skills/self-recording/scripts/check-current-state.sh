#!/bin/bash
# check-current-state.sh -- flag journals whose "Current state" block has drifted.
#
# A journal's `## Current state` block is a pointer summary that is rewritten in
# place -- the one exception to append-only. It drifts when a session appends a
# `decision` entry and does not regenerate the block. This script reports, for
# every project JOURNAL.md:
#
#   MISSING  -- no `<!-- current-state: YYYY-MM-DD[; decisions: N] -->` marker
#   STALE    -- decision count changed, or a legacy marker predates a decision
#   OK       -- marker present and no newer/unaccounted decision
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

rc=0

check_journal() {
  j="$1"
  proj="$(basename "$(dirname "$j")")"
  marker_line="$(grep -m1 -oE '<!-- current-state: [0-9]{4}-[0-9]{2}-[0-9]{2}(; decisions: [0-9]+)? -->' "$j")"
  marker="$(printf '%s\n' "$marker_line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}')"

  if [ -z "$marker" ]; then
    printf 'MISSING  %-24s no current-state marker\n' "$proj"
    rc=1
    return
  fi

  recorded_decisions=""
  case "$marker_line" in
    *'; decisions: '*)
      recorded_decisions="${marker_line#*; decisions: }"
      recorded_decisions="${recorded_decisions%% *}"
      ;;
  esac

  # Extract only real decision-entry metadata: it must appear after a dated entry
  # heading, at the start of a list item, and outside fenced code. This avoids
  # counting quoted examples such as `- **type:** decision` in prose or templates.
  decision_dates="$(awk '
    /^[[:space:]]*```/ { fenced = !fenced; next }
    fenced             { next }
    /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ {
      d = substr($2, 1, 10)
      counted = 0
      next
    }
    d != "" && !counted && /^- \*\*type:\*\* decision[[:space:]]*$/ {
      print d
      counted = 1
    }
  ' "$j")"
  decision_count="$(printf '%s\n' "$decision_dates" | awk 'NF { n++ } END { print n + 0 }')"
  newest_decision="$(printf '%s\n' "$decision_dates" | sort | tail -1)"

  # Counted markers detect decisions added later on the same day. Legacy date-only
  # markers retain the original date comparison until they are regenerated.
  if [ -n "$recorded_decisions" ] && [ "$decision_count" -ne "$recorded_decisions" ]; then
    printf 'STALE    %-24s marker %s, decisions %s/%s\n' "$proj" "$marker" "$recorded_decisions" "$decision_count"
    rc=1
  elif [ -n "$newest_decision" ] && [ "$newest_decision" \> "$marker" ]; then
    printf 'STALE    %-24s marker %s, decision %s\n' "$proj" "$marker" "$newest_decision"
    rc=1
  else
    printf 'OK       %-24s marker %s\n' "$proj" "$marker"
  fi
}

if [ $# -gt 0 ]; then
  for p in "$@"; do
    if [ -f "$p/JOURNAL.md" ]; then
      check_journal "$p/JOURNAL.md"
    elif [ -f "$p" ] && [ "$(basename "$p")" = "JOURNAL.md" ]; then
      check_journal "$p"
    else
      echo "skip: $p has no JOURNAL.md" >&2
    fi
  done
else
  # Any top-level folder containing a JOURNAL.md is a project. Underscore-prefixed
  # folders are vault infrastructure, not projects. Read one path per line so
  # spaces in project names remain part of the path.
  while IFS= read -r j; do
    [ -n "$j" ] && check_journal "$j"
  done < <(find . -maxdepth 2 -name JOURNAL.md -not -path './_*' | sort)
fi

exit $rc

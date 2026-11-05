#!/bin/bash
# rotate-journal.sh -- keep JOURNAL.md small by rolling its oldest entries out,
# verbatim, into per-month files under <project>/journal/.
#
# Why: journals are append-only, so they grow without bound. Past ~100 KB some
# editors refuse to preview them and agents can no longer read them whole.
# Rotation moves bytes; it never edits or drops an entry.
#
#   <project>/JOURNAL.md          preamble + ## Current state + newest entries
#   <project>/journal/YYYY-MM.md  older entries from that month, newest first
#
# An entry runs from a `## YYYY-MM-DD` heading (outside a ``` fence) to the line
# before the next one. Everything above the first entry is the preamble. Entries
# go to the file for the month in their own heading date. A month file that
# already exists gets the newly moved entries inserted above its existing ones,
# so newest-first holds inside every file.
#
# Rules:
#   * Keeps the newest entries whose total, with the preamble, fits --max-kb
#     (default 60). Always keeps at least --min-keep entries (default 5).
#   * New entries still go at the top of JOURNAL.md, never into journal/.
#   * Rolled files are still append-only memory: mark superseded entries in
#     place there, exactly as in JOURNAL.md.
#   * Current-state pointers keep working -- they cite date + title, and grep
#     finds the entry wherever it lives. check-current-state.sh counts decisions
#     across JOURNAL.md and journal/*.md, so markers stay valid.
#   * Checks every entry line is conserved before replacing anything.
#   * Do not run it while another session is writing the same journal.
#
# Usage:  bash _tools/rotate-journal.sh                      # dry run, all projects
#         bash _tools/rotate-journal.sh Some-Project         # dry run, one project
#         bash _tools/rotate-journal.sh --apply [paths...]   # write it
#         options: --max-kb N  --min-keep N
#
# POSIX tools only (awk, sed, find, sort, cksum). Works on macOS and Windows/Git Bash.

set -u
# Byte lengths and a stable sort order, whatever the user's locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="$(dirname "$SCRIPT_DIR")"
cd "$VAULT" || exit 1

usage() { sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'; }
need_int() {  # option value
  case "$2" in
    ''|*[!0-9]*) echo "ERROR: $1 needs a whole number, got '${2}'" >&2; exit 2 ;;
  esac
}

APPLY=0
MAX_KB=60
MIN_KEEP=5
PATHS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)    APPLY=1 ;;
    --max-kb)   need_int "$1" "${2:-}"; MAX_KB="$2"; shift ;;
    --min-keep) need_int "$1" "${2:-}"; MIN_KEEP="$2"; shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *)          PATHS+=("${1%/}") ;;
  esac
  shift
done
MAX_BYTES=$((MAX_KB * 1024))
POINTER='Older entries are in [`journal/`](journal/), one file per month, rolled out verbatim by `_tools/rotate-journal.sh`.'

ENTRY_RE='^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'

# "<start> <end> <YYYY-MM> <bytes>" per entry, then "HEAD <lines> <bytes>".
index_entries() {
  awk -v re="$ENTRY_RE" '
    /^[[:space:]]*```/ { fenced = !fenced }
    !fenced && $0 ~ re {
      if (s) printf "%d %d %s %d\n", s, NR - 1, m, b
      else hl = NR - 1
      s = NR; m = substr($2, 1, 7); b = 0
    }
    { if (s) b += length($0) + 1; else hb += length($0) + 1 }
    END { if (s) printf "%d %d %s %d\n", s, NR, m, b; else hl = NR
          printf "HEAD %d %d\n", hl, hb + 0 }
  ' "$1"
}

# Entry lines (no preamble) of each file given; for the conservation check.
entry_lines() {
  for f in "$@"; do
    [ -f "$f" ] || continue
    awk -v re="$ENTRY_RE" '/^[[:space:]]*```/ { f = !f } !f && $0 ~ re { on = 1 } on' "$f"
  done
}
entry_sum() { entry_lines "$@" | sort | cksum; }

# Print lines a..b of a file; nothing when the range is empty.
lines() { [ "$2" -ge "$1" ] && sed -n "${1},${2}p" "$3"; return 0; }

month_header() {  # project month
  cat <<EOF
---
type: journal-archive
project: $1
period: $2
---

# $1 — journal, $2

Entries rolled out of [\`../JOURNAL.md\`](../JOURNAL.md) by
\`_tools/rotate-journal.sh\`, verbatim, newest first. Still append-only memory:
mark a superseded entry \`status: superseded\` here, in place. New entries go
at the top of \`../JOURNAL.md\`, never here.

---

EOF
}

rc=0

rotate() {
  j="$1"
  dir="$(dirname "$j")"
  # `project:` from YAML frontmatter only (line 1 must open it).
  proj="$(awk 'NR==1 && !/^---[[:space:]]*$/ {exit} NR>1 && /^---[[:space:]]*$/ {exit}
               /^project:[[:space:]]/ {sub(/^project:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$j")"
  [ -n "$proj" ] || proj="$(basename "$dir")"

  idx="$(index_entries "$j")"
  head_lines="$(printf '%s\n' "$idx" | awk '$1=="HEAD"{print $2}')"
  head_bytes="$(printf '%s\n' "$idx" | awk '$1=="HEAD"{print $3}')"
  entries="$(printf '%s\n' "$idx" | awk '$1!="HEAD"')"
  n="$(printf '%s\n' "$entries" | awk 'NF{c++} END{print c+0}')"
  total=$(wc -c < "$j" | tr -d ' ')

  has_pointer=0
  lines 1 "$head_lines" "$j" | grep -qF '](journal/)' && has_pointer=1
  pl=0
  [ "$has_pointer" -eq 1 ] || pl=$(( ${#POINTER} + 2 ))

  # How many entries to keep, counted from the top.
  keep="$(printf '%s\n' "$entries" | awk -v hb="$head_bytes" -v max="$MAX_BYTES" \
            -v pl="$pl" -v mk="$MIN_KEEP" '
    NF { k++; t += $4; if (k > mk && hb + pl + t > max) { print k - 1; done = 1; exit } }
    END { if (!done) print k + 0 }')"

  if [ "$keep" -ge "$n" ]; then
    printf 'OK       %-28s %4d KB, %d entries\n' "$dir" $((total / 1024)) "$n"
    return
  fi

  moved=$((n - keep))
  months="$(printf '%s\n' "$entries" | awk -v k="$keep" 'NF && ++i > k {print $3}' | sort -u -r | tr '\n' ' ')"
  printf 'ROTATE   %-28s %4d KB, %d entries: keep %d, move %d -> journal/ %s\n' \
    "$dir" $((total / 1024)) "$n" "$keep" "$moved" "$months"
  [ "$APPLY" -eq 1 ] || return

  if [ -e "$dir/journal" ] && [ ! -d "$dir/journal" ]; then
    echo "ERROR    $dir/journal exists and is not a directory; nothing written" >&2
    rc=1; return
  fi
  before="$(entry_sum "$j" "$dir"/journal/*.md)"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rotate-journal.XXXXXX")" || { rc=1; return; }
  first_moved_line="$(printf '%s\n' "$entries" | awk -v k="$keep" 'NF && ++i == k + 1 {print $1}')"

  # New JOURNAL.md: preamble (+ pointer once) + kept entries.
  {
    if [ "$has_pointer" -eq 1 ]; then
      lines 1 "$head_lines" "$j"
    else
      # Above `## Current state` (or the first other `## ` section, outside
      # fences), so regenerating that block never drops it. With no section
      # heading, append it to the preamble.
      lines 1 "$head_lines" "$j" | awk -v p="$POINTER" '
        /^[[:space:]]*```/ { f = !f }
        !done && !f && /^## / { print p; print ""; done = 1 }
        { print }
        END { if (!done) { print p; print "" } }'
    fi
    lines $((head_lines + 1)) $((first_moved_line - 1)) "$j"
  } > "$tmp/JOURNAL.md"

  # Month files: existing preamble (or a new header), moved entries for that
  # month, then the file's existing entries.
  for m in $months; do
    mf="$dir/journal/$m.md"
    {
      if [ -f "$mf" ]; then
        awk -v re="$ENTRY_RE" '/^[[:space:]]*```/{f=!f} !f && $0 ~ re {exit} {print}' "$mf"
      else
        month_header "$proj" "$m"
      fi
      printf '%s\n' "$entries" | awk -v k="$keep" -v m="$m" 'NF && ++i > k && $3 == m {print $1, $2}' |
        while read -r a b; do lines "$a" "$b" "$j"; done
      entry_lines "$mf"
    } > "$tmp/$m.md"
  done

  # Conservation check before touching anything.
  others=()
  for f in "$dir"/journal/*.md; do
    [ -f "$f" ] || continue
    case " $months " in *" $(basename "$f" .md) "*) ;; *) others+=("$f") ;; esac
  done
  after="$(entry_sum "$tmp"/*.md ${others[@]+"${others[@]}"})"
  if [ "$before" != "$after" ]; then
    echo "ERROR    $dir: entry content not conserved; nothing written" >&2
    rm -rf "$tmp"; rc=1; return
  fi

  # Month files first: an interruption duplicates entries, never loses them.
  mkdir -p "$dir/journal" || { rm -rf "$tmp"; rc=1; return; }
  for m in $months; do mv "$tmp/$m.md" "$dir/journal/$m.md" || { rc=1; return; }; done
  mv "$tmp/JOURNAL.md" "$j" || { rc=1; return; }
  rm -rf "$tmp"
  printf '         wrote %s (%d KB) and journal/ %s\n' "$j" $(( $(wc -c < "$j") / 1024 )) "$months"
}

if [ ${#PATHS[@]} -gt 0 ]; then
  for p in "${PATHS[@]}"; do
    if [ -f "$p/JOURNAL.md" ]; then
      rotate "$p/JOURNAL.md"
    elif [ -f "$p" ] && [ "$(basename "$p")" = "JOURNAL.md" ]; then
      rotate "$p"
    else
      echo "skip: $p has no JOURNAL.md" >&2
    fi
  done
else
  # Same discovery as check-current-state.sh: a top-level folder with a
  # JOURNAL.md is a project; underscore folders are infrastructure. A file in
  # journal/ is never a project -- only one named exactly JOURNAL.md is.
  while IFS= read -r j; do
    [ -n "$j" ] && rotate "${j#./}"
  done < <(find . -maxdepth 2 -name JOURNAL.md -not -path './_*' | sort)
fi

[ "$APPLY" -eq 1 ] || echo "(dry run -- pass --apply to write)"
exit $rc

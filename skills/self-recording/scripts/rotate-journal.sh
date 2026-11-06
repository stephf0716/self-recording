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
# An entry runs from a `## YYYY-MM-DD` heading (outside a code fence) to the
# line before the next one. Everything above the first entry is the preamble.
# Entries go to the file for the month in their own heading date. A month file
# that already exists gets the newly moved entries inserted above its existing
# ones, so newest-first holds inside every file.
#
# Rules:
#   * Keeps the newest entries whose total, with the preamble, fits --max-kb
#     (default 60). Always keeps at least --min-keep entries (default 5).
#   * New entries still go at the top of JOURNAL.md, never into journal/.
#   * Rolled files are still append-only memory: mark superseded entries in
#     place there, exactly as in JOURNAL.md.
#   * check-current-state.sh counts decisions across JOURNAL.md and
#     journal/*.md, so markers stay valid.
#
# Safety (--apply):
#   * One rotation per project at a time: <project>/.rotate-journal.lock/ is
#     the lock and the staging area (same volume, so replacing is a rename).
#   * Every source file is checksummed when read and re-checked just before
#     anything is replaced; if another session wrote in between, it aborts with
#     nothing written. Still: close the journal in editors and don't rotate
#     while other sessions are working -- an editor saving an old buffer later
#     undoes the rotation (the next dry run then reports it as REPAIR).
#   * Whole entries are conserved, checked before and after writing.
#   * If any replacement fails, everything already replaced is rolled back.
#   * Repair: an entry in JOURNAL.md that is already, verbatim, in journal/
#     (a half-applied or undone rotation) is dropped from JOURNAL.md, not
#     copied again. A same-heading entry with different text is a CONFLICT:
#     nothing is written; resolve it by hand.
#
# Usage:  bash _tools/rotate-journal.sh                      # dry run, all projects
#         bash _tools/rotate-journal.sh Some-Project         # dry run, one project
#         bash _tools/rotate-journal.sh --apply [paths...]   # write it
#         options: --max-kb N  --min-keep N
#
# POSIX tools only (awk, sed, find, sort, cksum). Works on macOS and Windows/Git Bash.

set -u
set -o pipefail
# Byte lengths and a stable sort order, whatever the user's locale.
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VAULT="$(dirname "$SCRIPT_DIR")"
cd "$VAULT" || exit 1

usage() { sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; }
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
    # 10# so a zero-padded value is decimal, not octal.
    --max-kb)   need_int "$1" "${2:-}"; MAX_KB=$((10#$2)); shift ;;
    --min-keep) need_int "$1" "${2:-}"; MIN_KEEP=$((10#$2)); shift ;;
    -h|--help)  usage; exit 0 ;;
    -*)         echo "ERROR: unknown option $1" >&2; exit 2 ;;
    *)          PATHS+=("${1%/}") ;;
  esac
  shift
done
MAX_BYTES=$((MAX_KB * 1024))
POINTER='Older entries are in [`journal/`](journal/), one file per month, rolled out verbatim by `_tools/rotate-journal.sh`.'
LOCK_NAME=.rotate-journal.lock

# Test-only fault injection (tests/test-skill.sh). Unset in normal use.
#   ROTATE_JOURNAL_TEST_HOOK   shell command run after staging, before the re-check
#   ROTATE_JOURNAL_FAIL_AT     name of one replace step to fail, e.g. place:JOURNAL.md
TEST_HOOK="${ROTATE_JOURNAL_TEST_HOOK:-}"
FAIL_AT="${ROTATE_JOURNAL_FAIL_AT:-}"

ENTRY_RE='^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'

# Markdown code fences: ``` or ~~~ (3+), closed only by the same character at
# least as long with nothing after it, so a longer fence can quote a shorter
# one. Sets `fenced`; returns 1 on a fence line. Shared by every scanner here
# and by check-current-state.sh.
FENCE_AWK='
function fence(line,   s, c, n, rest) {
  s = line; sub(/^[[:space:]]*/, "", s)
  c = substr(s, 1, 1)
  if (c != "`" && c != "~") return 0
  n = 0; while (substr(s, n + 1, 1) == c) n++
  if (n < 3) return 0
  rest = substr(s, n + 1)
  if (!fenced) {
    if (c == "`" && index(rest, "`")) return 0
    fenced = 1; fch = c; flen = n; return 1
  }
  if (c == fch && n >= flen && rest ~ /^[[:space:]]*$/) { fenced = 0; return 1 }
  return 0
}'

# plan_index JOURNAL [month files...]
# Prints "<start> <end> <YYYY-MM> <bytes> <new|dup|conflict>" per JOURNAL.md
# entry, then "HEAD <preamble lines> <preamble bytes>". `dup` = the same entry,
# byte for byte, is already in a month file; `conflict` = a month file has an
# entry with the same heading but different text.
plan_index() {
  j="$1"; shift
  awk -v re="$ENTRY_RE" -v jf="$j" "$FENCE_AWK"'
    function flush() {
      if (!s) return
      if (!isj) { seen[cur] = 1; heads[head] = 1 }
      else print s, e, m, b, ((cur in seen) ? "dup" : ((head in heads) ? "conflict" : "new"))
      s = 0
    }
    FNR == 1 { flush(); fenced = 0; isj = (FILENAME == jf) }
    { fence($0) }
    !fenced && $0 ~ re { flush(); s = FNR; head = $0; m = substr($2, 1, 7); cur = ""; b = 0 }
    s   { cur = cur $0 "\n"; b += length($0) + 1; e = FNR; next }
    isj { hl = FNR; hb += length($0) + 1 }
    END { flush(); print "HEAD", hl + 0, hb + 0 }
  ' "$@" "$j"
}

# One line per entry (its lines joined by \001), for whole-entry conservation
# checks. Fails if any named file cannot be read.
entry_records() {
  for f in "$@"; do
    [ -e "$f" ] || continue
    awk -v re="$ENTRY_RE" "$FENCE_AWK"'
      function out() { if (on) print cur; cur = "" }
      { fence($0) }
      !fenced && $0 ~ re { out(); on = 1; cur = $0; next }
      on { cur = cur "\001" $0 }
      END { out() }' "$f" || return 1
  done
}
entry_sum() { entry_records "$@" | sort | cksum; }

# Name and checksum of every file a rotation reads, to detect concurrent writes.
snapshot() {
  for f in "$@"; do
    [ -e "$f" ] || continue
    printf '%s %s\n' "$f" "$(cksum < "$f")" || return 1
  done
}

# Print lines a..b of a file; nothing when the range is empty.
lines() { [ "$2" -ge "$1" ] || return 0; sed -n "${1},${2}p" "$3"; }

# A replace step that a test can make fail: step NAME command...
step() { [ "$1" != "$FAIL_AT" ] || return 1; shift; "$@"; }

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
LOCK=""        # lock dir held by this process
KEEP_LOCK=0    # 1 = it holds originals needed for recovery; never delete it
PHASE=stage    # commit = files are being replaced; an interrupt must keep the lock

release() { [ -z "$LOCK" ] || [ "$KEEP_LOCK" -eq 1 ] || rm -rf "$LOCK"; LOCK=""; }
trap 'release' EXIT
trap 'echo "interrupted${LOCK:+; see $LOCK}" >&2; [ "$PHASE" != commit ] || KEEP_LOCK=1; exit 130' INT TERM

abort() {  # message -- nothing was replaced
  echo "ERROR    $dir: $1; nothing written" >&2
  release; rc=1
}

rotate() {
  j="$1"
  dir="$(dirname "$j")"
  KEEP_LOCK=0

  # Every source must be a readable regular file, every destination a file or
  # absent (a directory named YYYY-MM.md would swallow the mv).
  if [ -e "$dir/journal" ] && [ ! -d "$dir/journal" ]; then
    echo "ERROR    $dir: journal exists and is not a directory; nothing written" >&2; rc=1; return
  fi
  mfiles=()
  for f in "$dir"/journal/*.md; do
    [ -e "$f" ] || continue
    [ -f "$f" ] && [ -r "$f" ] || { echo "ERROR    $dir: $f is not a readable file; nothing written" >&2; rc=1; return; }
    mfiles+=("$f")
  done
  [ -r "$j" ] || { echo "ERROR    $dir: cannot read $j; nothing written" >&2; rc=1; return; }

  if [ "$APPLY" -eq 1 ]; then
    [ -w "$dir" ] && { [ ! -d "$dir/journal" ] || [ -w "$dir/journal" ]; } ||
      { echo "ERROR    $dir: not writable; nothing written" >&2; rc=1; return; }
    if ! mkdir "$dir/$LOCK_NAME" 2>/dev/null; then
      echo "LOCKED   $dir: $dir/$LOCK_NAME exists -- another rotation is running, or one" >&2
      echo "         was interrupted. If none is running, read its README and remove it." >&2
      rc=1; return
    fi
    LOCK="$dir/$LOCK_NAME"
    printf 'rotate-journal.sh staging and lock, started %s by pid %s.\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$$" \
      > "$LOCK/README" || { abort "cannot write the lock"; return; }
    snap0="$(snapshot "$j" "$dir"/journal/*.md)" || { abort "could not read sources"; return; }
  fi

  # `project:` from YAML frontmatter only (line 1 must open it).
  proj="$(awk 'NR==1 && !/^---[[:space:]]*$/ {exit} NR>1 && /^---[[:space:]]*$/ {exit}
               /^project:[[:space:]]/ {sub(/^project:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); print; exit}' "$j")"
  [ -n "$proj" ] || proj="$(basename "$dir")"

  idx="$(plan_index "$j" ${mfiles[@]+"${mfiles[@]}"})" || { abort "could not read entries"; return; }
  head_lines="$(printf '%s\n' "$idx" | awk '$1=="HEAD"{print $2}')"
  head_bytes="$(printf '%s\n' "$idx" | awk '$1=="HEAD"{print $3}')"
  entries="$(printf '%s\n' "$idx" | awk '$1!="HEAD" && NF')"
  n="$(printf '%s\n' "$entries" | awk 'NF{c++} END{print c+0}')"
  total=$(wc -c < "$j" | tr -d ' ')

  conflicts="$(printf '%s\n' "$entries" | awk '$5=="conflict"{print $1}')"
  if [ -n "$conflicts" ]; then
    echo "CONFLICT $dir: these JOURNAL.md entries are also in journal/ with different text:" >&2
    for l in $conflicts; do printf '           line %s: %s\n' "$l" "$(sed -n "${l}p" "$j")" >&2; done
    echo "         Keep one copy of each by hand (the newer edit wins); nothing written." >&2
    release; rc=1; return
  fi

  has_pointer=0
  lines 1 "$head_lines" "$j" | grep -F '](journal/)' >/dev/null && has_pointer=1
  pl=0
  [ "$has_pointer" -eq 1 ] || pl=$(( ${#POINTER} + 2 ))

  # Per entry: keep, move, or drop (already in journal/). Keeps the newest
  # entries that fit; once one does not fit, every older entry moves.
  plan="$(printf '%s\n' "$entries" | awk -v hb="$head_bytes" -v max="$MAX_BYTES" -v pl="$pl" -v mk="$MIN_KEEP" '
    NF && $5 == "dup" { print $1, $2, $3, "drop"; next }
    NF { k++; t += $4; if (!cut && k > mk && hb + pl + t > max) cut = 1
         print $1, $2, $3, (cut ? "move" : "keep") }')"
  n_keep="$(printf '%s\n' "$plan" | awk '$4=="keep"{c++} END{print c+0}')"
  n_move="$(printf '%s\n' "$plan" | awk '$4=="move"{c++} END{print c+0}')"
  n_drop="$(printf '%s\n' "$plan" | awk '$4=="drop"{c++} END{print c+0}')"

  if [ "$n_move" -eq 0 ] && [ "$n_drop" -eq 0 ]; then
    printf 'OK       %-28s %4d KB, %d entries\n' "$dir" $((total / 1024)) "$n"
    release; return
  fi

  months="$(printf '%s\n' "$plan" | awk '$4=="move"{print $3}' | sort -u -r | tr '\n' ' ')"
  word=ROTATE; [ "$n_move" -gt 0 ] || word=REPAIR
  extra=""; [ "$n_drop" -eq 0 ] || extra=", drop $n_drop already in journal/"
  printf '%-8s %-28s %4d KB, %d entries: keep %d, move %d%s' \
    "$word" "$dir" $((total / 1024)) "$n" "$n_keep" "$n_move" "$extra"
  [ "$n_move" -eq 0 ] && printf '\n' || printf ' -> journal/ %s\n' "$months"
  [ "$APPLY" -eq 1 ] || return

  # ---- stage everything inside the lock ----------------------------------
  mkdir -p "$LOCK/new" "$LOCK/orig" || { abort "cannot stage"; return; }

  # New JOURNAL.md: preamble (+ pointer once) + kept entries, in order.
  if [ "$has_pointer" -eq 1 ]; then
    lines 1 "$head_lines" "$j"
  else
    # Above `## Current state` (or the first other `## ` section, outside
    # fences), so regenerating that block never drops it. With no section
    # heading, append it to the preamble.
    lines 1 "$head_lines" "$j" | awk -v p="$POINTER" "$FENCE_AWK"'
      { fence($0) }
      !done && !fenced && /^## / { print p; print ""; done = 1 }
      { print }
      END { if (!done) { print p; print "" } }'
  fi > "$LOCK/JOURNAL.md" &&
    printf '%s\n' "$plan" | awk '$4=="keep"{print $1, $2}' |
      while read -r a b; do lines "$a" "$b" "$j" || exit 1; done >> "$LOCK/JOURNAL.md" ||
    { abort "could not stage JOURNAL.md"; return; }

  # Month files: existing preamble (or a new header), moved entries for that
  # month, then the file's existing entries.
  for m in $months; do
    mf="$dir/journal/$m.md"
    out="$LOCK/new/$m.md"
    if [ -f "$mf" ]; then
      awk -v re="$ENTRY_RE" "$FENCE_AWK"'{ fence($0) } !fenced && $0 ~ re {exit} {print}' "$mf" > "$out"
    else
      month_header "$proj" "$m" > "$out"
    fi || { abort "could not stage journal/$m.md"; return; }
    printf '%s\n' "$plan" | awk -v m="$m" '$4=="move" && $3==m {print $1, $2}' |
      while read -r a b; do lines "$a" "$b" "$j" || exit 1; done >> "$out" ||
      { abort "could not stage journal/$m.md"; return; }
    if [ -f "$mf" ]; then
      awk -v re="$ENTRY_RE" "$FENCE_AWK"'{ fence($0) } !fenced && $0 ~ re { on = 1 } on' "$mf" >> "$out" ||
        { abort "could not stage journal/$m.md"; return; }
    fi
  done

  # Whole-entry conservation: every entry that is not a dropped duplicate, in
  # the staged files plus the month files left alone.
  printf '%s\n' "$plan" | awk '$4!="drop"{print $1, $2}' |
    while read -r a b; do lines "$a" "$b" "$j" || exit 1; done > "$LOCK/expected.md" ||
    { abort "could not read entries"; return; }
  expected="$( { entry_records ${mfiles[@]+"${mfiles[@]}"} "$LOCK/expected.md"; } | sort | cksum)" ||
    { abort "could not read entries"; return; }
  untouched=()
  for f in ${mfiles[@]+"${mfiles[@]}"}; do
    case " $months " in *" $(basename "$f" .md) "*) ;; *) untouched+=("$f") ;; esac
  done
  staged="$(entry_sum "$LOCK/JOURNAL.md" "$LOCK"/new/*.md ${untouched[@]+"${untouched[@]}"})" ||
    { abort "could not read staged entries"; return; }
  [ "$staged" = "$expected" ] || { abort "entry content not conserved"; return; }

  [ -z "$TEST_HOOK" ] || bash -c "$TEST_HOOK"

  # Lost-update guard: nothing we read may have changed, and no month file may
  # have appeared, since we read it.
  snap1="$(snapshot "$j" "$dir"/journal/*.md)" || { abort "could not re-read sources"; return; }
  [ "$snap1" = "$snap0" ] || { abort "$j or journal/ changed while rotating (another session writing?)"; return; }

  # ---- replace, with rollback --------------------------------------------
  # JOURNAL.md first: it is the file most likely to be held open. Each target
  # is renamed into the lock before its replacement is renamed in, so a failure
  # at any point can put every original back.
  done_list=""
  rollback() {
    ok=1
    printf '%s' "$done_list" | awk 'NF{l[++n]=$0} END{for(i=n;i>0;i--) print l[i]}' |
      while IFS='|' read -r t o; do
        if [ -n "$o" ]; then mv -f "$o" "$t" || exit 1; else rm -f "$t" || exit 1; fi
      done || ok=0
    return $((1 - ok))
  }
  commit_one() {  # target staged key
    o=""
    if [ -e "$1" ]; then
      o="$LOCK/orig/$3"
      step "away:$3" mv -f "$1" "$o" || return 1
    fi
    if ! step "place:$3" mv -f "$2" "$1"; then
      [ -z "$o" ] || mv -f "$o" "$1" || return 2
      return 1
    fi
    done_list="$done_list$1|$o
"
  }
  failed=""
  journal_existed=0; [ ! -d "$dir/journal" ] || journal_existed=1
  mkdir -p "$dir/journal" || { abort "cannot create $dir/journal"; return; }
  PHASE=commit
  commit_one "$j" "$LOCK/JOURNAL.md" JOURNAL.md; s=$?
  [ "$s" -eq 0 ] || failed="JOURNAL.md:$s"
  if [ -z "$failed" ]; then
    for m in $months; do
      commit_one "$dir/journal/$m.md" "$LOCK/new/$m.md" "$m.md"; s=$?
      [ "$s" -eq 0 ] || { failed="journal/$m.md:$s"; break; }
    done
  fi
  if [ -n "$failed" ]; then
    if [ "${failed##*:}" -eq 1 ] && rollback; then
      [ "$journal_existed" -eq 1 ] || rmdir "$dir/journal" 2>/dev/null
      PHASE=stage
      abort "could not replace ${failed%:*} (open in an editor or the sync client?); rolled back"
    else
      KEEP_LOCK=1
      echo "ERROR    $dir: could not replace ${failed%:*} and could not roll back." >&2
      echo "         Originals are in $LOCK/orig/; restore them by hand." >&2
      rc=1; release; PHASE=stage
    fi
    return
  fi
  PHASE=stage

  # Read it all back: what is on disk must be exactly what was planned.
  final="$(entry_sum "$j" "$dir"/journal/*.md)"
  if [ "$final" != "$expected" ]; then
    KEEP_LOCK=1
    echo "ERROR    $dir: files on disk do not match the plan after writing (another writer?)." >&2
    echo "         Originals are kept in $LOCK/orig/; compare before deleting it." >&2
    rc=1; release; return
  fi
  release
  printf '         wrote %s (%d KB)%s\n' "$j" $(( $(wc -c < "$j") / 1024 )) \
    "$( [ -z "$months" ] || printf ' and journal/ %s' "$months")"
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

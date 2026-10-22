#!/bin/bash
# upgrade.sh -- bring an established vault's _tools/ up to this skill version.
#
#   bash scripts/upgrade.sh /path/to/vault            # report only; changes nothing
#   bash scripts/upgrade.sh /path/to/vault --apply    # replace, stamp, commit once
#
# Run it from the SKILL directory (the one with SKILL.md), never from a vault's
# _tools/: it compares the vault against the scripts shipped next to it.
#
# Each vault tool listed in reference/script-hashes.txt gets one status:
#
#   OK        identical to this version
#   UPDATE    identical to an older release -- untouched, safe to replace
#   MODIFIED  matches no release -- edited locally; merge by hand, never replaced
#   ABSENT    not installed -- left alone; install only what this machine runs
#
# --apply replaces UPDATE files only, writes _tools/.self-recording-version, and
# makes one commit, "upgrade: self-recording FROM -> TO", after committing any
# pre-existing drift separately so the upgrade reverts in one step. It never
# touches AGENTS.md, pointer files, the schema, or journals: those were adapted
# for this vault. reference/upgrading.md lists, per version, what to merge there.
#
# Works with a detached history (default $HOME/<vault>-history.git, or
# VAULT_GIT_DIR) or a plain .git in the vault. Refuses --apply with no history.
#
# POSIX tools plus git. No python (see reference/pitfalls.md 3).

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
MANIFEST="$SKILL_DIR/reference/script-hashes.txt"
CURRENT="$(tr -d '\r' < "$SKILL_DIR/SKILL.md" 2>/dev/null | sed -n 's/^version:[[:space:]]*//p' | head -1)"

[ -f "$SKILL_DIR/SKILL.md" ] && [ -f "$MANIFEST" ] || {
  echo "ERROR: run this from the skill directory (scripts/ next to SKILL.md and" >&2
  echo "       reference/script-hashes.txt), not from a vault's _tools/." >&2
  exit 1; }

VAULT="${1:-}"
APPLY=0
[ "${2:-}" = "--apply" ] && APPLY=1
[ -n "$VAULT" ] || { echo "usage: bash scripts/upgrade.sh /path/to/vault [--apply]" >&2; exit 1; }
VAULT="$(cd "$VAULT" && pwd)" || { echo "ERROR: no such directory: $1" >&2; exit 1; }
TOOLS="$VAULT/_tools"
STAMP_FILE="$TOOLS/.self-recording-version"

[ "$TOOLS" != "$SKILL_DIR/scripts" ] || { echo "ERROR: that is the skill itself, not a vault." >&2; exit 1; }

hash_of() { tr -d '\r' < "$1" | git hash-object --stdin; }
# A CRLF checkout must parse like LF: strip carriage returns from the manifest too.
manifest() { tr -d '\r' < "$MANIFEST"; }

# Release order is manifest order; no version-sort needed.
VERSIONS="$(manifest | awk '!/^#/ && NF==3 && !seen[$1]++ { print $1 }')"
TOOL_LIST="$(manifest | awk -v v="$CURRENT" '!/^#/ && NF==3 && $1==v { print $3 }')"
[ -n "$TOOL_LIST" ] || { echo "ERROR: manifest has no rows for version $CURRENT" >&2; exit 1; }

# Versions whose copy of $2 has hash $1, space-separated, release order.
versions_with() {
  manifest | awk -v h="$1" -v p="$2" '!/^#/ && NF==3 && $2==h && $3==p { printf "%s ", $1 }'
}

echo "Skill:  $SKILL_DIR ($CURRENT)"
echo "Vault:  $VAULT"

STAMPED=""
[ -f "$STAMP_FILE" ] && STAMPED="$(tr -d '\r\n ' < "$STAMP_FILE")"

UPDATES=""
MODIFIED=0
EVIDENCE=0               # untouched tools the version was inferred from
CANDIDATES="$VERSIONS"   # versions consistent with every untouched tool

while IFS= read -r t; do
  src="$SKILL_DIR/scripts/$t"
  dst="$TOOLS/$t"
  if [ ! -f "$dst" ]; then
    printf '  ABSENT    %s\n' "$t"
    continue
  fi
  h="$(hash_of "$dst")"
  if [ "$h" = "$(hash_of "$src")" ]; then
    printf '  OK        %s\n' "$t"
  else
    matches="$(versions_with "$h" "$t")"
    if [ -n "$matches" ]; then
      printf '  UPDATE    %s (matches %s)\n' "$t" "$(echo $matches)"
      UPDATES="$UPDATES$t
"
    else
      printf '  MODIFIED  %s -- edited locally; diff against %s and merge by hand\n' "$t" "$src"
      MODIFIED=$((MODIFIED + 1))
      continue
    fi
  fi
  # Narrow the inferred vault version to releases this tool is identical to.
  EVIDENCE=$((EVIDENCE + 1))
  matches="$(versions_with "$h" "$t")"
  keep=""
  for v in $CANDIDATES; do
    case " $matches " in *" $v "*) keep="$keep $v" ;; esac
  done
  CANDIDATES="$keep"
done <<EOF
$TOOL_LIST
EOF

# FROM_SHORT is where the per-version merge list starts. When the tools can't
# pin one release, start from the oldest one they allow: walking a section the
# contract already has costs a read, skipping one it lacks loses the change.
OLDEST="$(echo $VERSIONS | awk '{ print $1 }')"
if [ -n "$STAMPED" ]; then
  FROM="$STAMPED"; FROM_SHORT="$STAMPED"
elif [ "$EVIDENCE" -eq 0 ]; then
  FROM="unknown (no stamp, and no untouched tool to infer from)"; FROM_SHORT="$OLDEST"
elif [ -z "$(echo $CANDIDATES)" ]; then
  FROM="unknown (no stamp; untouched tools come from different releases)"; FROM_SHORT="$OLDEST"
else
  lo="$(echo $CANDIDATES | awk '{ print $1 }')"
  hi="$(echo $CANDIDATES | awk '{ print $NF }')"
  FROM_SHORT="$lo"
  if [ "$lo" = "$hi" ]; then
    FROM="$lo (inferred; no stamp)"
  else
    FROM="$lo..$hi (inferred; no stamp; these releases ship identical copies of its tools)"
  fi
fi
echo "Built:  $FROM"
FROM_LABEL="${FROM%% *}"

legacy=0; nomarker=0
while IFS= read -r j; do
  [ -n "$j" ] || continue
  if grep -qE '<!-- current-state: [0-9-]{10}; decisions: [0-9]+ -->' "$j"; then :
  elif grep -qE '<!-- current-state: [0-9-]{10} -->' "$j"; then legacy=$((legacy + 1))
  else nomarker=$((nomarker + 1)); fi
done <<EOF
$(cd "$VAULT" && find . -maxdepth 2 -name JOURNAL.md -not -path './_*' | sort | while IFS= read -r r; do printf '%s/%s\n' "$VAULT" "${r#./}"; done)
EOF
[ "$legacy" -gt 0 ] && echo "  note: $legacy journal(s) use date-only markers; they upgrade when next regenerated."
[ "$nomarker" -gt 0 ] && echo "  note: $nomarker journal(s) have no Current state block; add one only if the owner wants it."

echo
echo "Contract files (AGENTS.md, pointers, MEMORY-SCHEMA.md) are never changed by"
echo "this script. Merge what reference/upgrading.md lists for each version after"
echo "$FROM_SHORT -- section by section, with the owner's agreement."
[ "$FROM_LABEL" = "$FROM_SHORT" ] || {
  echo "$FROM_SHORT is the oldest release it could be (or the oldest this script"
  echo "knows), so some sections may already be in its contract: compare before merging."; }
[ "$MODIFIED" -gt 0 ] && echo "MANUAL: $MODIFIED locally modified tool(s) above."

if [ "$APPLY" -eq 0 ]; then
  if [ -n "$UPDATES" ] || [ "$STAMPED" != "$CURRENT" ]; then
    echo "Run again with --apply to replace UPDATE files and stamp $CURRENT."
  else
    echo "Tools are current."
  fi
  exit 0
fi

# ---- apply ---------------------------------------------------------------
if [ -d "$VAULT/.git" ]; then
  g() { git -C "$VAULT" "$@"; }
else
  GIT_DIR_PATH="${VAULT_GIT_DIR:-$HOME/$(basename "$VAULT")-history.git}"
  [ -d "$GIT_DIR_PATH" ] || {
    echo "ERROR: no version history ($GIT_DIR_PATH). Set it up first:" >&2
    echo "       bash $SKILL_DIR/scripts/setup-history.sh $VAULT" >&2
    exit 1; }
  g() { git --git-dir="$GIT_DIR_PATH" --work-tree="$VAULT" "$@"; }
  # The default history path uses only the vault's basename, and its
  # core.worktree points at the vault it was made for. Upgrading a copy with
  # the same name would write tools here but stage and commit the original.
  wt="$(g config --get core.worktree)"
  if [ -n "$wt" ] && [ "$(cd "$wt" 2>/dev/null && pwd -P)" != "$(cd "$VAULT" && pwd -P)" ]; then
    echo "ERROR: $GIT_DIR_PATH is the history of $wt, not of $VAULT." >&2
    echo "       Set VAULT_GIT_DIR to this vault's own history, or set one up first." >&2
    exit 1
  fi
fi

# Nothing is written until the history is readable and has a baseline to undo to.
st="$(g status --porcelain -uall)" || {
  echo "ERROR: cannot read the vault's history; nothing was changed." >&2; exit 1; }
g rev-parse --verify -q HEAD >/dev/null || {
  echo "ERROR: the vault's history has no commits to undo to; nothing was changed." >&2; exit 1; }
if [ -n "$st" ]; then
  n="$(printf '%s\n' "$st" | grep -c .)"
  g add -A && g commit -q -m "pre-upgrade: $n file(s) changed" \
    -m "Drift already in the vault, committed separately so the upgrade commit holds only the upgrade." \
    || { echo "ERROR: could not commit existing changes." >&2; exit 1; }
fi

start="$(g rev-parse HEAD)" || { echo "ERROR: cannot read HEAD; nothing was changed." >&2; exit 1; }

replaced=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  mkdir -p "$(dirname "$TOOLS/$t")"
  cp "$SKILL_DIR/scripts/$t" "$TOOLS/$t" || { echo "ERROR: copy failed: $t" >&2; exit 1; }
  case "$t" in *.sh) chmod +x "$TOOLS/$t" ;; esac
  replaced="$replaced  $t
"
done <<EOF
$UPDATES
EOF

mkdir -p "$TOOLS" && printf '%s\n' "$CURRENT" > "$STAMP_FILE" || {
  echo "ERROR: could not write $STAMP_FILE; the upgrade is NOT recorded." >&2
  exit 1; }

g add -A || {
  echo "ERROR: could not stage the upgrade (is another git process running?)." >&2
  echo "       Tools and the stamp are written but NOT committed; commit them before anything else." >&2
  exit 1; }

# A sweep or hook may have committed part, or all, of the upgrade already.
# Counted before our own commit, so it covers both branches below.
others=0
[ -n "$start" ] && others="$(g rev-list --count "$start..HEAD" 2>/dev/null || echo 0)"
warn_others() {
  [ "$others" -gt 0 ] || return 0
  echo "WARNING: $others other commit(s) landed during the upgrade (a sweep or hook);" >&2
  echo "         part or all of it may be in them. Full undo: revert $(g rev-parse --short "$start")..HEAD" >&2
}

if ! g diff --cached --quiet; then
  g commit -q -m "upgrade: self-recording $FROM_LABEL -> $CURRENT" \
    -m "Replaced (untouched copies of an older release):
${replaced:-  (none)}
Locally modified tools left alone: $MODIFIED. Contract files are merged by hand
per reference/upgrading.md, in a separate commit." \
    || { echo "ERROR: commit failed." >&2; exit 1; }
  echo
  echo "Committed: $(g log -1 --format='%h %s')"
  echo "Undo:      _tools/vgit revert $(g log -1 --format=%h)   (plain git if the vault has .git)"
  warn_others
else
  echo
  if [ "$others" -gt 0 ]; then
    echo "Nothing left to commit: another writer already committed the upgrade."
  else
    echo "Nothing to commit; already current."
  fi
  warn_others
fi
exit 0

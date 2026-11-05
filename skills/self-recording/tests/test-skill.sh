#!/bin/bash
set -eu

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/self-recording-tests.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

assert_contains() {
  haystack="$1"
  needle="$2"
  label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label (missing: $needle)" ;;
  esac
}

test_current_state_handles_project_names_with_spaces() {
  vault="$TMP_ROOT/spaces"
  mkdir -p "$vault/_tools" "$vault/Foo Bar"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  cat > "$vault/Foo Bar/JOURNAL.md" <<'EOF'
---
type: journal
---

## Current state

<!-- current-state: 2026-09-20 -->

---
EOF

  set +e
  output="$(bash "$vault/_tools/check-current-state.sh" 2>&1)"
  status=$?
  set -e

  [ "$status" -eq 0 ] || fail "project name with spaces should pass; got status $status: $output"
  assert_contains "$output" "OK       Foo Bar" "project name with spaces should remain one path"
}

test_current_state_detects_same_day_decision() {
  vault="$TMP_ROOT/same-day"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  cat > "$vault/Project/JOURNAL.md" <<'EOF'
---
type: journal
---

## Current state

<!-- current-state: 2026-09-20; decisions: 0 -->

---

## 2026-09-20 — Same-day decision

- **type:** decision
- **confidence:** probable
- **source:** session
- **status:** active
EOF

  set +e
  output="$(bash "$vault/_tools/check-current-state.sh" 2>&1)"
  status=$?
  set -e

  [ "$status" -eq 1 ] || fail "same-day decision should make a counted marker stale; got status $status: $output"
  assert_contains "$output" "STALE" "same-day decision should be detected"
  assert_contains "$output" "decisions 0/1" "stale output should explain the decision-count mismatch"
}

test_new_project_uses_counted_current_state_marker() {
  vault="$TMP_ROOT/new-project"
  mkdir -p "$vault/_tools"
  cp "$SKILL_DIR/scripts/new-project.sh" "$vault/_tools/"

  bash "$vault/_tools/new-project.sh" "Project" "Purpose" >/dev/null
  marker="$(grep -m1 '<!-- current-state:' "$vault/Project/JOURNAL.md")"
  [ "$marker" = '<!-- current-state: '"$(date '+%Y-%m-%d')"'; decisions: 0 -->' ] || \
    fail "new project should start with a counted current-state marker; got: $marker"
}

test_counted_marker_is_ok_after_regeneration() {
  vault="$TMP_ROOT/regenerated"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  cat > "$vault/Project/JOURNAL.md" <<'EOF'
## Current state
<!-- current-state: 2026-09-20; decisions: 1 -->
---
## 2026-09-20 — Same-day decision
- **type:** decision
EOF

  output="$(bash "$vault/_tools/check-current-state.sh")"
  assert_contains "$output" "OK       Project" "matching decision count should be current"
}

test_legacy_marker_detects_later_decision() {
  vault="$TMP_ROOT/legacy"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  cat > "$vault/Project/JOURNAL.md" <<'EOF'
## Current state
<!-- current-state: 2026-09-19 -->
---
## 2026-09-20 — Later decision
- **type:** decision
EOF

  set +e
  output="$(bash "$vault/_tools/check-current-state.sh")"
  status=$?
  set -e
  [ "$status" -eq 1 ] || fail "legacy marker should remain backward compatible for later-date decisions"
  assert_contains "$output" "STALE" "legacy marker should detect a later decision date"
}

test_archive_project_preserves_name_and_content() {
  vault="$TMP_ROOT/archive"
  mkdir -p "$vault/_tools" "$vault/Foo Bar"
  cp "$SKILL_DIR/scripts/archive-project.sh" "$vault/_tools/"
  printf '%s\n' 'project: Foo Bar' > "$vault/Foo Bar/JOURNAL.md"

  bash "$vault/_tools/archive-project.sh" "Foo Bar" >/dev/null
  [ ! -e "$vault/Foo Bar" ] || fail "archive should remove the live project path"
  [ -f "$vault/_archive/Foo Bar/JOURNAL.md" ] || fail "archive should preserve the project name and journal"
}

test_all_shell_scripts_parse() {
  for script in "$SKILL_DIR"/scripts/*.sh; do
    bash -n "$script" || fail "shell syntax check failed: $script"
  done
}

test_current_state_accepts_a_journal_path() {
  vault="$TMP_ROOT/direct-path"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  cat > "$vault/Project/JOURNAL.md" <<'EOF'
## Current state
<!-- current-state: 2026-09-20; decisions: 0 -->
EOF

  output="$(bash "$vault/_tools/check-current-state.sh" "Project/JOURNAL.md" 2>&1)"
  assert_contains "$output" "OK       Project" "explicit JOURNAL.md path should be accepted"
}

test_current_state_ignores_fenced_metadata_examples() {
  vault="$TMP_ROOT/fenced-example"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  cat > "$vault/Project/JOURNAL.md" <<'EOF'
## Current state
<!-- current-state: 2026-09-20; decisions: 0 -->
---
## 2026-09-20 — Procedure note
- **type:** procedure

Example only:

```markdown
- **type:** decision
```
EOF

  set +e
  output="$(bash "$vault/_tools/check-current-state.sh")"
  status=$?
  set -e
  [ "$status" -eq 0 ] || fail "fenced metadata example should not make marker stale: $output"
  assert_contains "$output" "OK       Project" "fenced metadata example must not count as a decision entry"
}

# Commits in tests need an identity and must never touch the real $HOME.
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

blob() { tr -d '\r' < "$1" | git hash-object --stdin; }

skill_version() { tr -d '\r' < "$SKILL_DIR/SKILL.md" | sed -n 's/^version:[[:space:]]*//p' | head -1; }

# A vault with every current vault tool in _tools/ and detached history.
make_vault() {
  vault="$1"
  mkdir -p "$vault/_tools/launchd" "$vault/Project"
  awk -v v="$(skill_version)" '!/^#/ && NF==3 && $1==v { print $3 }' \
    "$SKILL_DIR/reference/script-hashes.txt" | while IFS= read -r t; do
      cp "$SKILL_DIR/scripts/$t" "$vault/_tools/$t"
    done
  printf '# adapted contract\n' > "$vault/AGENTS.md"
  printf '## Current state\n\n<!-- current-state: 2026-01-01 -->\n' > "$vault/Project/JOURNAL.md"
  VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/setup-history.sh" "$vault" >/dev/null 2>&1 \
    || fail "setup-history failed for $vault"
}

test_manifest_matches_current_scripts() {
  manifest="$SKILL_DIR/reference/script-hashes.txt"
  v="$(skill_version)"
  rows="$(awk -v v="$v" '!/^#/ && NF==3 && $1==v' "$manifest")"
  [ -n "$rows" ] || fail "script-hashes.txt has no rows for SKILL.md version $v"
  printf '%s\n' "$rows" | while read -r _ h t; do
    [ -f "$SKILL_DIR/scripts/$t" ] || fail "manifest lists missing script: $t"
    [ "$(blob "$SKILL_DIR/scripts/$t")" = "$h" ] || fail "manifest hash for $t is not the current file; add/refresh the $v rows"
  done
  # Every vault tool must be listed; upgrade.sh is not a vault tool.
  (cd "$SKILL_DIR/scripts" && find . -type f -not -name upgrade.sh | sed 's|^\./||') |
    while IFS= read -r t; do
      printf '%s\n' "$rows" | awk -v t="$t" '$3==t { f=1 } END { exit !f }' \
        || fail "vault tool $t is not in script-hashes.txt for $v"
    done
}

test_upgrade_replaces_only_untouched_tools() {
  skill="$TMP_ROOT/skill"
  cp -R "$SKILL_DIR" "$skill"
  vault="$TMP_ROOT/upgrade-vault"
  make_vault "$vault"

  # An "older release" copy of check-current-state.sh, registered as 0.0.1 ...
  printf '# older release\n' >> "$vault/_tools/check-current-state.sh"
  old="$(blob "$vault/_tools/check-current-state.sh")"
  { awk -v v="$(skill_version)" '!/^#/ && NF==3 && $1==v { $1 = "0.0.1"; print }' "$skill/reference/script-hashes.txt" |
      awk -v h="$old" '$3=="check-current-state.sh" { $2 = h } { print }'
    cat "$skill/reference/script-hashes.txt"; } > "$skill/reference/m.tmp"
  mv "$skill/reference/m.tmp" "$skill/reference/script-hashes.txt"
  # ... and a locally edited install-hooks.sh that matches no release.
  printf '# local edit\n' >> "$vault/_tools/install-hooks.sh"
  VAULT_GIT_DIR="$vault.git" git --git-dir="$vault.git" add -A
  VAULT_GIT_DIR="$vault.git" git --git-dir="$vault.git" commit -qm "built from 0.0.1"
  printf 'unrelated drift\n' > "$vault/drift.md"

  report="$(VAULT_GIT_DIR="$vault.git" bash "$skill/scripts/upgrade.sh" "$vault")"
  assert_contains "$report" "UPDATE    check-current-state.sh (matches 0.0.1)" "older untouched tool is UPDATE"
  assert_contains "$report" "MODIFIED  install-hooks.sh" "edited tool is MODIFIED"
  assert_contains "$report" "OK        hook-autocommit.sh" "current tool is OK"
  assert_contains "$report" "Built:  unstamped" "no stamp is reported as unstamped"
  assert_contains "$report" "each version after
0.0.1 --" "merge list starts at the oldest release"
  assert_contains "$report" "1 journal(s) use date-only markers" "legacy markers reported"
  [ ! -f "$vault/_tools/.self-recording-version" ] || fail "report mode must not write the stamp"

  VAULT_GIT_DIR="$vault.git" bash "$skill/scripts/upgrade.sh" "$vault" --apply >/dev/null \
    || fail "upgrade --apply failed"
  [ "$(blob "$vault/_tools/check-current-state.sh")" = "$(blob "$skill/scripts/check-current-state.sh")" ] \
    || fail "UPDATE tool should be replaced"
  assert_contains "$(cat "$vault/_tools/install-hooks.sh")" "# local edit" "MODIFIED tool must be left alone"
  [ "$(cat "$vault/AGENTS.md")" = "# adapted contract" ] || fail "upgrade must not touch AGENTS.md"
  [ "$(cat "$vault/_tools/.self-recording-version")" = "$(skill_version)" ] || fail "stamp not written"

  log="$(git --git-dir="$vault.git" log --format=%s -3)"
  assert_contains "$log" "upgrade: self-recording unstamped -> $(skill_version)" "one upgrade commit"
  assert_contains "$log" "pre-upgrade: 1 file(s) changed" "drift committed separately first"
  [ -z "$(git --git-dir="$vault.git" status --porcelain)" ] || fail "tree should be clean after upgrade"
  git --git-dir="$vault.git" show --stat --format= HEAD | grep -q drift.md \
    && fail "upgrade commit must not contain unrelated drift"

  again="$(VAULT_GIT_DIR="$vault.git" bash "$skill/scripts/upgrade.sh" "$vault")"
  assert_contains "$again" "Tools are current." "second run is a no-op"
}

test_upgrade_refuses_another_vaults_history() {
  live="$TMP_ROOT/live/Vault"
  mkdir -p "$TMP_ROOT/live"
  make_vault "$live"
  copy="$TMP_ROOT/scratch/Vault"
  mkdir -p "$TMP_ROOT/scratch"
  cp -R "$live" "$copy"
  printf 'live drift\n' > "$live/drift.md"
  before="$(git --git-dir="$live.git" rev-parse HEAD)"
  set +e
  out="$(VAULT_GIT_DIR="$live.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$copy" --apply 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "--apply must refuse a history whose worktree is another vault"
  assert_contains "$out" "is the history of" "explains the mismatched history"
  [ "$(git --git-dir="$live.git" rev-parse HEAD)" = "$before" ] || fail "live vault history must not get a commit"
  [ ! -f "$copy/_tools/.self-recording-version" ] || fail "copy must not be stamped"
}

test_upgrade_handles_special_characters_and_staging_failure() {
  vault="$TMP_ROOT/R&D | notes"
  make_vault "$vault"
  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault")"
  assert_contains "$out" "1 journal(s) use date-only markers" "journals found under a path with & and |"

  : > "$vault.git/index.lock"
  set +e
  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault" --apply 2>&1)"
  status=$?
  set -e
  rm -f "$vault.git/index.lock"
  [ "$status" -ne 0 ] || fail "--apply must fail when staging fails"
  assert_contains "$out" "NOT committed" "says the upgrade is uncommitted"

  # A stamp that cannot be written must fail, not report "already current".
  git --git-dir="$vault.git" add -A && git --git-dir="$vault.git" commit -qm "sweep" >/dev/null
  rm -f "$vault/_tools/.self-recording-version" && mkdir "$vault/_tools/.self-recording-version"
  set +e
  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault" --apply 2>&1)"
  status=$?
  set -e
  rmdir "$vault/_tools/.self-recording-version"
  [ "$status" -ne 0 ] || fail "--apply must fail when the stamp cannot be written"
  assert_contains "$out" "the upgrade is NOT recorded" "says the stamp was not written"
}

test_upgrade_parses_a_crlf_checkout() {
  skill="$TMP_ROOT/crlf-skill"
  cp -R "$SKILL_DIR" "$skill"
  for f in SKILL.md reference/script-hashes.txt; do
    awk '{ printf "%s\r\n", $0 }' "$SKILL_DIR/$f" > "$skill/$f"
  done
  vault="$TMP_ROOT/crlf-vault"
  make_vault "$vault"
  out="$(VAULT_GIT_DIR="$vault.git" bash "$skill/scripts/upgrade.sh" "$vault")" || fail "report failed on a CRLF checkout"
  assert_contains "$out" "OK        hook-autocommit.sh" "CRLF manifest still matches installed tools"
  case "$out" in *ABSENT*) fail "CRLF manifest must not report installed tools as ABSENT: $out" ;; esac
}

test_upgrade_refuses_an_unreadable_history() {
  vault="$TMP_ROOT/broken-history"
  make_vault "$vault"
  rm -rf "$vault.git/objects" "$vault.git/HEAD"
  mkdir -p "$vault.git"
  before="$(blob "$vault/_tools/check-current-state.sh")"
  set +e
  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault" --apply 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "--apply must stop when the history cannot be read"
  assert_contains "$out" "nothing was changed" "says the vault was left alone"
  [ ! -f "$vault/_tools/.self-recording-version" ] || fail "no stamp without a readable history"
}

test_upgrade_never_writes_through_symlinks() {
  vault="$TMP_ROOT/linked"
  make_vault "$vault"
  shared="$TMP_ROOT/shared-tools"
  mkdir -p "$shared"
  printf '# older shared copy\n' > "$shared/check-current-state.sh"
  rm "$vault/_tools/check-current-state.sh"
  ln -s "$shared/check-current-state.sh" "$vault/_tools/check-current-state.sh"
  # Register the shared copy as an older release, so without the guard it is UPDATE.
  skill="$TMP_ROOT/linked-skill"
  cp -R "$SKILL_DIR" "$skill"
  printf '0.0.1 %s check-current-state.sh\n' "$(blob "$shared/check-current-state.sh")" > "$skill/reference/m.tmp"
  cat "$skill/reference/script-hashes.txt" >> "$skill/reference/m.tmp"
  mv "$skill/reference/m.tmp" "$skill/reference/script-hashes.txt"
  out="$(VAULT_GIT_DIR="$vault.git" bash "$skill/scripts/upgrade.sh" "$vault" --apply 2>&1)" || fail "apply failed: $out"
  assert_contains "$out" "LINKED    check-current-state.sh" "symlinked tool is reported, not replaced"
  [ "$(cat "$shared/check-current-state.sh")" = "# older shared copy" ] || fail "upgrade must not write through a symlinked tool"

  vault2="$TMP_ROOT/linked-dir"
  make_vault "$vault2"
  mv "$vault2/_tools" "$TMP_ROOT/real-tools"
  ln -s "$TMP_ROOT/real-tools" "$vault2/_tools"
  set +e
  out="$(VAULT_GIT_DIR="$vault2.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault2" --apply 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a symlinked _tools/ must be refused"
  [ ! -f "$TMP_ROOT/real-tools/.self-recording-version" ] || fail "no stamp written through a symlinked _tools/"
}

test_upgrade_refuses_without_history_or_from_tools() {
  vault="$TMP_ROOT/no-history"
  mkdir -p "$vault/_tools"
  set +e
  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault" --apply 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "--apply without history must fail"
  assert_contains "$out" "no version history" "explains missing history"

  cp "$SKILL_DIR/scripts/upgrade.sh" "$vault/_tools/"
  set +e
  out="$(bash "$vault/_tools/upgrade.sh" "$vault" 2>&1)"
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "upgrade.sh copied into _tools must refuse to run"
}

# ---- journal rollover -----------------------------------------------------

# Entry lines (from the first dated heading on) of each file, in order.
entries_of() {
  for f in "$@"; do
    awk '/^[[:space:]]*```/ { f = !f } !f && /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { on = 1 } on' "$f"
  done
}

# write_entry DATE TYPE -- one ~400-byte journal entry.
write_entry() {
  printf '## %s — Entry from %s\n\n- **type:** %s\n- **confidence:** probable\n- **source:** session\n- **status:** active\n\n' "$1" "$1" "$2"
  i=0; while [ $i -lt 5 ]; do printf 'Body line %s for %s, long enough to give the entry real weight.\n' "$i" "$1"; i=$((i + 1)); done
  printf '\n'
}

# A project journal with 12 entries, newest first, across 2026-09..2026-07.
make_rollover_vault() {
  vault="$1"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/rotate-journal.sh" "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  {
    printf -- '---\ntype: journal\nproject: Project\n---\n\n# Project — journal\n\nPreamble.\n\n'
    printf '## Current state\n\n<!-- current-state: 2026-09-30; decisions: 6 -->\n\n- *(pointer)*\n\n---\n\n'
    for d in 2026-09-30 2026-09-20 2026-09-10 2026-09-01 2026-08-25 2026-08-15 \
             2026-08-05 2026-08-01 2026-07-28 2026-07-14 2026-07-02 2026-07-01; do
      case "$d" in 2026-09-20|2026-08-15|2026-08-01|2026-07-28|2026-07-14|2026-07-01) t=decision ;; *) t=fact ;; esac
      write_entry "$d" "$t"
    done
  } > "$vault/Project/JOURNAL.md"
}

test_rotate_dry_run_writes_nothing() {
  vault="$TMP_ROOT/rotate-dry"
  make_rollover_vault "$vault"
  before="$(cksum < "$vault/Project/JOURNAL.md")"
  out="$(bash "$vault/_tools/rotate-journal.sh" --max-kb 2 --min-keep 2)"
  assert_contains "$out" "ROTATE   Project" "dry run reports the rotation"
  assert_contains "$out" "dry run" "dry run says so"
  [ "$(cksum < "$vault/Project/JOURNAL.md")" = "$before" ] || fail "dry run must not change JOURNAL.md"
  [ ! -e "$vault/Project/journal" ] || fail "dry run must not create journal/"
}

test_rotate_conserves_entries_and_order() {
  vault="$TMP_ROOT/rotate-apply"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  original="$(entries_of "$j")"
  check_before="$(bash "$vault/_tools/check-current-state.sh")" || fail "fixture should be OK before rotation: $check_before"

  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 >/dev/null || fail "rotate --apply failed"
  [ "$(wc -c < "$j")" -le 2048 ] || fail "JOURNAL.md should fit --max-kb 2"
  kept="$(grep -c '^## 2026-' "$j")"
  [ "$kept" -ge 2 ] || fail "min-keep 2 must be honored; kept $kept"
  [ -f "$vault/Project/journal/2026-07.md" ] || fail "July entries should roll into journal/2026-07.md"

  # Newest-first across JOURNAL.md then month files, newest month first.
  rolled="$(entries_of "$j" $(ls "$vault/Project/journal/"*.md | sort -r))"
  [ "$rolled" = "$original" ] || fail "rotation must conserve every entry line, in order"

  assert_contains "$(head -12 "$vault/Project/journal/2026-07.md")" "type: journal-archive" "month file frontmatter"
  assert_contains "$(head -12 "$vault/Project/journal/2026-07.md")" "period: 2026-07" "month file period"
  [ "$(grep -c '](journal/)' "$j")" -eq 1 ] || fail "pointer line inserted exactly once"
  awk '/\]\(journal\/\)/ { p = NR } /^## Current state/ { c = NR } END { exit !(p && c && p < c) }' "$j" \
    || fail "pointer must sit above ## Current state"
  grep -q '^type: journal$' "$j" || fail "JOURNAL.md frontmatter must be kept"

  check_after="$(bash "$vault/_tools/check-current-state.sh")" || fail "checker must stay OK after rotation: $check_after"
  assert_contains "$check_after" "OK       Project" "decision count unchanged after rotation"

  snapshot="$(cat "$j" "$vault/Project/journal/"*.md | cksum)"
  out="$(bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2)"
  assert_contains "$out" "OK       Project" "second run reports OK"
  [ "$(cat "$j" "$vault/Project/journal/"*.md | cksum)" = "$snapshot" ] || fail "second run must be a no-op"
}

test_rotate_inserts_above_existing_month_entries() {
  vault="$TMP_ROOT/rotate-existing"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 3 --min-keep 2 >/dev/null || fail "first rotation failed"
  first_aug="$(entries_of "$vault/Project/journal/2026-08.md" 2>/dev/null || true)"
  # Hand-edit the month file preamble; it must survive the next insertion.
  if [ -f "$vault/Project/journal/2026-08.md" ]; then
    awk 'NR == 2 { print "note: kept" } { print }' "$vault/Project/journal/2026-08.md" > "$TMP_ROOT/m" &&
      mv "$TMP_ROOT/m" "$vault/Project/journal/2026-08.md"
  fi
  original="$(entries_of "$j" $(ls "$vault/Project/journal/"*.md | sort -r))"

  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 1 --min-keep 1 >/dev/null || fail "second rotation failed"
  aug="$vault/Project/journal/2026-08.md"
  [ -f "$aug" ] || fail "August month file should exist"
  grep -q '^note: kept$' "$aug" || fail "existing month-file preamble must be kept"
  if [ -n "$first_aug" ]; then
    case "$(entries_of "$aug")" in
      *"$first_aug") ;;
      *) fail "existing month entries must stay below the newly moved ones" ;;
    esac
  fi
  first_heading="$(grep -m1 '^## 2026-' "$aug")"
  case "$first_heading" in "## 2026-08-25"*) ;; *) fail "newest August entry should be first; got $first_heading" ;; esac
  rolled="$(entries_of "$j" $(ls "$vault/Project/journal/"*.md | sort -r))"
  [ "$rolled" = "$original" ] || fail "second rotation must conserve entries and order"
  [ "$(grep -c '](journal/)' "$j")" -eq 1 ] || fail "pointer must not be duplicated"
  bash "$vault/_tools/check-current-state.sh" >/dev/null || fail "checker must stay OK after second rotation"
}

test_rotate_keeps_fenced_headings_inside_an_entry() {
  vault="$TMP_ROOT/rotate-fence"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/rotate-journal.sh" "$vault/_tools/"
  {
    printf '## Current state\n\n<!-- current-state: 2026-09-02; decisions: 0 -->\n\n---\n\n'
    write_entry 2026-09-02 fact
    printf '## 2026-08-02 — Has an example\n\n- **type:** fact\n\n```markdown\n## 2026-01-01 — Not an entry\n```\n\nAfter the fence.\n\n'
    write_entry 2026-08-01 fact
  } > "$vault/Project/JOURNAL.md"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 0 --min-keep 1 >/dev/null || fail "fenced rotation failed"
  [ ! -e "$vault/Project/journal/2026-01.md" ] || fail "a fenced heading must not become its own entry"
  grep -q 'Not an entry' "$vault/Project/journal/2026-08.md" || fail "fenced example must travel with its entry"
  grep -q 'After the fence' "$vault/Project/journal/2026-08.md" || fail "text after the fence stays with its entry"
}

test_rotate_handles_journal_without_preamble() {
  vault="$TMP_ROOT/rotate-nopreamble"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/rotate-journal.sh" "$vault/_tools/"
  { write_entry 2026-09-02 fact; write_entry 2026-08-02 fact; write_entry 2026-07-02 fact; } > "$vault/Project/JOURNAL.md"
  original="$(entries_of "$vault/Project/JOURNAL.md")"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 1 --min-keep 1 >/dev/null \
    || fail "journal starting with an entry should rotate"
  rolled="$(entries_of "$vault/Project/JOURNAL.md" $(ls "$vault/Project/journal/"*.md | sort -r))"
  [ "$rolled" = "$original" ] || fail "no-preamble rotation must conserve entries"
  grep -q '](journal/)' "$vault/Project/JOURNAL.md" || fail "pointer added to an empty preamble"

  # --min-keep 0 may roll everything out.
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 0 --min-keep 0 >/dev/null || fail "--min-keep 0 should work"
  [ -z "$(entries_of "$vault/Project/JOURNAL.md")" ] || fail "--max-kb 0 --min-keep 0 should move every entry"
  rolled="$(entries_of $(ls "$vault/Project/journal/"*.md | sort -r))"
  [ "$rolled" = "$original" ] || fail "moving every entry must conserve them"
}

test_rotate_pointer_detection_reads_only_the_preamble() {
  vault="$TMP_ROOT/rotate-quoted-pointer"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/rotate-journal.sh" "$vault/_tools/"
  {
    printf '## Current state\n\n<!-- current-state: 2026-09-02; decisions: 0 -->\n\n---\n\n'
    write_entry 2026-09-02 fact
    printf '## 2026-08-03 — Quotes the link\n\n- **type:** fact\n\nSee [`journal/`](journal/) once it exists.\n\n'
    write_entry 2026-08-01 fact
  } > "$vault/Project/JOURNAL.md"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 1 --min-keep 1 >/dev/null || fail "rotation failed"
  sed -n '1,/^## Current state/p' "$vault/Project/JOURNAL.md" | grep -qF 'Older entries are in' \
    || fail "an entry quoting the link must not suppress the preamble pointer"
}

test_rotate_rejects_bad_options_and_ignores_infrastructure() {
  vault="$TMP_ROOT/rotate-opts"
  make_rollover_vault "$vault"
  set +e
  bash "$vault/_tools/rotate-journal.sh" --max-kb >/dev/null 2>&1; s1=$?
  bash "$vault/_tools/rotate-journal.sh" --min-keep x >/dev/null 2>&1; s2=$?
  set -e
  [ "$s1" -eq 2 ] && [ "$s2" -eq 2 ] || fail "missing or non-numeric option values must be refused ($s1, $s2)"

  mkdir -p "$vault/_agent/Scratch"
  cp "$vault/Project/JOURNAL.md" "$vault/_agent/Scratch/JOURNAL.md"
  out="$(bash "$vault/_tools/rotate-journal.sh" --max-kb 2 --min-keep 2)"
  case "$out" in *_agent*) fail "underscore folders are not projects: $out" ;; esac
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 >/dev/null || fail "apply failed"
  out="$(bash "$vault/_tools/check-current-state.sh")"
  case "$out" in *journal*) fail "journal/ month files must not be reported as projects: $out" ;; esac
  out="$(bash "$vault/_tools/rotate-journal.sh" Project/JOURNAL.md)"
  assert_contains "$out" "OK       Project" "explicit JOURNAL.md path accepted"
}

test_current_state_counts_decisions_in_rolled_files() {
  vault="$TMP_ROOT/rolled-count"
  mkdir -p "$vault/_tools" "$vault/Project/journal"
  cp "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  printf '## Current state\n<!-- current-state: 2026-09-20; decisions: 3 -->\n---\n## 2026-09-20 — New\n- **type:** decision\n' \
    > "$vault/Project/JOURNAL.md"
  # An unclosed fence in one month file must not hide the next file's entries
  # (state resets per file), and a frontmatter `type:` must not count.
  printf -- '---\ntype: journal-archive\n---\n## 2026-07-01 — Older\n- **type:** decision\n```\n' \
    > "$vault/Project/journal/2026-07.md"
  printf '## 2026-08-01 — Old\n- **type:** decision\n' > "$vault/Project/journal/2026-08.md"
  out="$(bash "$vault/_tools/check-current-state.sh")" || fail "decisions in journal/*.md must count: $out"
  assert_contains "$out" "OK       Project" "rolled decision counted"
}

test_current_state_handles_project_names_with_spaces
printf 'PASS: project names with spaces\n'
test_current_state_accepts_a_journal_path
printf 'PASS: explicit journal path\n'
test_current_state_ignores_fenced_metadata_examples
printf 'PASS: fenced metadata examples are ignored\n'
test_current_state_detects_same_day_decision
printf 'PASS: same-day decision staleness\n'
test_new_project_uses_counted_current_state_marker
printf 'PASS: new projects use counted markers\n'
test_counted_marker_is_ok_after_regeneration
printf 'PASS: regenerated counted marker\n'
test_legacy_marker_detects_later_decision
printf 'PASS: legacy marker compatibility\n'
test_current_state_counts_decisions_in_rolled_files
printf 'PASS: decisions in journal/*.md are counted\n'
test_rotate_dry_run_writes_nothing
printf 'PASS: rotate dry run writes nothing\n'
test_rotate_conserves_entries_and_order
printf 'PASS: rotate conserves entries and order; second run is a no-op\n'
test_rotate_inserts_above_existing_month_entries
printf 'PASS: rotate inserts above existing month entries\n'
test_rotate_keeps_fenced_headings_inside_an_entry
printf 'PASS: rotate keeps fenced headings inside an entry\n'
test_rotate_handles_journal_without_preamble
printf 'PASS: rotate handles a journal with no preamble, and --min-keep 0\n'
test_rotate_pointer_detection_reads_only_the_preamble
printf 'PASS: rotate pointer detection reads only the preamble\n'
test_rotate_rejects_bad_options_and_ignores_infrastructure
printf 'PASS: rotate validates options and skips non-projects\n'
test_archive_project_preserves_name_and_content
printf 'PASS: archive preserves project identity\n'
test_all_shell_scripts_parse
printf 'PASS: shell syntax\n'
test_manifest_matches_current_scripts
printf 'PASS: release manifest matches scripts\n'
test_upgrade_replaces_only_untouched_tools
printf 'PASS: upgrade replaces only untouched tools\n'
test_upgrade_refuses_without_history_or_from_tools
printf 'PASS: upgrade refuses unsafe runs\n'
test_upgrade_refuses_another_vaults_history
printf "PASS: upgrade refuses another vault's history\n"
test_upgrade_parses_a_crlf_checkout
printf 'PASS: upgrade parses a CRLF checkout\n'
test_upgrade_refuses_an_unreadable_history
printf 'PASS: upgrade refuses an unreadable history\n'
test_upgrade_handles_special_characters_and_staging_failure
printf 'PASS: upgrade handles & and | in paths, and staging failure\n'
test_upgrade_never_writes_through_symlinks
printf 'PASS: upgrade never writes through symlinks\n'

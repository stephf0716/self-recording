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

skill_version() { sed -n 's/^version:[[:space:]]*//p' "$SKILL_DIR/SKILL.md" | head -1; }

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
  assert_contains "$report" "Built:  0.0.1 (inferred; no stamp)" "version inferred from untouched tools"
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
  assert_contains "$log" "upgrade: self-recording 0.0.1 -> $(skill_version)" "one upgrade commit"
  assert_contains "$log" "pre-upgrade: 1 file(s) changed" "drift committed separately first"
  [ -z "$(git --git-dir="$vault.git" status --porcelain)" ] || fail "tree should be clean after upgrade"
  git --git-dir="$vault.git" show --stat --format= HEAD | grep -q drift.md \
    && fail "upgrade commit must not contain unrelated drift"

  again="$(VAULT_GIT_DIR="$vault.git" bash "$skill/scripts/upgrade.sh" "$vault")"
  assert_contains "$again" "Tools are current." "second run is a no-op"
}

test_upgrade_reports_ambiguous_version_as_a_range() {
  vault="$TMP_ROOT/ambiguous"
  mkdir -p "$vault/_tools"
  VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/setup-history.sh" "$vault" >/dev/null 2>&1 \
    || fail "setup-history failed for $vault"

  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault")"
  assert_contains "$out" "Built:  unknown (no stamp, and no untouched tool" "no evidence is not a version"

  # setup-history.sh alone: every release it is identical in stays a candidate.
  cp "$SKILL_DIR/scripts/setup-history.sh" "$vault/_tools/"
  h="$(blob "$vault/_tools/setup-history.sh")"
  range="$(awk -v h="$h" '!/^#/ && NF==3 && $2==h && $3=="setup-history.sh" { print $1 }' \
    "$SKILL_DIR/reference/script-hashes.txt")"
  lo="$(echo $range | awk '{ print $1 }')"
  hi="$(echo $range | awk '{ print $NF }')"
  [ "$lo" != "$hi" ] || return 0   # manifest no longer has a shared copy to test with
  out="$(VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault")"
  assert_contains "$out" "Built:  $lo..$hi (inferred" "shared tool gives a range, not the newest"
  assert_contains "$out" "each version after
$lo --" "merge list starts at the oldest candidate"
  assert_contains "$out" "compare before merging" "owner told the range may overlap the contract"

  VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/upgrade.sh" "$vault" --apply >/dev/null \
    || fail "upgrade --apply failed"
  assert_contains "$(git --git-dir="$vault.git" log --format=%s -1)" \
    "upgrade: self-recording $lo..$hi -> $(skill_version)" "commit names the range"
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
test_archive_project_preserves_name_and_content
printf 'PASS: archive preserves project identity\n'
test_all_shell_scripts_parse
printf 'PASS: shell syntax\n'
test_manifest_matches_current_scripts
printf 'PASS: release manifest matches scripts\n'
test_upgrade_replaces_only_untouched_tools
printf 'PASS: upgrade replaces only untouched tools\n'
test_upgrade_reports_ambiguous_version_as_a_range
printf 'PASS: upgrade reports an ambiguous version as a range\n'
test_upgrade_refuses_without_history_or_from_tools
printf 'PASS: upgrade refuses unsafe runs\n'

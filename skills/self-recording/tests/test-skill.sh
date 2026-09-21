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

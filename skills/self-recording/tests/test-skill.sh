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
  for script in "$SKILL_DIR"/scripts/*.sh "$SKILL_DIR"/scripts/hermes/*.sh; do
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
  # Every vault tool must be listed; upgrade.sh and hermes/ are not vault tools.
  (cd "$SKILL_DIR/scripts" && find . -type f -not -name upgrade.sh -not -path './hermes/*' | sed 's|^\./||') |
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

test_dream_commit_makes_one_commit_per_run() {
  vault="$TMP_ROOT/dream-vault"
  make_vault "$vault"
  w="$SKILL_DIR/scripts/hermes/dream-commit.sh"
  mem="$TMP_ROOT/dream-memories"
  mkdir -p "$mem"
  printf 'Prefers terse replies\n' > "$mem/USER.md"
  export VAULT_GIT_DIR="$vault.git" DREAM_MEMORIES="$mem"

  printf 'hand edit\n' > "$vault/hand.md"
  bash "$w" begin "$vault" >/dev/null || fail "dream begin failed"
  [ -f "$mem/.dream-backup/$(date '+%Y-%m-%d')/USER.md" ] || fail "begin should back up harness memory"
  printf '\n## 2026-10-18 — x\n' >> "$vault/Project/JOURNAL.md"
  mkdir -p "$vault/_agent/sessions" && printf 'log\n' > "$vault/_agent/sessions/d.md"
  out="$(bash "$w" end "$vault" 2>&1)" || fail "dream end failed"
  assert_contains "$out" "dream: $(date '+%Y-%m-%d')" "end reports the dream commit"

  log="$(git --git-dir="$vault.git" log --format=%s -2)"
  assert_contains "$log" "dream: $(date '+%Y-%m-%d')" "dream commit exists"
  assert_contains "$log" "pre-dream: 1 file(s) changed" "pre-existing drift split off"
  files="$(git --git-dir="$vault.git" show --name-only --format= HEAD)"
  assert_contains "$files" "Project/JOURNAL.md" "dream commit holds the journal change"
  case "$files" in *hand.md*) fail "dream commit must not contain pre-existing drift" ;; esac

  # A sweep landing mid-run breaks the one-revert promise; end must say so.
  bash "$w" begin "$vault" >/dev/null
  printf 'a\n' >> "$vault/Project/JOURNAL.md"
  git --git-dir="$vault.git" add -A && git --git-dir="$vault.git" commit -qm "sweep: 1 file(s) changed"
  printf 'b\n' >> "$vault/Project/JOURNAL.md"
  out="$(bash "$w" end "$vault" 2>&1)"
  assert_contains "$out" "1 other commit(s) landed during the run" "interleaved commit is reported"

  out="$(bash "$w" end "$vault" 2>&1)"
  assert_contains "$out" "nothing to commit" "clean tree makes no commit"
  unset VAULT_GIT_DIR DREAM_MEMORIES
}

test_dream_commit_refuses_without_history() {
  vault="$TMP_ROOT/dream-nohist"
  mkdir -p "$vault"
  set +e
  VAULT_GIT_DIR="$vault.git" bash "$SKILL_DIR/scripts/hermes/dream-commit.sh" begin "$vault" >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "dream begin must stop when there is no history"
}

test_dream_prompt_keeps_its_safety_rules() {
  d="$(cat "$SKILL_DIR/templates/DREAM.md")"
  assert_contains "$d" "## Untrusted content" "untrusted-content rule lives in the prompt"
  assert_contains "$d" "Never write \`confidence: confirmed\`" "confirmed is forbidden"
  assert_contains "$d" "Never mark a \`confirmed\` entry superseded" "confirmed entries are not superseded"
  assert_contains "$d" "Do not create or edit skills" "no skill writing"
  assert_contains "$d" "First run: skip this step" "first run does not rebuild the digest"
  assert_contains "$d" "{{COMMIT_WRAPPER}} begin" "commit wrapper brackets the run"
  assert_contains "$d" "summaries skipped: check-current-state.sh not installed" "missing summary tool is skipped, not created"
  assert_contains "$d" "step 7 builds it only from vault entries, never from session text" "guidance is built from entries only"
  assert_contains "$d" "**Every bullet cites the entry behind it.**" "guidance bullets carry provenance"
  assert_contains "$d" "Skip \`unverified\`" "unverified entries stay out of guidance"
  assert_contains "$d" "**How to work, never what to do.**" "guidance cannot carry actions"
  assert_contains "$d" "never overrides \`AGENTS.md\`" "guidance never outranks the contract"
  assert_contains "$d" "dismissals" "harvest looks at friction"
  assert_contains "$d" "is the run's log, not a message" "report is not delivered as a message"
  if grep -n "delivered to" "$SKILL_DIR/templates/DREAM.md"; then
    fail "DREAM.md must not assume the report is delivered to the owner"
  fi
  # Steps are referenced by number; a renumbering must not leave a dangling one.
  for n in $(grep -o 'step [0-9]' "$SKILL_DIR/templates/DREAM.md" | awk '{ print $2 }' | sort -u); do
    grep -q "^### $n\. " "$SKILL_DIR/templates/DREAM.md" || fail "DREAM.md refers to missing step $n"
  done
  if grep -n 'confidence:\*\* confirmed' "$SKILL_DIR/templates/DREAM.md"; then
    fail "DREAM.md must not contain a confirmed example entry"
  fi
}

test_every_client_is_pointed_at_the_guidance() {
  assert_contains "$(cat "$SKILL_DIR/templates/AGENTS.md")" "**If \`_agent/GUIDANCE.md\` exists, read it next, every session.**" "contract points at guidance"
  assert_contains "$(cat "$SKILL_DIR/templates/AGENTS.md")" "Don't edit \`_agent/GUIDANCE.md\`; change the entries." "live sessions change entries, not guidance"
  grep -qx '@_agent/GUIDANCE.md' "$SKILL_DIR/templates/CLAUDE.md" || fail "CLAUDE.md must import the guidance"
  assert_contains "$(cat "$SKILL_DIR/templates/HERMES.md")" "_agent/GUIDANCE.md" "Hermes pointer names the guidance"
  assert_contains "$(cat "$SKILL_DIR/SKILL.md")" "Set \`deliver\` and \`failure_deliver\` to local" "setup defaults to silent delivery"
}

test_skill_audit_grep_finds_confirmed_dream_entries() {
  vault="$TMP_ROOT/audit"
  mkdir -p "$vault/P"
  cat > "$vault/P/JOURNAL.md" <<'EOF'
## 2026-10-18 — ok

- **type:** preference
- **confidence:** probable
- **source:** dream `_agent/sessions/2026-10-18-dream-h.md`
- **status:** active

## 2026-10-17 — bad

- **type:** preference
- **confidence:** confirmed
- **source:** dream `_agent/sessions/2026-10-17-dream-h.md`
- **status:** active
EOF
  pattern="$(sed -n "s/^grep -rn -B1 '\(.*dream\)' --include=JOURNAL.md.*/\1/p" "$SKILL_DIR/SKILL.md")"
  [ -n "$pattern" ] || fail "SKILL.md audit grep not found"
  hits="$(cd "$vault" && grep -rn -B1 "$pattern" --include=JOURNAL.md . | grep 'confidence:\*\* confirmed' || true)"
  [ "$(printf '%s\n' "$hits" | grep -c 'confidence')" -eq 1 ] || fail "audit grep should flag exactly the one confirmed dream entry: $hits"
  case "$hits" in *probable*) fail "audit grep must not flag probable entries" ;; esac
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
test_dream_commit_makes_one_commit_per_run
printf 'PASS: dream wrapper makes one commit per run\n'
test_dream_commit_refuses_without_history
printf 'PASS: dream wrapper refuses without history\n'
test_dream_prompt_keeps_its_safety_rules
printf 'PASS: dream prompt safety rules\n'
test_every_client_is_pointed_at_the_guidance
printf 'PASS: every client is pointed at the guidance\n'
test_skill_audit_grep_finds_confirmed_dream_entries
printf 'PASS: dream audit grep\n'

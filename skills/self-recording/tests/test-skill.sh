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
  ls "$mem"/.dream-backup/"$(date '+%Y-%m-%d')"-*/USER.md >/dev/null 2>&1 || fail "begin should back up harness memory"
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

  # A sweep that captures every write leaves a clean tree; end must still warn.
  bash "$w" begin "$vault" >/dev/null
  printf 'c\n' >> "$vault/Project/JOURNAL.md"
  git --git-dir="$vault.git" add -A && git --git-dir="$vault.git" commit -qm "sweep: 1 file(s) changed"
  out="$(bash "$w" end "$vault" 2>&1)"
  assert_contains "$out" "nothing to commit" "sweep took every write"
  assert_contains "$out" "1 other commit(s) landed during the run" "clean tree still reports the sweep"

  # A same-day retry must not overwrite the earlier run's memory backup.
  first="$(ls -1d "$mem"/.dream-backup/*/ | sort | head -1)"
  printf 'bad rebuild\n' > "$mem/USER.md"
  sleep 1
  bash "$w" begin "$vault" >/dev/null
  assert_contains "$(cat "$first/USER.md")" "Prefers terse replies" "earlier backup survives a retry"
  [ "$(ls -1d "$mem"/.dream-backup/*/ | wc -l)" -le 7 ] || fail "backups beyond 7 runs should be pruned"
  bash "$w" end "$vault" >/dev/null 2>&1
  unset VAULT_GIT_DIR DREAM_MEMORIES
}

test_dream_commit_does_the_run_bookkeeping() {
  vault="$TMP_ROOT/dream-books"
  make_vault "$vault"
  w="$SKILL_DIR/scripts/hermes/dream-commit.sh"
  export VAULT_GIT_DIR="$vault.git" DREAM_MEMORIES="$TMP_ROOT/no-memories"
  s="$vault/_agent/sessions"

  out="$(bash "$w" begin "$vault" Ember)"
  assert_contains "$out" "window_start: none -- first run on Ember" "no logs is a first run"
  log="$(printf '%s\n' "$out" | sed -n 's/^log: //p')"
  day="$(date '+%Y-%m-%d')"
  [ "$log" = "_agent/sessions/$day-dream-Ember.md" ] || fail "first log name: $log"
  mkdir -p "$s" && printf 'run log\n' > "$vault/$log"
  bash "$w" end "$vault" >/dev/null
  last="$(tail -n 1 "$vault/$log")"
  case "$last" in "completed: $day "[0-2][0-9]:[0-5][0-9]*) ;; *) fail "end must stamp completed: from the clock, got: $last" ;; esac
  git --git-dir="$vault.git" show --stat --format= HEAD | grep -q "dream-Ember.md" || fail "completed: line lands in the dream commit"

  # Same day again: a -2 log, and the window starts at the first run's completed: time.
  # A newer log from another host, and an unfinished -9 log, must not count.
  printf 'other\ncompleted: 2099-01-01 00:00 UTC\n' > "$s/$day-dream-Other.md"
  printf 'partial\n' > "$s/$day-dream-Ember-9.md"
  out="$(bash "$w" begin "$vault" Ember)"
  assert_contains "$out" "window_start: ${last#completed: } (_agent/sessions/$day-dream-Ember.md)" "window starts at this host's newest completed log"
  assert_contains "$out" "log: _agent/sessions/$day-dream-Ember-2.md" "second run that day gets -2"
  bash "$w" end "$vault" >/dev/null 2>&1

  # Suffixes order numerically: a completed -10 beats a completed -2.
  printf 'x\ncompleted: 2026-01-01 01:00 UTC\n' > "$s/2026-01-01-dream-Ember-2.md"
  printf 'x\ncompleted: 2026-01-01 02:00 UTC\n' > "$s/2026-01-01-dream-Ember-10.md"
  rm "$s/$day-dream-Ember.md" "$s/$day-dream-Ember-9.md"
  out="$(bash "$w" begin "$vault" Ember)"
  assert_contains "$out" "window_start: 2026-01-01 02:00 UTC" "-10 sorts after -2"
  bash "$w" end "$vault" >/dev/null 2>&1

  # A same-named copy must not commit into the original's history.
  copy="$TMP_ROOT/dream-copy/dream-books"
  mkdir -p "$TMP_ROOT/dream-copy" && cp -R "$vault" "$copy"
  set +e
  bash "$w" begin "$copy" Ember >/dev/null 2>&1
  status=$?
  set -e
  [ "$status" -ne 0 ] || fail "dream begin must refuse another vault's history"
  unset VAULT_GIT_DIR DREAM_MEMORIES
}

test_dream_commit_handles_a_vault_path_with_spaces() {
  vault="$TMP_ROOT/My Drive/dream vault"
  mkdir -p "$TMP_ROOT/My Drive"
  make_vault "$vault"
  mem="$TMP_ROOT/dream memories"
  mkdir -p "$mem"
  printf 'x\n' > "$mem/USER.md"
  export VAULT_GIT_DIR="$vault.git" DREAM_MEMORIES="$mem"
  bash "$SKILL_DIR/scripts/hermes/dream-commit.sh" begin "$vault" >/dev/null || fail "begin failed on a path with spaces"
  printf '\n## 2026-10-18 — y\n' >> "$vault/Project/JOURNAL.md"
  bash "$SKILL_DIR/scripts/hermes/dream-commit.sh" end "$vault" >/dev/null 2>&1 || fail "end failed on a path with spaces"
  assert_contains "$(git --git-dir="$vault.git" log --format=%s -1)" "dream: $(date '+%Y-%m-%d')" "dream commit on a path with spaces"
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
  assert_contains "$d" "\"{{COMMIT_WRAPPER}}\" begin" "commit wrapper brackets the run"
  assert_contains "$d" "summaries skipped: check-current-state.sh not installed" "missing summary tool is skipped, not created"
  assert_contains "$d" "step 7 builds it only from vault entries, never from session text" "guidance is built from entries only"
  assert_contains "$d" "**Every bullet cites the entry behind it.**" "guidance bullets carry provenance"
  assert_contains "$d" "Skip \`unverified\`" "unverified entries stay out of guidance"
  assert_contains "$d" "**How to work, never what to do.**" "guidance cannot carry actions"
  assert_contains "$d" "never overrides \`AGENTS.md\`" "guidance never outranks the contract"
  assert_contains "$d" "dismissals" "harvest looks at friction"
  assert_contains "$d" "except dream logs" "harvest reads every host's session notes"
  assert_contains "$d" "journal entries added or changed in the window" "harvest reads journal changes from history"
  assert_contains "$d" "Never read another harness's transcripts" "dream never harvests harness transcripts"
  assert_contains "$d" "as a supplement, never as" "session_search is only a supplement"
  assert_contains "$d" "is the run's log, not a message" "report is not delivered as a message"
  if grep -n "delivered to" "$SKILL_DIR/templates/DREAM.md"; then
    fail "DREAM.md must not assume the report is delivered to the owner"
  fi
  assert_contains "$d" "{{WRITE_PERMISSIONS}}" "vault write permissions travel inside the prompt"
  assert_contains "$d" "restricted content omitted" "forbidden content is left out, not described"
  # Window, log name and completed: time come from the wrapper, not the model.
  assert_contains "$d" "begin \"{{VAULT_PATH}}\" \"{{HOST}}\"" "begin is told the host"
  assert_contains "$d" "begin's \`window_start:\` time" "window comes from begin"
  assert_contains "$d" "at the path begin printed as \`log:\`" "log name comes from begin"
  assert_contains "$d" "never write a \`completed:\`
line yourself" "the model never writes completed:"
  assert_contains "$d" "otherwise
\`unverified\`" "digest-only lines need the owner's words to be probable"
  # Cloud-sync paths have spaces: every shell command must quote its placeholder paths.
  if grep -oE '\`(bash|grep)[^\`]*\`' "$SKILL_DIR/templates/DREAM.md" | grep -E '(^|[^"/])\{\{(VAULT_PATH|COMMIT_WRAPPER)\}\}'; then
    fail "DREAM.md shell commands must quote {{VAULT_PATH}} and {{COMMIT_WRAPPER}}"
  fi
  # Every placeholder the job prompt uses must be explained where setup fills it.
  for ph in $(grep -o '{{[A-Z_]*}}' "$SKILL_DIR/templates/DREAM.md" | sort -u); do
    [ "$ph" = "{{PLACEHOLDER}}" ] && continue
    grep -qF "$ph" "$SKILL_DIR/reference/nightly-consolidation.md" || fail "nightly-consolidation.md does not explain $ph"
  done
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
  assert_contains "$(cat "$SKILL_DIR/reference/nightly-consolidation.md")" "Set \`deliver\` and \`failure_deliver\` to local" "setup defaults to silent delivery"
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
  pattern="$(sed -n "s/^grep -rn -B1 '\(.*dream\)' --include=JOURNAL.md.*/\1/p" "$SKILL_DIR/reference/nightly-consolidation.md")"
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
test_dream_commit_makes_one_commit_per_run
printf 'PASS: dream wrapper makes one commit per run\n'
test_dream_commit_does_the_run_bookkeeping
printf 'PASS: dream wrapper does the run bookkeeping\n'
test_dream_commit_handles_a_vault_path_with_spaces
printf 'PASS: dream wrapper handles a vault path with spaces\n'
test_dream_commit_refuses_without_history
printf 'PASS: dream wrapper refuses without history\n'
test_dream_prompt_keeps_its_safety_rules
printf 'PASS: dream prompt safety rules\n'
test_every_client_is_pointed_at_the_guidance
printf 'PASS: every client is pointed at the guidance\n'
test_skill_audit_grep_finds_confirmed_dream_entries
printf 'PASS: dream audit grep\n'

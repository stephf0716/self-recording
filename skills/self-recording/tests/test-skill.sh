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

test_dream_commit_refuses_during_a_rotation() {
  vault="$TMP_ROOT/dream-rotating"
  make_vault "$vault"
  w="$SKILL_DIR/scripts/hermes/dream-commit.sh"
  mem="$TMP_ROOT/dream-rotating-mem"
  mkdir -p "$mem"
  export VAULT_GIT_DIR="$vault.git" DREAM_MEMORIES="$mem"
  before="$(git --git-dir="$vault.git" rev-parse HEAD)"

  mkdir "$vault/Project/.rotate-journal.lock"
  printf 'drift\n' >> "$vault/Project/JOURNAL.md"
  set +e
  out="$(bash "$w" begin "$vault" h 2>&1)"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "begin must stop while a rotation lock exists"
  assert_contains "$out" "journal rotation in progress" "begin names the rotation"
  [ "$(git --git-dir="$vault.git" rev-parse HEAD)" = "$before" ] || fail "begin must not commit drift beside a rotation"
  rmdir "$vault/Project/.rotate-journal.lock"

  out="$(bash "$w" begin "$vault" h)" || fail "begin failed once the lock is gone"
  log="$(printf '%s\n' "$out" | sed -n 's/^log: //p')"
  mkdir -p "$vault/_agent/sessions"
  printf '# dream log\n' > "$vault/$log"
  mid="$(git --git-dir="$vault.git" rev-parse HEAD)"
  mkdir "$vault/Project/.rotate-journal.lock"
  set +e
  out="$(bash "$w" end "$vault" 2>&1)"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "end must stop while a rotation lock exists"
  [ "$(git --git-dir="$vault.git" rev-parse HEAD)" = "$mid" ] || fail "end must not commit a half-rotated tree"
  if grep -q '^completed:' "$vault/$log"; then fail "a refused end must leave the window to retry"; fi
  rmdir "$vault/Project/.rotate-journal.lock"
  unset VAULT_GIT_DIR DREAM_MEMORIES
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
  assert_contains "$d" "'*JOURNAL.md' '*/journal/20??-??.md'" "harvest diff includes rolled month files"
  assert_contains "$d" "move, not deleted or new memory" "a rotation commit is a move"
  assert_contains "$d" "never with \`--apply\`" "the dream never rotates"
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
  # A rotated-out dream entry must still be found.
  mkdir -p "$vault/P/journal"
  cat > "$vault/P/journal/2026-09.md" <<'EOF'
## 2026-09-01 — rolled bad

- **type:** preference
- **confidence:** confirmed
- **source:** dream `_agent/sessions/2026-09-01-dream-h.md`
- **status:** active
EOF
  cmd="$(tr -d '\r' < "$SKILL_DIR/reference/nightly-consolidation.md" | sed -n "s/^\(grep -rn -B1 '.*dream' --include=JOURNAL.md .*confirmed'\).*/\1/p")"
  [ -n "$cmd" ] || fail "nightly-consolidation.md audit grep not found"
  hits="$(cd "$vault" && eval "$cmd" || true)"
  [ "$(printf '%s\n' "$hits" | grep -c 'confidence')" -eq 2 ] || fail "audit grep should flag exactly the two confirmed dream entries: $hits"
  case "$hits" in *probable*) fail "audit grep must not flag probable entries" ;; esac
}

# ---- journal rollover -----------------------------------------------------

# Entry lines (from the first dated heading on) of each file, in order. Same
# fence rule as the scripts: a longer fence can quote a shorter one.
entries_of() {
  for f in "$@"; do
    awk '
      function fence(line,   s, c, n, rest) {
        s = line; sub(/^[[:space:]]*/, "", s); c = substr(s, 1, 1)
        if (c != "`" && c != "~") return 0
        n = 0; while (substr(s, n + 1, 1) == c) n++
        if (n < 3) return 0
        rest = substr(s, n + 1)
        if (!fenced) { if (c == "`" && index(rest, "`")) return 0; fenced = 1; fch = c; flen = n; return 1 }
        if (c == fch && n >= flen && rest ~ /^[[:space:]]*$/) { fenced = 0; return 1 }
        return 0
      }
      { fence($0) } !fenced && /^## [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ { on = 1 } on' "$f"
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

test_rotate_honors_fence_length() {
  vault="$TMP_ROOT/rotate-long-fence"
  mkdir -p "$vault/_tools" "$vault/Project"
  cp "$SKILL_DIR/scripts/rotate-journal.sh" "$SKILL_DIR/scripts/check-current-state.sh" "$vault/_tools/"
  {
    printf '## Current state\n\n<!-- current-state: 2026-09-02; decisions: 0 -->\n\n---\n\n'
    write_entry 2026-09-02 fact
    printf '## 2026-08-02 — Quotes a fenced example\n\n- **type:** fact\n\n````markdown\n```\n## 2026-01-01 — Not an entry\n- **type:** decision\n```\n````\n\n~~~\n## 2026-02-01 — Not one either\n```\n~~~\n\nAfter both fences.\n\n'
    write_entry 2026-08-01 fact
  } > "$vault/Project/JOURNAL.md"
  original="$(entries_of "$vault/Project/JOURNAL.md")"
  bash "$vault/_tools/check-current-state.sh" >/dev/null || fail "a decision inside a long fence must not count"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 0 --min-keep 1 >/dev/null || fail "long-fence rotation failed"
  [ ! -e "$vault/Project/journal/2026-01.md" ] || fail "a heading inside a 4-backtick fence must not become an entry"
  [ ! -e "$vault/Project/journal/2026-02.md" ] || fail "a heading inside a ~~~ fence must not become an entry"
  grep -q 'After both fences' "$vault/Project/journal/2026-08.md" || fail "the quoting entry must stay whole"
  rolled="$(entries_of "$vault/Project/JOURNAL.md" $(ls "$vault/Project/journal/"*.md | sort -r))"
  [ "$rolled" = "$original" ] || fail "long-fence rotation must conserve entries and order"
}

test_rotate_refuses_unsafe_destinations_and_sources() {
  vault="$TMP_ROOT/rotate-unsafe"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  before="$(cksum < "$j")"
  # A directory where a month file should go would swallow the mv.
  mkdir -p "$vault/Project/journal/2026-07.md"
  set +e
  out="$(bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 2>&1)"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a directory named like a month file must be refused"
  assert_contains "$out" "nothing written" "refusal says nothing was written"
  [ "$(cksum < "$j")" = "$before" ] || fail "JOURNAL.md must be untouched when a destination is a directory"
  [ -z "$(ls -A "$vault/Project/journal/2026-07.md")" ] || fail "nothing may be written inside the directory"
  rmdir "$vault/Project/journal/2026-07.md"

  # An unreadable month file must abort, not be overwritten. Skipped where
  # chmod cannot revoke read access (Windows, root).
  printf '## 2026-07-01 — Already rolled\n- **type:** fact\n' > "$vault/Project/journal/2026-07.md"
  chmod 000 "$vault/Project/journal/2026-07.md"
  if [ ! -r "$vault/Project/journal/2026-07.md" ]; then
    set +e
    bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 >/dev/null 2>&1; status=$?
    set -e
    chmod 644 "$vault/Project/journal/2026-07.md"
    [ "$status" -ne 0 ] || fail "an unreadable month file must abort the rotation"
    [ "$(cksum < "$j")" = "$before" ] || fail "JOURNAL.md must be untouched when a source is unreadable"
    grep -q 'Already rolled' "$vault/Project/journal/2026-07.md" || fail "unreadable month file must not be overwritten"
  else
    chmod 644 "$vault/Project/journal/2026-07.md"
    printf '  (unreadable-file case skipped: chmod cannot revoke read here)\n'
  fi
}

test_rotate_reads_zero_padded_values_as_decimal() {
  vault="$TMP_ROOT/rotate-decimal"
  make_rollover_vault "$vault"
  a="$(bash "$vault/_tools/rotate-journal.sh" --max-kb 3 --min-keep 2)"
  b="$(bash "$vault/_tools/rotate-journal.sh" --max-kb 003 --min-keep 02)"
  [ "$a" = "$b" ] || fail "--max-kb 003 must mean 3, not octal: $b"
  bash "$vault/_tools/rotate-journal.sh" --max-kb 08 --min-keep 09 >/dev/null || fail "08 and 09 are valid decimal values"
}

test_rotate_aborts_on_concurrent_write() {
  vault="$TMP_ROOT/rotate-concurrent"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  # Another session appends between the read and the replace.
  set +e
  out="$(ROTATE_JOURNAL_TEST_HOOK='printf "\n## 2026-10-01 — Late append\n" >> Project/JOURNAL.md' \
    bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 2>&1)"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a write during rotation must abort it"
  assert_contains "$out" "changed while rotating" "says why it aborted"
  grep -q 'Late append' "$j" || fail "the concurrent append must survive"
  [ ! -e "$vault/Project/journal" ] || fail "nothing may be written when a source changed"
  [ ! -e "$vault/Project/.rotate-journal.lock" ] || fail "lock must be released after an abort"
}

test_rotate_rolls_back_a_failed_replace() {
  vault="$TMP_ROOT/rotate-rollback"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  before="$(cksum < "$j")"
  for at in away:JOURNAL.md place:JOURNAL.md place:2026-07.md; do
    set +e
    out="$(ROTATE_JOURNAL_FAIL_AT="$at" bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 2>&1)"; status=$?
    set -e
    [ "$status" -ne 0 ] || fail "a failed replace ($at) must exit non-zero"
    assert_contains "$out" "rolled back" "a failed replace ($at) is rolled back"
    [ "$(cksum < "$j")" = "$before" ] || fail "JOURNAL.md must be restored after a failed $at"
    [ ! -e "$vault/Project/journal" ] || fail "new month files must be removed after a failed $at"
    [ ! -e "$vault/Project/.rotate-journal.lock" ] || fail "lock must be released after rollback ($at)"
  done

  # With month files already present, a failure restores them byte for byte.
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 3 --min-keep 2 >/dev/null || fail "setup rotation failed"
  snap="$(cat "$j" "$vault/Project/journal/"*.md | cksum)"
  set +e
  ROTATE_JOURNAL_FAIL_AT=place:2026-08.md bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 1 --min-keep 1 >/dev/null 2>&1; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "failed replace of an existing month file must exit non-zero"
  [ "$(cat "$j" "$vault/Project/journal/"*.md | cksum)" = "$snap" ] || fail "existing files must be restored after rollback"
  dups="$(entries_of "$j" "$vault/Project/journal/"*.md | grep '^## 20' | sort | uniq -d)"
  [ -z "$dups" ] || fail "rollback must not leave duplicated entries: $dups"
}

test_rotate_repairs_a_half_applied_rotation() {
  vault="$TMP_ROOT/rotate-repair"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  cp "$j" "$TMP_ROOT/repair-original"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 >/dev/null || fail "setup rotation failed"
  # The pre-rotation JOURNAL.md comes back (an editor or sync restore), and a
  # session then adds a new entry at the top.
  awk 'done || !/^## 2026-09-30/ { print; next } { printf "## 2026-10-02 — Written after the restore\n\n- **type:** fact\n\n"; print; done = 1 }' \
    "$TMP_ROOT/repair-original" > "$j"
  want="$( { entries_of "$j"; } | grep '^## 20' | sort -u)"

  out="$(bash "$vault/_tools/rotate-journal.sh" --max-kb 2 --min-keep 2)"
  assert_contains "$out" "already in journal/" "dry run reports the duplicates"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 >/dev/null || fail "repair failed"
  all="$(entries_of "$j" "$vault/Project/journal/"*.md | grep '^## 20')"
  [ -z "$(printf '%s\n' "$all" | sort | uniq -d)" ] || fail "repair must leave no duplicated entries"
  [ "$(printf '%s\n' "$all" | sort -u)" = "$want" ] || fail "repair must keep every entry"
  [ "$(grep -m1 '^## 20' "$j")" = "## 2026-10-02 — Written after the restore" ] || fail "the new entry stays at the top"
  out="$(bash "$vault/_tools/rotate-journal.sh" --max-kb 2 --min-keep 2)"
  assert_contains "$out" "OK       Project" "after repair there is nothing left to do"
}

test_rotate_refuses_conflicts_and_held_locks() {
  vault="$TMP_ROOT/rotate-conflict"
  make_rollover_vault "$vault"
  j="$vault/Project/JOURNAL.md"
  cp "$j" "$TMP_ROOT/conflict-original"
  bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 >/dev/null || fail "setup rotation failed"
  # The restored copy differs from the rolled one: same heading, edited text.
  sed 's/^Body line 0 for 2026-07-01,/Body line 0 (edited) for 2026-07-01,/' "$TMP_ROOT/conflict-original" > "$j"
  snap="$(cat "$j" "$vault/Project/journal/"*.md | cksum)"
  set +e
  out="$(bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 2>&1)"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a conflicting duplicate must be refused"
  assert_contains "$out" "CONFLICT" "conflict is named"
  assert_contains "$out" "2026-07-01" "conflicting entry is listed"
  [ "$(cat "$j" "$vault/Project/journal/"*.md | cksum)" = "$snap" ] || fail "nothing may change on a conflict"

  vault="$TMP_ROOT/rotate-locked"
  make_rollover_vault "$vault"
  mkdir "$vault/Project/.rotate-journal.lock"
  set +e
  out="$(bash "$vault/_tools/rotate-journal.sh" --apply --max-kb 2 --min-keep 2 2>&1)"; status=$?
  set -e
  [ "$status" -ne 0 ] || fail "a held lock must be refused"
  assert_contains "$out" "LOCKED" "held lock is reported"
  [ ! -e "$vault/Project/journal" ] || fail "nothing may be written while locked"
  [ -d "$vault/Project/.rotate-journal.lock" ] || fail "someone else's lock must not be removed"
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
test_rotate_honors_fence_length
printf 'PASS: rotate and checker honor fence length and ~~~ fences\n'
test_rotate_refuses_unsafe_destinations_and_sources
printf 'PASS: rotate refuses directory destinations and unreadable sources\n'
test_rotate_reads_zero_padded_values_as_decimal
printf 'PASS: rotate reads zero-padded values as decimal\n'
test_rotate_aborts_on_concurrent_write
printf 'PASS: rotate aborts when a source changes mid-run\n'
test_rotate_rolls_back_a_failed_replace
printf 'PASS: rotate rolls back a failed replace, leaving no duplicates\n'
test_rotate_repairs_a_half_applied_rotation
printf 'PASS: rotate repairs a half-applied rotation\n'
test_rotate_refuses_conflicts_and_held_locks
printf 'PASS: rotate refuses conflicting duplicates and held locks\n'
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
test_dream_commit_refuses_during_a_rotation
printf 'PASS: dream wrapper refuses during a journal rotation\n'
test_dream_prompt_keeps_its_safety_rules
printf 'PASS: dream prompt safety rules\n'
test_every_client_is_pointed_at_the_guidance
printf 'PASS: every client is pointed at the guidance\n'
test_skill_audit_grep_finds_confirmed_dream_entries
printf 'PASS: dream audit grep\n'

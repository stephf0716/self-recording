# Upgrading an established vault

A vault built by an earlier version of this skill is not a blank folder. Its
contract was adapted, its journals hold months of entries, and some of its
tools may have been edited by hand. Re-running setup over it destroys that.
Upgrade instead.

## The rules

1. **Never re-scaffold.** Do not copy `templates/` over the vault. `AGENTS.md`,
   pointer files, and `MEMORY-SCHEMA.md` were adapted for this person; the
   templates are a reference for what to *add*, not a replacement.
2. **Tools are replaced only when untouched.** `scripts/upgrade.sh` hashes
   each file in `_tools/` against every release. A copy identical to an older
   release is safe to replace. A copy that matches nothing was edited
   locally: diff it and merge by hand, with the owner.
3. **Contract changes go section by section, with the owner's agreement.**
   They are revertible, but a contract change alters how every future
   session behaves, so it is their call. Show the diff, not a summary.
4. **Journals are not migrated.** Old entries stay as they were written,
   missing fields and all. Format changes apply to new writes; summaries
   upgrade lazily, the next time they are regenerated.
5. **New features are opt-in.** An upgrade offers them; it never enables
   one. Enabling follows that feature's own setup, including any supervised
   first run.
6. **One revertible boundary.** Commit existing drift first, then make the
   upgrade its own commit(s). `upgrade.sh --apply` does both for `_tools/`;
   commit contract merges separately so each can be reverted alone.

## Procedure

From the skill directory (the one containing `SKILL.md`):

```bash
bash tests/test-skill.sh                       # the skill itself is sound
bash scripts/upgrade.sh /path/to/vault         # report: what is current, stale, edited
bash scripts/upgrade.sh /path/to/vault --apply # replace untouched tools, stamp, commit
```

Then, for every version after the one the report says the vault was built
with, work through that version's section below. `_tools/.self-recording-version`
records the result; vaults from before 0.4.0 have no stamp, and the report
infers the version from the tools instead. When several releases ship identical
copies of the tools it finds, it reports the range and starts the list from
the oldest; check each section against the contract before merging it.

If the vault has **no version history**, stop. Set it up first (SKILL.md
Step 2). An upgrade with no undo is exactly the unreviewed write the design
forbids.

---

## 0.3.0 → 0.3.1

**Tools:** `check-current-state.sh` (counted markers, same-day detection, fenced
examples ignored, project names with spaces) and `new-project.sh` (new
journals start with a counted marker). Both replaced by `--apply` if untouched.

**Contract — merge into the vault's `AGENTS.md` and `MEMORY-SCHEMA.md`:** the
marker is now `<!-- current-state: YYYY-MM-DD; decisions: N -->`, and
regeneration sets `decisions:` to the journal's total decision count. Compare
the `## Current state` sections of `templates/AGENTS.md` and
`templates/MEMORY-SCHEMA.md` with the vault's.

**Journals:** none. Date-only markers keep working and become counted ones the
next time each block is regenerated.

## 0.3.1 → 0.4.0

**Tools:** none changed. `--apply` writes the version stamp.

**New, optional — nightly consolidation ("dream").** Not enabled by upgrading.
If the owner wants it, follow SKILL.md Step 5, "Nightly consolidation",
including the supervised first run. It adds:

- `templates/DREAM.md` — the job prompt, filled in for this vault.
- `_agent/GUIDANCE.md` — written by the job, read by every session. Add the
  paragraph that points at it near the top of the vault's `AGENTS.md`, and the
  guidance line to each pointer file (`templates/CLAUDE.md`,
  `templates/HERMES.md`).
- `scripts/hermes/dream-commit.sh` — copied to `$HERMES_HOME/scripts/`, not
  `_tools/`. `upgrade.sh` does not track it; diff it by hand on later upgrades.
- The "Nightly consolidation" section at the end of `templates/AGENTS.md` —
  merge it into the vault's contract only once the job is enabled.

The job's summary step runs `_tools/check-current-state.sh`. If the report
shows it `ABSENT`, the job skips summaries and says so; copy it from
`scripts/` first if the owner wants them refreshed.

Established vaults need care that a new one does not: months of Hermes memory
may exist only in `USER.md` / `MEMORY.md`. The job's first run harvests those
into the vault and deliberately does not rebuild them; the owner reviews the
harvest before the second run does. Do not backfill weeks of old sessions in
one unattended run; if the owner wants a backfill, do it in a live session, a
week at a time.

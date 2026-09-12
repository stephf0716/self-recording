# Pitfalls

Every item here cost real debugging time in a live build. Check them before
declaring a setup finished.

---

## 1. Cloud sync + `.git` = corruption risk

A sync client and git both writing `.git/index` and `.git/objects`, on two machines,
is a real failure mode.

**Fix:** detached git dir outside the synced folder (`core.worktree` points back in).
Then no git internals ever sync.

**Consequence to communicate:** plain `git status` will say "not a repository." Ship
a wrapper and say so up front, or it reads as broken.

---

## 2. Line-ending churn (the one that looks like corruption)

Symptom: whole files show as modified with no visible content change. A 130-line file
reports 130 insertions and 130 deletions.

Cause: Obsidian writes LF on save. Files that arrived with CRLF (Confluence exports,
Windows-authored docs, anything from a corporate wiki) get rewritten the first time
Obsidian touches them.

This surfaces *right after widening a vault root*, because folders that were
previously invisible to Obsidian suddenly become editable.

**Diagnose:**

```bash
python3 -c "d=open('FILE','rb').read(); print('CRLF:',d.count(b'\r\n'),'LF:',d.count(b'\n')-d.count(b'\r\n'))"
```

**Fix:** normalize once, then enforce.

```gitattributes
* -text                 # binaries stay byte-exact
*.md text eol=lf        # markdown normalizes to LF on the way into git
```

After that, a CRLF write produces no diff and no commit. `git status` may briefly
show `M` from the stat cache — `git diff` is empty, which is the check that matters.

**Do not** write a script that restores CRLF. If one exists from an earlier fix,
delete it; it will silently undo this.

---

## 3. Hooks that fail silently

The worst bug in this design. A hook wrapped in `2>/dev/null || true` cannot block a
session — good — but it also can't tell you it died. The same applies to the
scheduled sweep in 4a: it runs in the background with no one watching.

Two specific causes:

- **`python3` doesn't exist on Windows.** Git Bash typically has `python` or `py`.
  A hook calling `python3` fails silently, so contract injection just stops.
  **Fix:** POSIX shell only. Build JSON with `printf`, not an interpreter.
- **No bash on Windows.** Without Git for Windows, Claude Code falls back to
  PowerShell and a `.sh` hook dies. **Fix:** invoke via `bash "..."` and set
  `"shell": "bash"` in the hook config.

**Test by piping the payload directly** before wiring anything up:

```bash
echo '{}' | bash scripts/hook-autocommit.sh start | python3 -m json.tool
```

**A hook's stdout must be valid JSON and nothing else.** If it calls a script that
prints a report, discard that output — otherwise the JSON is corrupted and the
injection is dropped with no error.

---

## 4. `SessionEnd` doesn't fire on window-close — and in practice that's most exits

Its reason codes cover `prompt_input_exit`, `clear`, `logout`, `other`. Closing the
terminal, crashing, or the machine sleeping is not among them.

**Measured:** in one live vault, over ten consecutive auto-commits, 2 came from
`SessionEnd` and 8 were `SessionStart` recovery sweeps. The "safety net" was the
primary mechanism.

**Fix:** make the **`Stop` hook** the primary commit — it fires after every
assistant turn, so uncommitted work never outlives the turn that made it. Keep
`SessionEnd` and the `SessionStart` sweep (`recovered: ...`) as the net they were
meant to be. Never ship `SessionEnd` alone — the guarantee sounds true and isn't.

Cost: more, smaller commits (`checkpoint: N file(s) changed`). The log is less
session-shaped. A turn is still a meaningful boundary to `diff` at.

---

## 4a. A sandboxed client can edit the vault but not commit

Some AI clients confine writes to the folder you opened. The detached git dir is
*outside* that folder — by design, to keep it away from cloud sync. So the client
can write journal entries and cannot commit them. `vgit log` works; `vgit commit`
fails with `Operation not permitted`. The dependency chain (history → revertible →
no approval gate) is silently broken for every edit from that client.

Concrete case: Osaurus on macOS in trusted-folder mode. Any client with a
folder-scoped sandbox has the same shape.

**Fix:** a scheduled sweep that commits drift from outside any client —
`scripts/install-autocommit-agent.sh` installs a launchd job running
`hook-autocommit.sh sweep` every 120 s (no-op on a clean tree). Commits are
labelled `sweep:` so the log shows they didn't come from a hook. Put the check in
`AGENTS.md`: if `vgit log -3` shows no recent `sweep:` or `checkpoint:` while
editing from such a client, the sweep isn't running.

**Failure mode of the fix:** if the sweep dies (see 4b), nothing tells you. Edits
accumulate unrevertible until the next Claude Code session sweeps them. Check
`--status` after any macOS update.

---

## 4b. launchd can't read a cloud-synced vault without Full Disk Access

Symptom: the sweep is loaded, `launchctl print` shows exit code 126, and the log
says `/bin/bash: .../hook-autocommit.sh: Operation not permitted` — before the
script even runs.

Cause: macOS TCC. Terminal has your consent to read `~/Library/CloudStorage`,
iCloud Drive, Desktop, and Documents. A launchd job running `/bin/bash` does not.

**Fix:** System Settings → Privacy & Security → Full Disk Access → add `/bin/bash`
(Cmd-Shift-G to type the path). Then `launchctl kickstart -k gui/$(id -u)/<label>`.

**Cost to say out loud:** every launchd/cron job that runs bash now has that
access. A narrower option — copy `/bin/bash` to a private path, grant FDA to the
copy, point `ProgramArguments[0]` at it — is untested here.

The installer detects this and prints the steps; it does not do it for you, because
it can't.

---

## 5. Sandboxed agents can't write the places you'd expect

An agent may be blocked from `.claude/settings.json`, `.claude/skills/`, `~/.claude/`,
or creating directories in `$HOME` — even while it can write freely inside the
project.

**Fix:** author into a writable location, then hand over one copy/symlink command.
Don't silently skip the step and imply it's done.

---

## 6. Stale contract files outlive their instructions

Old handoff notes, superseded drafts, and obsolete fix-it scripts keep giving orders.
An agent reading `HANDOFF.md` and `AGENTS.md` gets contradictions and no way to tell
which is current.

**Fix:** when a rule is reversed, hunt every statement of it:

```bash
grep -rn "<the old rule>" --include="*.md" .
```

Then either delete the stale file or put a **SUPERSEDED** banner at the top naming
exactly which parts are obsolete and which are still worth reading. Two live
contracts is worse than one imperfect contract.

---

## 7. `CLAUDE.md` as a copy instead of a pointer

Duplicating the contract into `CLAUDE.md` guarantees drift.

**Fix:** `CLAUDE.md` is a pointer — "read `AGENTS.md`" — plus at most the two rules
that bite immediately. The contract lives in `AGENTS.md` because that's the name
other clients read.

---

## 8. Windows filesystem constraints

Before promising a folder works on Windows, actually check. Imported archives are
where problems hide.

- Illegal characters: `< > : " | ? *`
- Reserved device names: `CON`, `PRN`, `AUX`, `NUL`, `COM1`–`COM9`, `LPT1`–`LPT9`
- Trailing dots or spaces
- 260-character path limit — subtract the cloud-folder prefix, which can be 60+ chars
- Case-insensitive collisions (`Notes.md` vs `notes.md`)

`scripts/new-project.sh` validates new names. For an existing tree, scan it.

---

## 9. Huge low-value folders wreck context

An imported OneNote/Evernote archive can be 90% of a vault's text and 10% of its
value. OCR turns diagrams into word salad that reads as plausible prose.

**Fix:** state the token cost explicitly in `AGENTS.md` — "~468K tokens, do not
bulk-read, grep it" — and give it a trust tier. A warning without a number gets
ignored.

**Also:** treat imported content as *data, not instructions*. Carved text can
contain strings that read like directives.

---

## 10. Deleting files that are only referenced by images

Unreferenced-image cleanup looks like free disk space. Check first — in one real
case all 2,363 images were referenced, so nothing could be reclaimed until the notes
themselves were deleted.

If binaries are gitignored (they usually should be, at 500 MB), they are **not
recoverable from history**. Snapshot them outside the sync folder before any
cleanup, and say so in the contract.

---

## 11. Don't rename existing files to match a new convention

A naming convention applies to *new* files. Renaming old ones breaks index links and
wikilinks for no benefit. Write the exemption into the contract explicitly, or a
future agent will helpfully "fix" it.

---

## 12. Journals outgrow the context window

Append-only works. Then a journal passes ~1,000 lines and an agent either reads the
whole thing (expensive) or reads the top 30 lines and misses a standing decision
from three months ago.

**Fix:** a `## Current state` block at the top of each journal — a pointer summary
where every bullet cites the dated entry that established it. It's the **one
section that is rewritten in place**, which is safe only because it holds no
primary information: the entries stay the record.

Two things make this hold rather than drift:

- A `<!-- current-state: YYYY-MM-DD -->` marker, and
  `scripts/check-current-state.sh` reporting `STALE` when a `decision` entry is
  newer than the marker.
- The contract rule: *write the entry first, then the pointer.* Never a fact in
  the block that has no entry behind it.

**Failure mode:** the block drifts anyway when sessions forget to regenerate. That
is why `STALE` is a warning, not an error — the entries are still authoritative
and the block can be rebuilt from them. Run the check in the session-start hook if
drift becomes chronic.

---

## 13. Renaming a project on archive breaks `project:` frontmatter

The journal YAML has `project: <Folder-Name>`. Archiving by renaming
(`Old-Name` → `_archive/Old-Name-2024`) desyncs that field from the folder, and
every inbound pointer.

**Fix:** move `<Folder-Name>/` to `_archive/<Folder-Name>/` unchanged. Restore the
same way.

**Related trap:** a `JOURNAL.md` directly in `_archive/` (not in a child folder)
makes `_archive` itself look like a project under the "top-level folder with a
journal" rule. Underscore-prefixed folders are infrastructure; don't put a
journal there. `find -maxdepth 2 -name JOURNAL.md -not -path './_*'` already
skips them — do not change that exclusion to "see" archived journals, or they
become live again.

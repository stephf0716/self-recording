# Nightly consolidation ("dream")

Optional. A scheduled job that reads the day's sessions, appends the
decisions, preferences, and lessons nobody journaled, rewrites
`_agent/GUIDANCE.md` (how every agent should work with the owner), refreshes
stale `## Current state` blocks, flags due `review_after` dates, and rebuilds
the harness's own small memory from the vault. The prompt is
`templates/DREAM.md`; it is harness-neutral, with Hermes as the worked case.

Offer it once the contract works and history is automated, not before. Never
enable it unasked.

## Why the guidance file

Without it, the job only files things away: an agent learns from an entry only
if it happens to open that journal. `_agent/GUIDANCE.md` is read at the start
of every session by every client (`AGENTS.md` says so, and the `CLAUDE.md`
pointer imports it), so a correction made to one agent reaches all of them by
morning.

That also makes it the most valuable place to inject an instruction, so it is
built only from journal entries (which carry provenance), never from session
text; every bullet cites its entry; `unverified` entries stay out; and it says
how to work, never what to do. The rest of the job's rules are in the prompt
itself (`templates/DREAM.md`, "Rules that override everything else"), because
a scheduled run may not get the contract injected. What went wrong without
them: `pitfalls.md` 4e and 14.

## Hermes setup

1. Copy the commit wrapper machine-locally — not into `_tools/` (pitfall 4d):
   `mkdir -p "$HERMES_HOME/scripts" && cp scripts/hermes/dream-commit.sh "$HERMES_HOME/scripts/"`
2. Fill `templates/DREAM.md`. For Hermes:

   | Placeholder | Value |
   |---|---|
   | `{{OWNER}}`, `{{VAULT_PATH}}`, `{{NOTES_DIR}}`, `{{LOW_TRUST_DIR}}` | as in the vault's `AGENTS.md` |
   | `{{TODAY}}` | leave for the run: its local date, `date +%F` |
   | `{{HARNESS}}` | `Hermes` |
   | `{{HOST}}` | `hostname -s` |
   | `{{COMMIT_WRAPPER}}` | `$HERMES_HOME/scripts/dream-commit.sh`, as an absolute path |
   | `{{MEMORY_DIR}}` | `$HERMES_HOME/memories`, as an absolute path |
   | `{{USER_CHAR_CAP}}`, `{{MEMORY_CHAR_CAP}}` | `memory.user_char_limit` and `memory.memory_char_limit` in `config.yaml` (defaults 1,375 and 2,200) |
   | `{{MAX_WINDOW_DAYS}}` | 3, so a missed night is caught up without one huge run |
   | `{{GUIDANCE_CHAR_CAP}}`, `{{FRICTION_WINDOW_DAYS}}` | 4,000 and 14 |
   | `{{WRITE_PERMISSIONS}}` | the vault contract's own rules on what may be stored (a scheduled run may not get the contract injected), or "none beyond rule 7" |
   | `{{SILENT_MARKER}}` | `[SILENT]` |

   Keep the filled copy in the vault (e.g. `_agent/DREAM.md`) as the
   versioned record — the cron job stores its own copy, so re-create the job
   after editing it.
3. **First run supervised.** Paste the filled prompt into a live session with
   the owner present. Its first run harvests digest-only memories into the
   vault and deliberately leaves the digest alone; the owner reviews the
   harvest before any rebuild. On an established vault this is the run that
   matters — months of memory may exist only in `USER.md`.
4. Create the job on the **gateway's** cron (`hermes cron create`, or ask
   Hermes in chat), pinned to a strong API model with `--model`. Not a second
   process on the same `HERMES_HOME`; two writers corrupt each other's memory.
   Read the job back and confirm the gateway is running — agent jobs are
   skipped without it. Set `deliver` and `failure_deliver` to local: the job
   runs in the background, and a chat message every night defeats that. Deliver
   to the owner's chat only if they ask for it.
5. If `memory.write_approval` is on, an unattended run cannot get its digest
   writes approved. Turn it off for this, or drop step 8 from the prompt.
6. Several machines with Hermes: session history is per-machine, so each runs
   its own job, staggered by an hour or more. Logs carry the host name; each
   job finds its window from its own host's logs only, and greps before
   writing, so overlaps don't duplicate.
7. Add the "Nightly consolidation" section from `templates/AGENTS.md` to the
   vault's contract, so live sessions know what dream entries are, plus the
   "read `_agent/GUIDANCE.md` next" paragraph near its top. In each pointer
   file, add the guidance line (`templates/CLAUDE.md` imports it with
   `@_agent/GUIDANCE.md`; `templates/HERMES.md` says to read it). Clients that
   load only `AGENTS.md` follow that paragraph.

## What it will not do

It does not create or edit Agent Skills. A repeated workflow becomes a
`procedure` entry and a line in the report; skill-making stays with Hermes's own
loop. Skills are instructions every later session obeys, and they live outside
vault history — an unattended job writing them from untrusted session text has
no undo.

## Verify

After the first scheduled run, from the vault:

```bash
_tools/vgit log --oneline -3     # a dream: commit, possibly after a pre-dream:
grep -rn -B1 '\*\*source:\*\* dream' --include=JOURNAL.md . | grep 'confidence:\*\* confirmed'   # expect nothing
head -5 _agent/GUIDANCE.md       # today's guidance marker
```

Then read the guidance file itself. Every bullet should be something the
owner would recognize as how they want to work, with an entry behind it. A
bullet that is really a one-off or a project status is noise; fix the entry
it cites, and the next run drops it.

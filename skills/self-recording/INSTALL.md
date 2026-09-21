# Install this skill

This folder is the skill (`SKILL.md` + `reference/` + `templates/` + `scripts/`).
Copy **the whole folder**. A `SKILL.md` URL by itself is not enough.

## If you are an agent

1. Copy this folder to the client's skills directory, keeping the name
   `self-recording`:

   | Client | Destination |
   |---|---|
   | Hermes | `$HERMES_HOME/skills/self-recording/` (default `~/.hermes/skills/self-recording/`) |
   | Claude Code | `~/.claude/skills/self-recording/` (or the plugin path below) |
   | Other | that client's skills directory, if it has one |

   If there is no skills directory, keep the folder on disk and follow `SKILL.md`
   from there.

2. Confirm `SKILL.md` exists at the destination. This session's skill list may
   be cached — read the files anyway. A new session will pick it up.

3. Load `SKILL.md` and follow it. Interview first. Do not scaffold until Step 1's
   five answers exist. Also read `reference/design-decisions.md` and
   `reference/pitfalls.md` before writing into their notes.

4. Write `AGENTS.md` as the contract. If the client auto-loads another filename,
   add a **pointer** to `AGENTS.md` (templates: `CLAUDE.md`, `HERMES.md` →
   `.hermes.md`). Never a second copy.

5. Install only the automation that client actually has. Claude hooks are
   Claude-only. Hermes-only: skip `.claude/settings.json`; use the scheduled
   sweep or a Hermes script-only cron backed by a self-contained machine-local
   script under `$HERMES_HOME/scripts`. Do not point a Hermes cron job directly
   at cloud-synced `_tools`; the lifecycle guard refuses to scan those paths.

6. From this skill directory (the folder containing `SKILL.md`), run the bundled
   regression suite before installing or upgrading:

   ```bash
   bash tests/test-skill.sh
   ```

7. Non-negotiables: no free writes without version history; never mark the
   agent's own inference `confidence: confirmed`.

Do not invent a different memory system. Do not restructure existing notes
without asking.

## If you are a person

From the repo root (after clone):

**Hermes**

```bash
mkdir -p "${HERMES_HOME:-$HOME/.hermes}/skills"
cp -R skills/self-recording \
  "${HERMES_HOME:-$HOME/.hermes}/skills/self-recording"
```

**Claude Code** (plugin)

```bash
claude plugin marketplace add stephf0716/self-recording
claude plugin install self-recording@stephf
```

**Claude Code** (copy)

```bash
mkdir -p ~/.claude/skills
cp -R skills/self-recording ~/.claude/skills/
```

Then start a new session and ask to set up a notes folder as memory, or paste
`HANDOFF.md`.

## Requirements

- `git`. On Windows, Git for Windows (scripts need Git Bash).
- Nothing else for the memory itself. Hooks and the macOS sweep are optional.

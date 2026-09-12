# Self-recording

A skill that turns a folder of Markdown into durable AI memory — notes that
record themselves while you work, with version-controlled undo.

Works with any file-capable agent (Claude Code, Hermes, ChatGPT/Codex, Copilot,
Cursor, …). Clients are temporary. The memory is plain text plus an `AGENTS.md`
contract.

The problem it solves: you explain the same context to every new AI chat, and
anything the AI figures out is lost when the session ends.

## Install

The skill is the folder `skills/self-recording/` (it contains `SKILL.md`,
`scripts/`, `templates/`, `reference/`). Copy **that whole folder**, not just
`SKILL.md`.

### Hermes Agent

```bash
mkdir -p "${HERMES_HOME:-$HOME/.hermes}/skills"
cp -R skills/self-recording \
  "${HERMES_HOME:-$HOME/.hermes}/skills/self-recording"
```

Start a **new** session, then ask it to set up a notes folder as durable memory
— or paste the prompt in `HANDOFF.md`.

Do not `hermes skills install` a URL to `SKILL.md` alone. That drops `scripts/`,
`templates/`, and `reference/`.

### Claude Code

```bash
claude plugin marketplace add stephf0716/self-recording
claude plugin install self-recording@stephf
```

Or `/plugin` inside Claude Code. To skip the plugin system:

```bash
mkdir -p ~/.claude/skills
cp -R skills/self-recording ~/.claude/skills/
```

### Any other client

Copy `skills/self-recording` into that client's skills directory if it has one.
Or open this repo and say: follow `skills/self-recording/SKILL.md`.

Details: `skills/self-recording/INSTALL.md`.

## Use

In the folder you want as memory, load the skill (slash command if the client
has one) or just say what you want — "I want my notes folder to work as memory
my AI remembers between sessions."

**It interviews you before building anything.** It does not assume your setup
matches anyone else's.

## The idea

Durable memory lives in Markdown you own. Swap Claude for Copilot for Hermes
and the memory stays put.

Memory is recorded **as work happens**, with no approval step — which is only
safe because of a dependency chain the skill treats as non-negotiable:

```
version history exists
  → so every AI write is revertible
    → so no approval gate is needed
      → so memory accumulates without effort
```

Remove version history and the whole thing becomes unsafe. The skill sets it up
before letting an AI write freely, and says so.

The other rule it enforces: **an AI may never mark its own inference as
`confirmed`.** Anything it inferred is `probable` — permanently distinguishable
from what you actually said, and greppable:

```bash
grep -rn "confidence: probable" --include=JOURNAL.md .
```

Nothing is gated, but nothing is disguised either.

## What you get

- **Project journals** — append-only, newest first, in the project folder you're
  already working in. No context switch to record something.
- **Provenance metadata** — `type`, `status`, `confidence`, `source`,
  `review_after`. Greppable, no database.
- **Git-backed undo** — a detached git dir when the folder is cloud-synced, so the
  sync client can never corrupt git's object store.
- **Auto-commit** — Claude Code hooks if you use Claude; a macOS scheduled sweep
  for sandboxed clients; Hermes can use that sweep or a cron. Every rule still
  lives in `AGENTS.md`.
- **`## Current state` block** — a pointer summary at the top of each journal, the
  one section that is rewritten rather than appended, with a drift checker.
- **Rejected alternatives recorded** — a decision without its discarded options is
  unreviewable a year later.
- **Project archive** — move an inactive project to `_archive/<Folder-Name>/`
  with the same name; only a top-level `JOURNAL.md` is live.

## Contents

| Path | What it is |
|---|---|
| `skills/self-recording/SKILL.md` | The workflow: interview → decide → history → contract → automate → verify |
| `reference/design-decisions.md` | Four real design forks, with honest costs, and what *not* to build yet |
| `reference/pitfalls.md` | Traps that each cost real debugging |
| `templates/` | `AGENTS.md`, client pointers (`CLAUDE.md`, `HERMES.md`), `MEMORY-SCHEMA.md`, `JOURNAL.md`, `_archive/README.md` |
| `scripts/` | History setup, Claude hook installer, auto-commit, launchd sweep, current-state checker, project scaffolder, archiver |

`reference/pitfalls.md` is worth reading even if you let the AI drive.

## Requirements

- `git`. On Windows, **Git for Windows** — the scripts need Git Bash.
- Claude Code only if you want Claude's session hooks. Hermes, ChatGPT, Copilot,
  and others work off `AGENTS.md`. The scheduled sweep is macOS-only (launchd).
- Nothing else. No Obsidian required, no database, no embeddings, no MCP server.

## Status and licensing

Version 0.3.0. MIT. Built from a working setup rather than designed in the
abstract — every item in `pitfalls.md` cost real debugging time.

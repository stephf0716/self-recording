<!--
TEMPLATE. A POINTER, NEVER A COPY.
Duplicating the contract here guarantees the two drift apart. Keep this short.
-->

# CLAUDE.md

**Read `AGENTS.md` in this directory now.** It is the contract and it applies in
full to this session.

This file is deliberately a pointer, not a copy — the contract lives in one place so
it cannot drift between clients.

## The part that matters most

**Record what you learn as you work, without being asked.** Durable memory goes in
the `JOURNAL.md` of whichever project you're working in — append a dated entry at the
top. Don't ask permission and don't stage it for review; a `Stop` hook auto-commits
after every turn and any entry is revertible.

Mark anything you wrote `confidence: probable`. **Never write
`confidence: confirmed`** — that is reserved for things {{OWNER}} stated.

If you added a `decision` entry, regenerate that journal's `## Current state`
block before you finish — it's the one section that is rewritten, not appended.

## Then, as needed

- `MEMORY-SCHEMA.md` — entry fields and their meanings
- `_agent/README.md` — session logs and scratch
- `{{NOTES_DIR}}/AGENTS.md` — cross-project notes
- `<project>/AGENTS.md` — before touching a project that has one

## Two things that bite immediately

1. {{LOW_TRUST_DIR}} is ~{{TOKEN_COUNT}} tokens of low-value text. **Grep it, never
   bulk-read it.**
2. {{HISTORY_GOTCHA — e.g. "There is no .git here; history is detached. Use
   _tools/vgit, not plain git."}}

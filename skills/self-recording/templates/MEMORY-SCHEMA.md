<!-- TEMPLATE. Replace {{OWNER}} and trim types that do not apply. -->

# Memory schema

Two shapes of durable memory, both plain Markdown, both greppable without a database.

1. **Journal entries** — `<project>/JOURNAL.md`. Append-only, newest at top. Where
   most memory lands, because it's where the work happens.
2. **Standalone notes** — `{{NOTES_DIR}}/`. Cross-project material, meetings, people.
   File-level YAML frontmatter.

## Journal entry fields

Per-entry metadata sits under the heading as a bold-key list, because YAML
frontmatter can only apply to a whole file:

```markdown
## 2026-01-15 — Short statement of what happened

- **type:** decision
- **confidence:** probable
- **source:** session `_agent/sessions/2026-01-15-slug.md`
- **status:** active
- **supersedes:** 2025-12-02 entry on the same topic   ← optional

Body: what was decided or learned, and **what was rejected and why**.
```

Greppable: `grep -B2 -A6 "confidence: probable" <project>/JOURNAL.md`

## Standalone note frontmatter

```yaml
---
type: fact
status: active
created: 2026-01-15
updated: 2026-01-15
source:
  - "[[_agent/sessions/2026-01-15-slug]]"
confidence: probable
owner: {{OWNER}}
review_after: 2026-04-15   # optional; set for anything that goes stale
supersedes:                # optional
sensitivity: internal      # optional; see below
tags: [example]
---
```

## Field values

### `type`

| Value | Use for |
|---|---|
| `decision` | Something was decided. Record what was rejected. |
| `fact` | A durable technical or organizational fact |
| `lesson` | Something learned the hard way |
| `procedure` | A repeatable sequence |
| `preference` | How {{OWNER}} wants work done |
| `status` | Where a project actually stands |
| `meeting` | Meeting note |
| `reference` | Pointer to an external standard or system of record |
| `session` | AI session log, in `_agent/sessions/` |
| `journal` | The journal file itself |

### `status`

`active` · `superseded` · `draft` · `archived`

A superseded entry is **kept, not deleted** — it's how you reconstruct why something
changed. Point `supersedes:` from the new entry at the old one.

### `confidence`

| Value | Means |
|---|---|
| `confirmed` | {{OWNER}} stated it, or explicitly agreed to it |
| `probable` | An agent wrote it from a trustworthy source, unreviewed |
| `unverified` | Machine-extracted, imported, or a guess worth recording |

**An agent may never mark its own unprompted output `confirmed`.** This is the one
hard rule. It preserves the distinction between what {{OWNER}} knows and what a model
inferred, given that nothing is gated on review.

If they say something directly in conversation, an agent recording it *may* mark it
`confirmed` — attribute them in the body.

### `source`

Provenance, **mandatory for anything an agent wrote**. Point at the session log, the
file it came from, or the meeting it was said in. An agent entry with no traceable
source is an assertion, not a memory.

Omit it on material {{OWNER}} authored directly — there is no upstream source, and
`confidence: confirmed` plus `owner:` already says where it came from.

### `sensitivity` (optional)

`internal` — contains personal or confidential material. Agents: don't read unless
the task requires it, don't quote details into unrelated notes, never paste into an
external service.

```bash
grep -rln "sensitivity: internal" .
```

## Journal `## Current state` block

Every `JOURNAL.md` has one section that is **not** append-only: `## Current
state`, placed between the preamble and the first dated entry. It is a pointer
summary — each bullet names what is currently true and cites the entry that
established it (`→ 2026-09-01 *Gate 0 closed*`). Because it holds no primary
information, rewriting it loses nothing; the entries remain the record.

Marker line, required, first thing inside the section:

```markdown
<!-- current-state: 2026-09-10 -->
```

The date is when the block was last regenerated. `_tools/check-current-state.sh`
compares it with the newest `type: decision` entry and reports `STALE` if the
decision is newer. Regenerate at the end of any session that adds a `decision`.
Target under ~30 bullets. Full rule in `AGENTS.md`.

## Auditing later

Because nothing is gated up front, these queries are what make review possible
whenever it's wanted:

```bash
grep -rn "confidence: probable" --include=JOURNAL.md .   # everything unreviewed
grep -rn "status: superseded" --include=JOURNAL.md .     # what changed its mind
grep -rln "review_after: 2026-0" .                       # coming due
bash _tools/check-current-state.sh                       # summaries out of date?
_tools/vgit log --oneline                                # session by session
_tools/vgit diff HEAD~1                                  # what the last one did
```

## Not in scope

No embeddings, no vector index, no derived cache is authoritative. Anything generated
must be rebuildable from the Markdown alone. If it can't be regenerated, it isn't
derived — it's source, and it needs metadata.

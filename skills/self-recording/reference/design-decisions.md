# The four forks

Walk through these with the person before scaffolding anything. Recommend a default,
state the cost honestly, and let them choose.

---

## Fork 1 — Does the AI write directly, or propose for review?

This is the decision the rest hang off.

### Option A: Review gate (proposals staged, human promotes)

The AI appends to an inbox file. The human reads it and promotes what's real.

- **Choose it when:** there is no version history, the content is high-stakes
  (regulated, safety-critical, externally reported), or more than one person depends
  on the notes being right.
- **Cost:** attention on every single fact. In practice this is the reason these
  systems get abandoned — the inbox stops being drained by week three and the memory
  quietly stops growing.

### Option B: Write directly, review by diff (recommended, if history exists)

The AI writes durable memory as it works, marked `confidence: probable`. Every write
is auto-committed. The human reviews by diff whenever they like — or never.

- **Requires:** version history. Non-negotiable.
- **Cost:** unreviewed content sits in authoritative folders. Mitigated by
  append-only dated entries, one-command revert, and a greppable confidence marker
  — not eliminated.

**The insight worth transmitting:** the review gate is standard *because most people
have no version history*. Human review is their only safety net. Once git is there,
the net moves from before the write to after it, and the gate stops paying for
itself.

---

## Fork 2 — Where does memory live?

### Option A: Per-project journals (recommended for project-shaped work)

`<project>/JOURNAL.md` beside the work.

- **Choose it when:** they open a project folder and work inside it. Which is most
  technical people.
- **Why it works:** recording costs no context switch. A design that makes someone
  leave what they're doing to record something will lose to not recording it.
- **Cost:** memory is spread across folders. Largely mooted if the whole tree is one
  search index (one Obsidian vault, one ripgrep root).

### Option B: Central knowledge base

Everything durable flows to one folder.

- **Choose it when:** they genuinely think in one notebook, or most knowledge is
  cross-cutting (research, writing, personal).
- **Cost:** every capture is a context switch out of the work.

### Option C: Both — journal locally, digest centrally

- **Cost:** the rollup is a second moving part that drifts from its source. Only
  worth it if they truly need a cross-project digest, and even then prefer
  generating it on demand over maintaining it.

**The one rollup that is worth it: a per-journal `## Current state` block.** It is
the same kind of second moving part, and it drifts the same way — but it stays
inside the journal it summarizes, it holds pointers only (every bullet cites an
entry), and `check-current-state.sh` detects drift mechanically. That is the
difference between a summary that can be trusted and one that can't: it is
regenerable from its source, and staleness is visible. A cross-project digest has
neither property.

**Cross-cutting material still needs a home** under A. Meetings, people, and
org-level facts don't belong to one project.

---

## Fork 3 — What provides version history?

### Option A: Detached git dir (recommended when the folder is cloud-synced)

Git dir outside the synced folder; `core.worktree` points back at it. **No `.git`
inside the vault.**

```bash
git init --bare -b main ~/vault-history.git
git --git-dir=~/vault-history.git config core.bare false
git --git-dir=~/vault-history.git config core.worktree /path/to/vault
```

- **Why:** the sync client can never touch git's index or object store. It also
  leaves the folder completely free of tooling artifacts, so it stays portable.
- **Cost:** plain `git` can't find it. Ship a `vgit` wrapper and explain it clearly,
  or the first `git status` that says "not a repository" will read as broken.
- **Cost:** per-machine. Files sync, commits don't.

### Option B: Normal `git init` in the folder

- **Choose it when:** the folder is **not** cloud-synced, or is already a repo.
  Simpler and better in that case — don't add complexity that buys nothing.
- **Cost:** with cloud sync and two machines, concurrent writes to `.git` can corrupt
  the object store or index. This is a real failure, not a theoretical one.

### Option C: Cloud-sync versioning only

Dropbox/OneDrive/iCloud keep per-file version history.

- **Reality check:** it exists and it's better than nothing. But it's per-file
  through a web UI — it can't show "what did that session change across six files,"
  which is exactly the review the write-directly design depends on.
- **If this is all they have:** keep the review gate (Fork 1, Option A).

### Option D: Nothing

Then Fork 1 must be Option A. Say so directly.

---

## Fork 4 — How much automation?

### Option A: Turn-and-lifecycle hooks (recommended for Claude Code)

`Stop` commits after every turn; `SessionEnd` commits at clean exit; `SessionStart`
sweeps drift and injects the contract.

- **Cost:** client-specific. Keep every *rule* in `AGENTS.md` and use hooks only for
  *mechanism*, so another client degrades to manual commits rather than losing the
  rules.
- **Cost:** `Stop` makes commits smaller and more numerous (`checkpoint:`). The log
  is turn-shaped rather than session-shaped.
- **Trap:** `SessionEnd` doesn't fire on window-close, crash, or sleep — and
  measured in a live vault, that was 8 of 10 exits. `Stop` is the primary
  mechanism *because* of that; `SessionStart` is the net. Don't ship `SessionEnd`
  alone.

### Option B: Manual commits

- **Choose it when:** they aren't using Claude Code, or don't want tooling in their
  config.
- **Cost:** reintroduces exactly the remembering-to-do-things that the design is
  trying to remove. Expect it to lapse.

### Option C: Scheduled sweep (launchd / cron / Task Scheduler) — *in addition to A*

Commit drift every N minutes regardless of which client wrote it.
`scripts/install-autocommit-agent.sh` does this on macOS (launchd, 120 s, no-op on
a clean tree).

- **Choose it when:** any client is **sandboxed to the vault folder** — it can edit
  the vault but cannot reach the detached git dir outside it, so nothing it writes
  is revertible until something else commits. Osaurus trusted-folder mode is the
  concrete case. Also worth it when several clients or machines write the same
  synced folder.
- **Cost:** `sweep:` commits are time-sliced rather than turn-shaped, so "what did
  that conversation do" is harder to read for non-Claude sessions.
- **Cost (macOS):** a launchd job needs Full Disk Access for `/bin/bash` to read a
  vault under `~/Library/CloudStorage` or iCloud. That grant is broad. See
  `pitfalls.md` 4b.
- **Failure mode:** it dies silently. If it stops, edits from sandboxed clients
  pile up unrevertible until a Claude Code session sweeps them. Check `--status`
  after OS updates.

This is not an alternative to A. Hooks give turn-shaped history for the client
that supports them; the sweep covers everything else.

---

## What to deliberately NOT build yet

**Semantic search / embeddings.** Under roughly 100K tokens of working text, scoped
file access plus `grep` is genuinely sufficient. An embedding index is a
regenerable cache that must never become the only copy of anything. Add it when
retrieval quality actually blocks work — not before.

**An MCP server.** Only worth it when several clients need one consistent
read/write interface *and* scoped filesystem access has proven insufficient. It also
becomes a security boundary, which is a real cost.

**A rebuild-the-index script.** Tempting and often destructive: hand-maintained
index files usually have prose around the generated part. Regenerate only what is
provably derived.

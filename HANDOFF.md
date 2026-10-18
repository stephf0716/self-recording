# Prompt for another agent

Give them this repo, the `skills/self-recording/` folder, or the zip, then paste
the block below.

---

Paste this:

```text
Install and then run the self-recording skill (v0.4.0). Do not improvise a different memory system.

Install
1. The skill folder is the directory that contains SKILL.md together with reference/, templates/, and scripts/ (in this repo: skills/self-recording/). Copy that whole folder to the current client's skills directory, named self-recording. Hermes: $HERMES_HOME/skills/self-recording/ (default ~/.hermes/skills/self-recording/). Claude Code: ~/.claude/skills/self-recording/ unless the plugin is already installed. Do not copy only SKILL.md. Do not use a SKILL.md URL install.
2. Confirm SKILL.md is at that path. Follow INSTALL.md if present.
3. This session's skills_list may be stale. Read the files with read_file / skill_view anyway.

Set up the vault
1. Load SKILL.md and follow it. Before writing any notes, also read reference/design-decisions.md and reference/pitfalls.md.
2. If the folder already has this system (_tools/hook-autocommit.sh, journals with a "## Current state" block), do not re-run setup: follow reference/upgrading.md: scripts/upgrade.sh reports, --apply replaces only untouched tools, and contract changes are merged only with the owner's agreement.
3. Interview first (Step 1). Do not scaffold until you have the five answers. Never restructure existing notes without asking.
4. Version history first (Step 2). If there is no history, do not remove the approval gate.
5. Agents may never mark their own inferences as confidence: confirmed.
6. Adapt templates/ — do not paste them unedited. AGENTS.md is the contract. If this client auto-loads another filename, write a pointer (templates/CLAUDE.md, templates/HERMES.md → .hermes.md), never a second copy.
7. Run scripts from this skill's scripts/ (or from the vault _tools/ after history setup).
8. Install only this client's automation. Claude Code: scripts/install-hooks.sh. Hermes-only: skip Claude hooks; use the macOS scheduled sweep (scripts/install-autocommit-agent.sh) or a Hermes script-only cron backed by a self-contained machine-local script under $HERMES_HOME/scripts. Do not point Hermes cron directly at cloud-synced _tools; its lifecycle guard refuses to scan those paths. Other clients: AGENTS.md plus the sweep if they cannot commit themselves. Nightly consolidation (templates/DREAM.md) is optional: offer it, do not enable it unasked. If enabled, it runs silently (no chat delivery unless the owner asks) and writes _agent/GUIDANCE.md, which every client's pointer must load.
9. Verify with real work (Step 6), then say the cost out loud (Step 7).
```

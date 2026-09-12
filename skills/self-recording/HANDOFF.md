# Prompt for another agent

Give them this repo, the `skills/self-recording/` folder, or the zip, then paste
the block below.

---

Paste this:

```text
Install and then run the self-recording skill (v0.3.0). Do not improvise a different memory system.

Install
1. The skill folder is the directory that contains SKILL.md together with reference/, templates/, and scripts/ (in this repo: skills/self-recording/). Copy that whole folder to the current client's skills directory, named self-recording. Hermes: $HERMES_HOME/skills/self-recording/ (default ~/.hermes/skills/self-recording/). Claude Code: ~/.claude/skills/self-recording/ unless the plugin is already installed. Do not copy only SKILL.md. Do not use a SKILL.md URL install.
2. Confirm SKILL.md is at that path. Follow INSTALL.md if present.
3. This session's skills_list may be stale. Read the files with read_file / skill_view anyway.

Set up the vault
1. Load SKILL.md and follow it. Before writing any notes, also read reference/design-decisions.md and reference/pitfalls.md.
2. Interview first (Step 1). Do not scaffold until you have the five answers. Never restructure existing notes without asking.
3. Version history first (Step 2). If there is no history, do not remove the approval gate.
4. Agents may never mark their own inferences as confidence: confirmed.
5. Adapt templates/ — do not paste them unedited. AGENTS.md is the contract. If this client auto-loads another filename, write a pointer (templates/CLAUDE.md, templates/HERMES.md → .hermes.md), never a second copy.
6. Run scripts from this skill's scripts/ (or from the vault _tools/ after history setup).
7. Install only this client's automation. Claude Code: scripts/install-hooks.sh. Hermes-only: skip Claude hooks; use the macOS scheduled sweep (scripts/install-autocommit-agent.sh) or a Hermes cron that runs the vault's _tools/hook-autocommit.sh sweep. Other clients: AGENTS.md plus the sweep if they cannot commit themselves.
8. Verify with real work (Step 6), then say the cost out loud (Step 7).
```

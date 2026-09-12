---
type: journal
project: {{PROJECT_NAME}}
status: active
created: {{TODAY}}
updated: {{TODAY}}
---

# {{PROJECT_NAME}} — journal

Append-only running record of decisions, changes of plan, and durable facts for this
project. **Newest entry at the top.**

Agents write here as work happens — no approval needed. Anything an agent wrote
carries `confidence: probable`; only {{OWNER}}'s own statements are `confirmed`.
Entries are never deleted or rewritten; a superseded one is marked
`status: superseded` and left in place.

Format and field definitions: `../AGENTS.md` and `../MEMORY-SCHEMA.md`.

## Current state

<!-- current-state: {{TODAY}} -->

Pointer summary of what is currently true. **Contains no primary information** —
every line cites the dated entry that established it. Rewritten in place (the one
exception to append-only); regenerate at the end of any session that adds a
`decision` entry. Keep under ~30 bullets. Check for drift with
`bash _tools/check-current-state.sh`.

- *(nothing settled yet)*

---

*(no entries yet)*

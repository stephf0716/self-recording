<!--
TEMPLATE. Replace every {{PLACEHOLDER}}. Ships with a newly built vault as
`_archive/README.md`. Do not put a JOURNAL.md in this folder itself.
-->

# Archived projects

Inactive vault projects live here so they stay out of the top-level listing.

## Convention

- A live project is a **top-level** folder with `JOURNAL.md`. Underscore-prefixed
  top-level folders (`_agent`, `_tools`, `_archive`) are vault infrastructure,
  not projects.
- To archive: move `<Folder-Name>/` to `_archive/<Folder-Name>/`, keeping the
  folder name so the journal `project:` field still matches.
- Set the project's README and journal frontmatter `status: archived`.
- Update inbound path pointers (other project READMEs/`AGENTS.md`).
- Journal the move in the archived project and in `{{NOTES_DIR}}/` if this vault
  records workspace-level decisions there.
- Do not put a `JOURNAL.md` directly in `_archive/` (that would register
  `_archive` itself as a project).

To restore: move the folder back to the vault root with the same name and set
status `active`.

Do not delete archived projects unless {{OWNER}} asks.

`bash _tools/archive-project.sh <Folder-Name>` moves the folder. It does not
edit pointers or journals — do that after the move.

# Draft identity across a native Mail resave

Refs #405 and #409. On 2026-09-17, a controlled unsent draft on macOS 27.0,
Mail 16.0 demonstrated that **both the numeric message ROWID and the RFC
Message-ID changed when the same compose window was edited and saved again**.
Message-ID is therefore not a supported cross-resave draft selector. This one
counterexample disproves a general stability guarantee; it does not establish
that every save on every account or Mail version changes both identifiers.

## Method and observations

The #405 checkout at `f5d69a809f4a7c09803474cb58d8306ebb33c303` was built with
`swift build`. A local MCP stdio client initialized that binary and called its
real `create_draft` with a UUID-named subject, `fixture@example.invalid`, plain
synthetic body version A, and the default sender. The response was
`Draft created successfully (mailto path)`. No send tool or send control was used.

Read-only AppleScript queries recorded only the uniquely named fixture's compose
window ID and saved draft metadata. The saved draft was located in the native
unified Drafts containers; account identity was read from its actual container.
The private account UUID and complete Message-IDs are intentionally not published.
Symbols below denote equality or inequality of the captured values, not hashes.

| Observation | Native compose window | Actual account | ROWID | RFC Message-ID | Saved body |
|---|---|---|---|---|---|
| After `create_draft` | W1 | A1 | R1 | M1 | version A present; B absent |
| After confirmed GUI edit and Save | W1 | A1 | R2 ≠ R1 | M2 ≠ M1 | version A absent; B present |
| After closing the owned window | absent | A1 | R2 | M2 | version B |
| After guarded fixture deletion | absent | no matching draft | absent | absent from Drafts | absent from Drafts |

The body edit used the observed CUA HTML body element. An initial attempt before
the editor's accessibility tree appeared left version A unchanged and was not
counted as a resave. After the editor appeared, select-all/paste visibly replaced
A with B; Save followed. Native read-back then confirmed B and both changed IDs.
This is an actual content-changing resave, not merely two unchanged snapshots.

The native `outgoing messages` collection contained no handle for this mailto
compose window before or after creation. Consequently, this run does not support
using an outgoing-message handle as the creation adapter for the existing mailto
path. The owned native window ID did persist across the observed edit, but that
alone does not bind a saved message record to the creation operation.

## Cleanup

The exact fixture window was closed. A fresh read located one matching saved
draft. Cleanup required the actual account, current ROWID, current Message-ID,
exact UUID subject, synthetic version-B body marker, and one recipient equal to
`fixture@example.invalid` before deleting that one draft. A subsequent native
query found no matching compose window, outgoing message, or Drafts record.
Deletion uses Mail's normal Trash behavior; Trash was not emptied. Other drafts
and mailboxes were not modified.

## Decisions and limits

- Retain the #405 guidance: ROWID is a transient snapshot; relist within the
  same account or use `subject_match` only while the subject remains unique and
  unchanged. Subject matching is not a permanent identity guarantee.
- Keep successful compose windows available for manual editing, with the
  documented autosave/identifier-drift cost. This experiment does not justify
  automatically closing the user's editor.
- Do not add a Message-ID selector based on an assumed cross-save invariant.
- #409 still needs a creation binding with actual evidence for default and
  explicit sender paths, competing drafts, and normal same-subject updates.
  A unique test subject is fixture isolation, not a production binding design.
- Re-saving an old draft can change both ID forms. A baseline ROWID exclusion
  alone cannot establish that a newly observed row is the replacement.
- A temporary-subject strategy cannot assume that the Message-ID captured before
  restoring the requested subject will survive that later save. This experiment
  establishes body-edit instability; a subject-only transition would need its
  own test and still could not supply a general cross-resave guarantee.

The live investigation answers #405's Message-ID open question for the tested
path. Complete independent review and #409's creation/receipt implementation are
separate unfinished gates.

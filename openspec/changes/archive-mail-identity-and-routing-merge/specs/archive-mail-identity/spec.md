## Purpose

Defines the machine-global participant identity file read by `/archive-mail`, how it combines with workspace `participant_aliases`, and how the resolved names are used for disambiguation candidates and reports.

## ADDED Requirements

### Requirement: Machine-global identity file

The archive-mail workflow SHALL read participant identity data from a machine-global file at `~/.claude/.mail/identity.yaml`. This file is a distinct concern from the per-workspace configuration file and SHALL NOT be treated as a second configuration layer: no merge precedence is defined between the two files beyond the supplement rule below, and no workspace file SHALL redefine an entry the identity file already provides.

The file SHALL support a single top-level key, `participant_aliases`, mapping a bare email address to a human-readable display string.

When the file is absent, the workflow SHALL proceed with no identity data and SHALL NOT emit an error. When the file is present but unparseable as YAML, the workflow SHALL report the parse failure and continue with no identity data rather than aborting the archive run.

Addresses SHALL be compared after trimming and lowercasing, without removing plus tags or dots; this normalization SHALL be used only to decide whether two entries name the same address. Workspace `participant_aliases` entries SHALL be used as written and SHALL NOT be dropped or rewritten by this step, so that a run without an identity file behaves exactly as before this change. Within the identity file, keys that are identical or collide after normalization SHALL be ignored with a warning while the other identity entries remain in use. Warnings SHALL name only the offending address and the error class; an entry whose key is not an address SHALL be identified by position, never by echoing a raw line, a key or a display name. Display names SHALL be rendered as quoted data with control characters removed and a length cap, and the source label and any recommendation SHALL be placed by the workflow, never taken from a display name.

#### Scenario: Identity file supplies a display name absent from workspace config

- **WHEN** `~/.claude/.mail/identity.yaml` maps an address to a display string and the workspace configuration file does not mention that address
- **THEN** reports produced by the archive run SHALL render that address using the display string from the identity file

##### Example: Department office address resolved in an audit report

- **GIVEN** `~/.claude/.mail/identity.yaml` contains `participant_aliases` with the entry `staff@example.invalid: "Example Staff (dept office)"`, and the workspace configuration file has no `participant_aliases` key
- **WHEN** an archive run produces a coverage-audit report naming that address
- **THEN** the report SHALL render `Example Staff (dept office)` rather than the bare address

#### Scenario: Workspace config supplements but cannot redefine

- **WHEN** both files define `participant_aliases` and the workspace file contains an address that the identity file also contains
- **THEN** the identity file's display string SHALL be used, and the workflow SHALL report the conflicting workspace entry as ignored

##### Example: Conflicting entry is ignored and disclosed

- **GIVEN** the identity file maps `person@example.invalid` to `"Example Person"` and the workspace configuration file maps the same address to `"YF"`
- **WHEN** the archive run resolves participant display names
- **THEN** the resolved name SHALL be `Example Person`, and the run report SHALL name `person@example.invalid` as an ignored workspace override

#### Scenario: Workspace-only address is honoured

- **WHEN** the workspace configuration file defines an address that the identity file does not contain
- **THEN** the workspace display string SHALL be used, with no conflict reported

#### Scenario: Absent identity file is not an error

- **WHEN** `~/.claude/.mail/identity.yaml` does not exist
- **THEN** the archive run SHALL complete normally using only workspace-level `participant_aliases`, exactly as written, and SHALL NOT emit a warning about the missing file


#### Scenario: Invalid identity file does not abort

- **WHEN** the identity file is malformed YAML, has a non-mapping root or a non-mapping `participant_aliases`, or contains a YAML tag, anchor, alias or merge key under `participant_aliases`
- **THEN** the workflow SHALL disclose the failure, ignore that identity file, and continue with workspace aliases

#### Scenario: Candidate and display consumers share resolution

- **WHEN** an identity supplies a display name for an email
- **THEN** Phase 1 candidate generation and the audit report SHALL use the same effective aliases, retaining the bare email for inspection, and the identity file alone SHALL NOT change filters or skip confirmation

#### Scenario: Global-only matches are never resolved without the user

- **WHEN** the filter is an ambiguous name, the user skipped confirmation with `--no-confirm`, and the identity file maps that name to an address that neither the workspace aliases nor the archive's thread participants contain
- **THEN** the workflow SHALL still present the candidates for the user to choose, and SHALL NOT mark a candidate that comes only from the identity file as recommended

#### Scenario: Identity and workspace give one name to different addresses

- **WHEN** the identity file and the workspace aliases use the same display name for different addresses
- **THEN** no candidate for that name SHALL be marked recommended, and the run report SHALL name the addresses involved

#### Scenario: Without an identity file, skipping confirmation behaves as before

- **WHEN** `~/.claude/.mail/identity.yaml` does not exist and the user skips confirmation with `--no-confirm`
- **THEN** Phase 1 SHALL be skipped and the filter SHALL be used as typed, exactly as before this change

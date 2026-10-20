## ADDED Requirements

### Requirement: Machine-global identity file

The archive-mail workflow SHALL read participant identity data from a machine-global file at `~/.claude/.mail/identity.yaml`. This file is a distinct concern from the per-workspace configuration file and SHALL NOT be treated as a second configuration layer: no merge precedence is defined between the two files beyond the supplement rule below, and no workspace file SHALL redefine an entry the identity file already provides.

The file SHALL support a single top-level key, `participant_aliases`, mapping a bare email address to a human-readable display string.

When the file is absent, the workflow SHALL proceed with no identity data and SHALL NOT emit an error. When the file is present but unparseable as YAML, the workflow SHALL report the parse failure and continue with no identity data rather than aborting the archive run.

#### Scenario: Identity file supplies a display name absent from workspace config

- **WHEN** `~/.claude/.mail/identity.yaml` maps an address to a display string and the workspace configuration file does not mention that address
- **THEN** reports produced by the archive run SHALL render that address using the display string from the identity file

##### Example: Department office address resolved in an audit report

- **GIVEN** `~/.claude/.mail/identity.yaml` contains `participant_aliases` with the entry `oxalislin@ntu.edu.tw: "Lin Hsin-Yi (PSY dept office)"`, and the workspace configuration file has no `participant_aliases` key
- **WHEN** an archive run produces a coverage-audit report naming that address
- **THEN** the report SHALL render `Lin Hsin-Yi (PSY dept office)` rather than the bare address

#### Scenario: Workspace config supplements but cannot redefine

- **WHEN** both files define `participant_aliases` and the workspace file contains an address that the identity file also contains
- **THEN** the identity file's display string SHALL be used, and the workflow SHALL report the conflicting workspace entry as ignored

##### Example: Conflicting entry is ignored and disclosed

- **GIVEN** the identity file maps `yfhsu@ntu.edu.tw` to `"Hsu Yung-Feng"` and the workspace configuration file maps the same address to `"YF"`
- **WHEN** the archive run resolves participant display names
- **THEN** the resolved name SHALL be `Hsu Yung-Feng`, and the run report SHALL name `yfhsu@ntu.edu.tw` as an ignored workspace override

#### Scenario: Workspace-only address is honoured

- **WHEN** the workspace configuration file defines an address that the identity file does not contain
- **THEN** the workspace display string SHALL be used, with no conflict reported

#### Scenario: Absent identity file is not an error

- **WHEN** `~/.claude/.mail/identity.yaml` does not exist
- **THEN** the archive run SHALL complete normally using only workspace-level `participant_aliases`, and SHALL NOT emit a warning about the missing file


#### Scenario: Invalid identity file does not abort

- **WHEN** the identity file is malformed YAML, has duplicate YAML keys, or has a non-mapping root
- **THEN** the workflow SHALL disclose the failure, ignore that identity file, and continue with workspace aliases

#### Scenario: Candidate and display consumers share resolution

- **WHEN** an identity supplies a display name for an email
- **THEN** Phase 1 candidate generation and the audit report SHALL use the same effective aliases, retaining the bare email for inspection and SHALL NOT silently change filters or skip confirmation

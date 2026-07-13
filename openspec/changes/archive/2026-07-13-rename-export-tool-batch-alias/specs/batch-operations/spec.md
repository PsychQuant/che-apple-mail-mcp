## ADDED Requirements

### Requirement: Batch export tool naming and deprecation alias

The system SHALL register the server-side markdown export tool under the canonical name `batch_export_emails_markdown`. The pre-existing name `export_emails_markdown` SHALL remain registered as a deprecated alias: both names SHALL dispatch to the same handler, accept the identical input schema, and return the identical manifest — the two registrations MUST NOT diverge in behaviour in any way. Every normative clause of the "Server-side markdown export" requirement SHALL apply equally to calls made under either name.

The deprecated alias's tool description SHALL begin with the literal prefix `DEPRECATED — renamed to batch_export_emails_markdown` and SHALL state the removal gate. A call made under the deprecated name SHALL emit a single-line deprecation warning to stderr naming the canonical replacement; the call's result content SHALL be unaffected.

The deprecated alias SHALL NOT be removed before the next major release (v3.0). Removing the alias SHALL be treated as a breaking change requiring its own change proposal, CHANGELOG entry, and caller-migration note.

#### Scenario: Canonical name dispatches identically

- **WHEN** `batch_export_emails_markdown` is called with any input that is valid for `export_emails_markdown`
- **THEN** the call SHALL behave exactly as the same call under `export_emails_markdown` — same validation, same files written, same manifest shape — with no deprecation warning emitted

#### Scenario: Deprecated alias still works and warns on stderr

- **WHEN** `export_emails_markdown` is called with a valid input
- **THEN** the call SHALL succeed with identical behaviour and manifest as under the canonical name
- **AND** exactly one deprecation warning line naming `batch_export_emails_markdown` SHALL be written to stderr
- **AND** the returned result SHALL NOT contain the deprecation warning

#### Scenario: Alias description marks deprecation

- **WHEN** the tool list is enumerated
- **THEN** the `export_emails_markdown` entry's description SHALL begin with `DEPRECATED — renamed to batch_export_emails_markdown`
- **AND** the `batch_export_emails_markdown` entry SHALL carry the full (non-deprecated) tool description

#### Scenario: Alias survives until the next major release

- **WHEN** any release with major version 2 is built
- **THEN** both `batch_export_emails_markdown` and `export_emails_markdown` SHALL be present in the tool list

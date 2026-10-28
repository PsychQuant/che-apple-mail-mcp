## Purpose

Ensure that attachments from either storage backend receive fresh quarantine metadata before atomic publication. Preserve descriptor-based containment and fail closed when quarantine cannot be set.

## ADDED Requirements

### Requirement: Quarantine every published attachment

The attachment publisher SHALL set com.apple.quarantine on its open temporary file descriptor before rename. Tier 1 bytes, Tier 2 staged copies, overwrites, and accepted empty attachments SHALL use the same policy. The marker SHALL identify CheAppleMailMCP with a current hexadecimal Unix timestamp and SHALL NOT inherit user approval or fabricated source metadata.

#### Scenario: Tier 1 publication

- **WHEN** extracted bytes are published, including an overwrite or accepted empty payload
- **THEN** the final file SHALL contain the exact bytes and fresh quarantine metadata

#### Scenario: Tier 2 publication

- **WHEN** a verified stage with absent or previously approved quarantine metadata is copied
- **THEN** the final file SHALL contain fresh publisher quarantine metadata independent of the stage attributes

### Requirement: Abort publication when quarantine fails

If quarantine cannot be applied, publication SHALL throw before rename, preserve an existing destination, leave an absent destination absent, and clean its temporary file. The error SHALL remain a terminal destination error rather than an acquisition retry.

#### Scenario: Unsupported or denied metadata operation

- **WHEN** quarantine application fails with ENOTSUP, EPERM, or EIO
- **THEN** no new destination SHALL become visible and prior destination content and metadata SHALL remain unchanged

### Requirement: Preserve containment and unrelated writes

Quarantine operations SHALL use the same descriptor as the temporary attachment write. The publisher SHALL retain root authorization, no-follow traversal, private staging, bounded copying, and atomic replacement. Ordinary Markdown exports SHALL retain their existing metadata policy.

#### Scenario: Parent and leaf are swapped to symlinks

- **WHEN** validated paths are swapped before publication
- **THEN** attachment bytes and quarantine SHALL be published only into the pinned destination directory and external sentinel content and attributes SHALL remain unchanged

#### Scenario: Ordinary export

- **WHEN** writeFileAtomicNoFollow publishes a Markdown export
- **THEN** the attachment quarantine policy SHALL NOT be applied

### Requirement: Distinguish verification layers

Verification records SHALL distinguish synthetic stage filesystem tests from actual Mail-produced stage observations and Gatekeeper launch checks.

#### Scenario: Native Mail is unavailable

- **WHEN** only macOS synthetic stage tests have run
- **THEN** records SHALL keep native Mail and Gatekeeper launch checks pending

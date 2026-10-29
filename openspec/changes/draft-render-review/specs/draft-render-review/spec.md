## ADDED Requirements

### Requirement: Preserve an inert review snapshot
The helper SHALL preserve the supplied RFC822 bytes in a new private bundle with a SHA256 digest and MIME content fingerprint. It SHALL refuse overwrites, parse defects, inputs above 16 MiB, more than 256 MIME parts, or nesting deeper than 16. Structural budgets SHALL be enforced during message creation and attachment while parsing, before an oversized tree is built. Quoted-printable input SHALL be checked before decoding; bare equals signs, invalid escapes or soft breaks, illegal control bytes and bare trailing whitespace SHALL be refused. It SHALL NOT execute HTML, fetch remote resources, or create files using attachment names.

#### Scenario: Prepare a multipart message
- **WHEN** a supported multipart RFC822 file is prepared
- **THEN** source.eml retains identical bytes and review.json records its fingerprint and pending client verification

#### Scenario: Unsafe or unsupported input
- **WHEN** parsing fails, a limit is exceeded, or the output already exists
- **THEN** preparation fails without reporting a usable review

### Requirement: Compare captured versions without asserting rendering
Comparison SHALL validate bundle integrity and compare the newly supplied source bytes and the received MIME content. Content fingerprints SHALL preserve MIME structure, decoded leaf bytes, Content-Type and Content-Disposition parameters, and Content-ID, while ignoring multipart boundaries and transfer-encoding representation. Matching fingerprints SHALL NOT establish sender identity, live Mail window identity, delivery, or rendering correctness.

#### Scenario: Unchanged source and equivalent transport encoding
- **WHEN** current source matches the snapshot and received content matches despite transport encoding changes
- **THEN** comparison reports readiness for client review with client_render_verified=false

#### Scenario: Source or received content differs
- **WHEN** either comparison fails
- **THEN** the helper reports the differing condition and a nonzero result without claiming client verification

### Requirement: Require actual non-Apple Mail review
The plugin workflow SHALL require an explicitly identified source and capture provenance. External test sending or uploading SHALL require explicit user approval and a designated test account. Client rendering acceptance SHALL require actual observation in the selected non-Apple Mail client, recorded with client identity, date and human result. Changed or recreated drafts SHALL require renewed review.

#### Scenario: Only offline preparation completed
- **WHEN** snapshots and content checks exist but no client observation exists
- **THEN** the workflow remains pending and SHALL NOT call it a rendering pass

#### Scenario: Real client acceptance
- **WHEN** an authorized test copy is matched to the captured source and actually inspected in Gmail
- **THEN** the workflow records the bounded human observation, without asserting all-client compatibility or automatic authorization to send the formal message

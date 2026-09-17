## ADDED Requirements

### Requirement: Authorize the full destination before side effects
The tool SHALL reject non-absolute file paths and unsafe raw segments using the existing segment predicate. It SHALL validate the full canonical path with the export allowed-roots policy and denylist before creating parents or invoking a backend.

#### Scenario: Traversal or denied leaf
- **WHEN** a caller supplies `../`, a control character, an out-of-root path, or a denied home leaf such as `.zshrc`
- **THEN** a typed destination error is returned without directory creation or Mail invocation

#### Scenario: Explicit roots replace home
- **WHEN** an operator configures a nonempty allowed-roots list
- **THEN** destinations outside those roots are rejected, including otherwise permitted home paths

### Requirement: Publish through a pinned directory
The publisher SHALL walk canonical parent components from a filesystem-root descriptor without following symlinks and SHALL atomically replace the leaf through the pinned parent descriptor. Existing links SHALL be accepted only when their canonical target passes authorization; later link swaps SHALL NOT redirect writes.

#### Scenario: Link replaced after authorization
- **WHEN** a parent or leaf is changed to a symlink after validation
- **THEN** publication either fails or writes through the authorized directory without modifying the symlink target outside the authorized tree

#### Scenario: Ordinary overwrite
- **WHEN** a permitted destination has missing parents or an existing regular file
- **THEN** parents are created safely and the file is atomically created or replaced

### Requirement: Isolate all attachment backends
SQLite bytes, attested empty data, both AppleScript entry points, and download retries SHALL share the publisher. Each Mail save attempt SHALL receive a fresh private stage path, never the caller destination. Publication errors SHALL be terminal and SHALL NOT trigger another backend.

#### Scenario: Stale or missing stage
- **WHEN** Mail claims success without creating a regular staged file
- **THEN** no destination is published and the existing typed missing/nonregular distinction is preserved

#### Scenario: Large or empty attachment
- **WHEN** a staged file exceeds 100 MB or an empty file is explicitly allowed
- **THEN** publication uses bounded memory, preserves the empty override annotation, and reports the published byte count against the caller destination

#### Scenario: Retry isolation and cleanup
- **WHEN** an attempt fails or succeeds
- **THEN** its private stage is cleaned and the next attempt uses a distinct path while preserving retry budgets and terminal errors

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
- **THEN** parents are created safely and the file is atomically created with mode 0644 as the umask allows, or replaced keeping its read and write bits; execute bits are never kept, and the temporary file is created with mode 0600

### Requirement: Isolate all attachment backends
SQLite bytes, attested empty data, both AppleScript entry points, and download retries SHALL share the publisher. Each Mail save attempt SHALL receive a fresh private stage path, never the caller destination. Publication errors SHALL be terminal and SHALL NOT trigger another backend. A 0-byte SQLite read without `allow_empty` SHALL be treated as a SQLite miss, so the AppleScript backend and the download retry still run.

#### Scenario: Stale or missing stage
- **WHEN** Mail claims success without creating a regular staged file
- **THEN** no destination is published and the existing typed missing/nonregular distinction is preserved
- **AND** a failure of the private stage itself is reported as a stage error, not a destination error

#### Scenario: Large or empty attachment
- **WHEN** a staged file exceeds 100 MB or an empty file is explicitly allowed
- **THEN** publication uses bounded memory, preserves the empty override annotation, and reports the published byte count against the caller destination

#### Scenario: Retry isolation and cleanup
- **WHEN** an attempt fails or succeeds
- **THEN** its private stage is cleaned and the next attempt uses a distinct path while preserving retry budgets and terminal errors

### Requirement: Shared policy permits cloud-sync folders and compares names as the volume does
The destination policy shared by `save_attachment` and Markdown export SHALL permit paths inside an existing directory `~/Library/CloudStorage/<folder>`, inside `~/Library/Mobile Documents/com~apple~CloudDocs`, and inside an existing `~/Library/Mobile Documents/<container>/Documents`, and SHALL deny the rest of `~/Library`, including the rest of each app container and anything directly under `CloudStorage` that is not an existing directory. The policy SHALL check the caller's own spelling of the path, and SHALL deny paths at or under the target of a denied name that is a link and of a link directly inside a denied directory (also when that directory is itself a link), including a target that does not exist yet and a target reached through a dangling link partway along it. Links deeper inside a denied directory are not followed. Denied home names SHALL be compared after full Unicode case folding and canonical normalization. The denied names SHALL include `.zshenv`, `.zlogin`, `.zlogout`, `.bash_login`, `.bash_logout`, `.claude`, `.claude.json`, `.mcp.json`, `.codex` and `.cursor` in addition to the existing list. A configured root of `/` SHALL permit every path outside the system and home denylists, and a configured root that cannot be resolved SHALL match nothing without rejecting destinations inside other roots.

#### Scenario: Cloud-synced archive folder
- **WHEN** `save_path` resolves inside `~/Library/CloudStorage/Dropbox`
- **THEN** the destination is permitted without any configuration

#### Scenario: Rest of Library
- **WHEN** `save_path` resolves inside `~/Library/LaunchAgents`, inside an app's iCloud container such as `~/Library/Mobile Documents/com~apple~mail`, or names `~/Library/CloudStorage` itself
- **THEN** a typed destination error is returned

#### Scenario: Denied name linked into a cloud folder
- **WHEN** `~/.zshrc` is a link to a file in `~/Library/CloudStorage/Dropbox`, existing or not yet created, and `save_path` names either path
- **THEN** a typed destination error is returned

#### Scenario: Link inside a denied folder
- **WHEN** `~/.claude/hooks` is a link to a directory in a configuration repository and `save_path` names a file in that directory
- **THEN** a typed destination error is returned

#### Scenario: Case-folded denied name
- **WHEN** a home component folds to a denied name, such as `.ſſh` for `.ssh`
- **THEN** a typed destination error is returned


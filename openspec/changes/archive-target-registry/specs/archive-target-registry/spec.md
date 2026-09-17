## ADDED Requirements

### Requirement: Complete explicit target registry
The registry SHALL store version 1 and a targets array, each with id, parent_id, workspace, config_file, output_dir, index_file, purpose, and filter_axis. Parents SHALL be explicit organizational relationships independent of filesystem nesting. An optional attachment_roots array SHALL declare additional absolute attachment directories; omitted SHALL mean no additional roots. The registry SHALL reject duplicate ids, cycles, missing parents, unknown fields, nonabsolute paths, and shared canonical config, output, or index paths. Index parent directories SHALL be distinct so derived threads.json files cannot overlap. It SHALL NOT automatically register discovered directories.

#### Scenario: Sibling directories have a parent relationship
- **WHEN** two targets in sibling filesystem directories declare a parent relationship
- **THEN** the registry SHALL preserve that relationship without inferring ancestry from paths

### Requirement: Index-backed cross-layer history
A selected target's snapshot SHALL include every target in its organizational tree. Every valid index Message-ID SHALL enter the history set, including entries whose markdown no longer exists. Such entries SHALL be reported as historical_index_only rather than proof of a current file location. Missing or invalid scope indexes SHALL fail the snapshot instead of silently producing partial dedup.

#### Scenario: Tombstones outnumber remaining markdown
- **WHEN** an intake index has 377 entries and only 27 corresponding markdown files
- **THEN** all 377 Message-IDs SHALL prevent recapture and 350 SHALL be disclosed as historical_index_only

### Requirement: Preserve independent capture and intake routing
The planner SHALL preserve new candidates discovered only by a child. Confirmed matched_target_ids SHALL determine a unique deepest destination for one ancestor chain. Cross-branch ambiguity SHALL stay at the lowest common ancestor intake; no match SHALL stay at root intake. Already archived IDs SHALL disclose their existing locations without recapture.

#### Scenario: Child-only discovery
- **WHEN** a child discovers a new ID absent from parent filters and the history set
- **THEN** the plan SHALL include root intake capture and the confirmed child destination

#### Scenario: Ambiguous sibling match
- **WHEN** one ID matches two sibling targets
- **THEN** the destination SHALL be their common parent intake and the plan SHALL disclose ambiguity

### Requirement: Recoverable distribution
The execution workflow SHALL serialize registered-tree operations, revalidate plan snapshots, persist a journal, verify destination content and index before recording source tombstones, and retain intake copies on destination failure. It SHALL NOT delete an unowned existing source file. Retry SHALL recover from every durable phase without losing content or recapturing committed IDs.

#### Scenario: Destination write fails
- **WHEN** a distribution fails before destination verification
- **THEN** the intake file and index SHALL remain recoverable, with the journal identifying the pending phase

### Requirement: Workflow integration and legacy compatibility
archive-mail SHALL consult the registry before registered capture, preview root capture and destination assignments, and use registry index history for tree-internal dedup. Unregistered targets SHALL retain existing behavior. External distributed_archives SHALL remain extra read-only sources, not alternate definitions of the registered hierarchy.

#### Scenario: Unregistered archive
- **WHEN** the registry is absent or the selected archive is unregistered
- **THEN** existing workspace behavior SHALL remain available without inferred registration


### Requirement: Preserve historical filename ownership
The executor SHALL reject new file paths reserved by existing index entries, including index-only tombstones, using Unicode-normalized case-insensitive comparison. It SHALL NOT make an old Message-ID appear present by assigning its former filename to a new message.

#### Scenario: Reusing an intake tombstone filename
- **WHEN** a historical ID reserves MAIL.md and a new ID proposes mail.md in that output
- **THEN** preparation SHALL fail without creating mail.md and require a different filename

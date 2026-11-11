## ADDED Requirements

### Requirement: Attachment paths must be regular files

When a composing tool validates its attachment paths (`compose_email` and `create_draft` today), the system SHALL reject every path that, after symlink resolution, is not a regular file: a directory (including a package directory such as `.rtfd` or `.app`), a FIFO, a socket, a character or block device, or a path whose final component is still a symbolic link after resolution. The type SHALL be read without following a final symbolic link, so a link that resolution could not remove is rejected rather than followed. The rejection SHALL be added to the same aggregated invalid-parameter error as the existing checks (a missing path, the deny-list, the `MAIL_MCP_ATTACHMENT_ROOTS` allow-list), as `'<path>' rejected: not a regular file (<kind>)`, and SHALL happen before any Mail operation. The system SHALL NOT open a path to decide its type. A regular file, and a symbolic link that resolves to a regular file, SHALL still be accepted. This is input validation, not an ineligibility reason of Requirement: Ineligible composing calls fail without side effects, and it does not extend that list.

#### Scenario: A FIFO is rejected without being opened

- **GIVEN** a named pipe created in a temporary directory, with no writer
- **WHEN** `validateAttachmentPaths` is called with its path
- **THEN** it throws an invalid-parameter error naming the path and `not a regular file`, and returns without blocking

#### Scenario: A directory is rejected with the other failures

- **WHEN** `validateAttachmentPaths` is called with a directory and a missing path
- **THEN** one invalid-parameter error names both: the directory as `not a regular file (directory)` and the missing path as `not found`

##### Example: attachment path kinds

| Path | Result |
| --- | --- |
| a regular file in a temporary directory | accepted |
| a symbolic link to that regular file | accepted |
| a directory | rejected: not a regular file (directory) |
| a symbolic link to a directory | rejected: not a regular file (directory) |
| a package directory named `Note.rtfd` | rejected: not a regular file (directory) |
| a FIFO created with `mkfifo` | rejected: not a regular file (FIFO) |
| `/dev/null` | rejected: not a regular file (character device) |

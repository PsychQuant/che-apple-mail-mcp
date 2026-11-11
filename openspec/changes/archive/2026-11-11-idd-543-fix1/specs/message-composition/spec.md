## MODIFIED Requirements

### Requirement: Attachment paths must be regular files

When a composing tool validates its attachment paths (`compose_email`, `create_draft`, and `update_draft` for the replacement draft), the system SHALL reject every path that, after symlink resolution, is not a regular file: a directory (including a package directory such as `.rtfd` or `.app`), a FIFO, a socket, a character or block device, or a path whose final component is still a symbolic link after resolution. Resolution SHALL make a relative path absolute against the server's working directory and then follow symbolic links without first removing `..` from the path text, so that a `..` after a symbolic link to a directory counts from that link's target, as the kernel does when it opens the path; the existence check, the deny-list, the `MAIL_MCP_ATTACHMENT_ROOTS` allow-list and the type check SHALL all judge that one resolved path. The type SHALL be read without following a final symbolic link, so a link that resolution could not remove is rejected rather than followed; a type that cannot be read SHALL be rejected as `type could not be read`. The rejection SHALL be added to the same aggregated invalid-parameter error as the existing checks (a missing path, the deny-list, the allow-list), as `'<path>' rejected: not a regular file (<kind>)`, and SHALL happen before any Mail operation, including the draft scans of `update_draft`. The system SHALL NOT open a path to decide its type. A regular file, and a symbolic link that resolves to a regular file, SHALL still be accepted. This is input validation, not an ineligibility reason of Requirement: Ineligible composing calls fail without side effects, and it does not extend that list.

#### Scenario: A FIFO is rejected without being opened

- **GIVEN** a named pipe created in a temporary directory, with no writer
- **WHEN** `validateAttachmentPaths` is called with its path
- **THEN** it throws an invalid-parameter error naming the path and `not a regular file (FIFO)`, returns without blocking, and no reader ever opens the pipe

#### Scenario: A directory is rejected with the other failures

- **WHEN** `validateAttachmentPaths` is called with a directory and a missing path
- **THEN** one invalid-parameter error names both: the directory as `not a regular file (directory)` and the missing path as `not found`

#### Scenario: update_draft validates before scanning drafts

- **WHEN** `update_draft` is called with a directory among its attachments
- **THEN** it fails with `not a regular file (directory)` before any Mail script runs

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
| `a/L/../target.txt`, L a link to `real/sub`, the file at `real/target.txt` (absolute or relative) | accepted |
| `a/L/../pipe`, a FIFO at `real/pipe`, a regular decoy at `a/pipe` | rejected: not a regular file (FIFO) |
| `allowed/L/../secret.txt` with `MAIL_MCP_ATTACHMENT_ROOTS` = `allowed`, L a link to `outside/inner`, a decoy at `allowed/secret.txt` | rejected: outside MAIL_MCP_ATTACHMENT_ROOTS allow-list |

##### Example: attachment type names

| Resolved path | Kind |
| --- | --- |
| a regular file | none (accepted) |
| a bound Unix-domain socket | socket |
| a symbolic link (the final component) | symbolic link |
| `/dev/null` | character device |
| a path that does not exist | type could not be read |

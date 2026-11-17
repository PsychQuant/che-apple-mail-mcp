## Why

#671: the attachment deny-list compares the resolved path with each sensitive directory as text. A spelling that `resolvingSymlinksInPath()` keeps and the kernel still accepts (a root-level `/.nofollow` or `/.resolve/<n>` prefix) names a deny-listed file without matching. The Diagnosis (2026-11-17) chose a comparison by file identity over rejecting the two known prefixes, because the defect is a class (spelling-dependence), and the maintainer accepted that default.

## What Changes

- `validateAttachmentPaths` keeps the string test and also compares the device and inode of each prefix of the resolved path with those of each existing deny-listed directory. A prefix or a deny-listed directory that cannot be examined rejects the path; a deny-listed directory that does not exist is skipped.
- The deny roots become an internal parameter of the validator (default: the current list) so tests can use a temporary directory; no new environment variable.
- SECURITY.md layer 3 and the limitation text, and the CHANGELOG, follow.

## Non-Goals

- Hard links to a deny-listed file stay unrecognised (documented).
- The `/private` entry that never matches after resolution is #710.
- No change to the allow-list, the regular-file check, or the `.`/`..` and NUL refusals.

## Capabilities

### New Capabilities

(none)

### Modified Capabilities

- `message-composition`: MODIFIED Requirement: Attachment paths must be regular files.

## Impact

- `Sources/CheAppleMailMCP/AppleScript/MailController.swift` (`validateAttachmentPaths`), `Tests/CheAppleMailMCPTests/MailControllerComposeTests.swift`, `SECURITY.md`, `CHANGELOG.md`, the spec above.

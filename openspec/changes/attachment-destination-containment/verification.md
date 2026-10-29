## Status

The text and counts below describe PR #436 on its September 2026 base. On 2026-10-28
the PR was re-integrated onto the current main as a local landing commit (not yet
merged); the IDD ensemble ran on it twice (reports on #402), and its fixes are listed
under "Verify fixes" at the end.

As of 2026-09-17: implementation complete; **not IDD verified**. Real Mail staging integration passed on 2026-09-17; the full Claude ensemble remains pending due to session quota. No merge, installation, release, or issue closure.

## Boundary and controls

The baseline mkdir helper, extracted unchanged from the parent commit into an isolated fixture probe, accepted `allowed/../outside/file` and created/wrote outside the intended root. The ordinary nested path also succeeded. The new boundary rejects unsafe components and unauthorized roots before directory creation or Mail invocation.

SQLite now extracts only bytes; attested empty data shares the publisher. Both string-based MailController overloads construct the destination capability, and the Server passes its already validated capability through fallback and retry. Each script writes to a fresh private stage. Missing/nonregular stages never count as success; destination publication errors are terminal. A 101 MB staged fixture proves bounded-copy publication with the correct size and endpoint bytes. Concurrent writes produce one complete file with no shared temporary files.

## Independent candidate review

One fresh read-only reviewer found a validation-to-use race: `realpath` captured an outside path, then the validator resolved a newly planted leaf symlink to an allowed target, while publication retained the outside path. A deterministic test reproduced both missing rejection and the outside replacement on the candidate. The coordinator fixed this by exposing the existing validator policy separately from canonicalization, then authorizing the exact pathname used by the no-follow descriptor walk. The same reproducer now rejects without outside publication. No second independent candidate cycle was run.

## Commands and results

- Baseline fixture probe: vulnerable traversal and legitimate control both reproduced; fixture removed afterward.
- Initial boundary test: compilation failed before the new capability existed.
- `swift test --filter 'AttachmentContainmentIntegrationTests|AttachmentDestinationTests|SaveAttachment|AttachmentDownloadScriptBuilderTests|ServerSchemaTests|RaceFreeFileWriterTests|AllowedRootsValidatorTests|ManifestToolsSetEqualityTests'`: 181 tests, 0 failures.
- Candidate race reproducer before correction: 2 assertion failures confirming the bypass. Included in the passing focused/full runs after correction.
- `REGENERATE_MCPB_MANIFEST=1 swift test --filter ManifestToolsSetEqualityTests`: 1 test passed; regenerated the tool description mirror after the first full suite detected drift.
- Final `swift test`: 1,251 tests, 10 skipped, 0 failures.
- `git diff --check`: passed.

The 181-test run above uses local generated fixtures and injected script runners; it does not itself prove native Mail staging. The separate opt-in live test below supplies that evidence. The broader pre-existing suite retains its existing setup and skip behavior. The home-minus-denylist default is the existing export policy, not exhaustive protection of unrelated home files; a narrow configured allowlist remains the deployment control. Descriptor pinning protects directory identity and symlink swaps, not a same-user adversary relocating entire open directory trees.

## Native staging evidence (2026-09-17)

`AttachmentDestinationLiveTests.testNativeMailStagePublicationAndCleanup` passed
with `MAIL_APP_INTEGRATION_TESTS=1` and one UUID-named local synthetic mailbox.
The test executes real Mail `save` through `MailController.runScript` into
`AttachmentDestination.saveUsingScript`'s production stage. Both native writes
were byte-compared against the 45-byte binary fixture. Successful publication
replaced an existing output; a deliberately identified producer error after the
second native write preserved the prior output. Distinct 0700 stages and their
cleanup were asserted. No send, real message content, or account mutation was
needed. The local fixture selector is deliberately separate from production
account resolution and does not prove remote download behavior.

The final live run executed one test with zero failures. A default-mode focused
run executed 18 tests, one live skip, zero failures. Mail's script-level mailbox
deletion returned -10000, so cleanup used the exact synthetic mailbox in Mail UI.
After the final run, the fixture and its newly created second Import parent were
removed after checking their contents; a separate native query returned `0, 0`.
The pre-existing/shared Import folder was retained. See
[reproduction instructions](../../../docs/testing/attachment-staging.md).

## Verify fixes (2026-10-28)

The IDD ensemble on the landing commit found that the shared policy denied every
cloud-sync folder: Dropbox, Google Drive, OneDrive and Box resolve into
`~/Library/CloudStorage`, iCloud Drive into `~/Library/Mobile Documents`, and the
`library` entry applied even to configured roots. The maintainer chose to permit
paths inside those two folders by default. The same round added full case folding
for denied names (`~/.ſſh` opened `~/.ssh`), shell startup and agent configuration
names to the denylist, a working root of `/`, export's handling of an unresolvable
root, mode 0644 for published files, and a Tier-1 0-byte read that falls through
to AppleScript instead of ending the call. The policy and mode fixes each have a
test that fails when the fix is reverted. Not covered that way: of the stage errors,
only the staged-link case is tested (the other `stage_failed` retypes are not); the
caller-spelling check inside `AttachmentDestination` is tested only through
`checkHomeNames`; the Tier-1 0-byte fall-through only through its helper
(`tier1BytesArePublishable`); and the restored allow_empty log line not at all. A
dispatcher-level test needs the entry point tracked in #575.

The second round found that the first carve-out was too wide and too literal: it
opened every child of `Mobile Documents`, including apps' iCloud containers such as
Mail's synced signatures, and let a denied name that is a link into a cloud folder
(`~/.zshrc` kept in Dropbox) be written through. It now permits only iCloud Drive
(`com~apple~CloudDocs`) and existing provider folders in `CloudStorage`, checks the
caller's own spelling of the path, and denies the resolved targets of denied names.
An overwrite keeps the replaced file's mode, a private-stage failure is reported as
`stage_failed`, and a path that cannot be resolved before authorization is refused
instead of reported as a write problem. The two live checks that unit tests cannot
make are tracked in #579.

The third round found two gaps in the second-round fixes and one limit of the design.
The temporary file was written before it took the replaced file's mode, so a private
file's new contents were briefly readable; it is now private from before the first
byte. A denied name linked to a file that does not exist yet was not resolved, so
writing the target would create the file the link activates; dangling links and link
chains are now resolved. And links directly inside a denied folder (`~/.claude/hooks`
in a config repository) were writable through their targets, which the mode fix made
worse by keeping a hook's execute bit; such links are now followed one step, and
execute bits are never kept. Deeper links are not followed, which is stated as the
limit of a denylist. On the maintainer's decision the Documents folders of apps'
iCloud containers are permitted again.

A fourth round, run with an explicit stopping rule (a finding is HIGH only when a caller
can reach it and a testable change closes it), found no HIGH. Its testable findings were
fixed: the temporary file is now created 0600 instead of being changed to 0600 after
creation, and a new file's mode comes from a probe file under the process's umask; a
denied folder that is itself a link is searched through the link; a dangling link
partway along a denied name's target is resolved; denied names are matched against the
names as they are on disk; an app container's Documents folder must already exist; and
a permission error before authorization is reported as one only for a path the policy
accepts as written. Not covered by a test that fails on revert: creating the temporary
file 0600 (a revert to create-then-chmod leaves the same mode inside the write
callback), and the on-disk name match (it needs a case-sensitive volume). Inherited
ACLs on the destination folder are not changed (#576 tracks it). The verify loop stops
here; the remaining shapes are the documented limit of a denylist.


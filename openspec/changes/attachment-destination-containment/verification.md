## Status

Implementation complete; **not IDD verified**. Real Mail staging integration passed on 2026-09-17; the full Claude ensemble remains pending due to session quota. No merge, installation, release, or issue closure.

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

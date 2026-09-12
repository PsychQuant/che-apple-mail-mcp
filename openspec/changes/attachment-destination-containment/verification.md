## Status

Implementation complete; **not IDD verified**. Real Mail staging integration and the full Claude ensemble remain pending. No merge, installation, release, or issue closure.

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

These attachment integration tests use local generated fixtures and injected script runners. They do not prove actual Mail.app staging behavior. The broader pre-existing suite retains its existing setup and skip behavior. The home-minus-denylist default is the existing export policy, not exhaustive protection of unrelated home files; a narrow configured allowlist remains the deployment control. Descriptor pinning protects directory identity and symlink swaps, not a same-user adversary relocating entire open directory trees.

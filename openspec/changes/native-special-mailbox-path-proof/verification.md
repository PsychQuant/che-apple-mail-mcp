## Status

Implementation complete; final Claude ensemble remains pending because the CLI OAuth session expired during round 2. Final Codex delta review passed. No merge, deployment or issue closure.

## Reproduction and boundary

The unchanged old joiner accepted Projects/Drafts and Projects/Sent together without native evidence. The new discovery stage supplies candidates only; names, parent voting, INBOX position and legacy tuple path slots cannot authorize output.

Both the account-scoped candidate and the native role object must match every expected component at a fixed depth and terminate at the exact account object. This does not use `while class == mailbox`: native parent references can report class `container` while still exposing their actual names. Object comparison is an additional check, not the sole identity premise. Literal slash components are omitted because the current string path API cannot represent them unambiguously.

## Actual native evidence

Read-only probes produced 40 correct-role matches, 40 wrong-role rejections and 12 same-name cross-account rejections. Direct and role-side native container chains each matched all 40 expected paths. No same-account/different-parent duplicate-leaf folder was available, and no user folders were created.

The opt-in committed live test ran 100 private fixture records: 40 known positives, 40 nonexistent candidates and 20 invalid top-level shorthands. It passed after both chain checks were enabled. A generated-script control retained the same real candidate/role but changed the expected ancestor; all four correct controls matched and all four wrong-ancestor controls were rejected while remaining available (see native-control-results.json). This exercises the ancestor guard directly.

The actual built MCP binary also completed initialize + get_special_mailboxes and returned five paths, four nested, for the selected nested-provider account. Per-account leaf lookup was moved to JSON over the existing non-GUI subprocess transport after the in-process query did not finish in the observation window. Unified mode is unchanged.

Cold standalone helper probes intermittently reported Mail unavailable before application-context preparation; prepared live tests and the actual MCP flow succeeded. This is an observed availability limitation, not proof of a resolved bootstrap issue. No message content was inspected by the new metadata probes; existing server startup synchronization remains unchanged.

## Validation

- Focused special-mailbox tests passed (57 tests before the optional live gate was added).
- `MAIL_APP_INTEGRATION_TESTS=1 MAIL_SPECIAL_MAILBOX_FIXTURE=<private fixture> swift test --filter SpecialMailboxNativeProofLiveTests`: one live test passed, covering 100 records.
- Final `swift test`: 1,255 tests, 11 skipped, zero failures. The extra skipped case is the explicit opt-in native gate, separately run above.
- Tool manifest equality/regeneration and Spectra validation passed; `git diff --check` passed.

## Review and limits

Round 1 completed all four Claude lenses, Claude adversarial review and Codex. The principal condition was native identity/parent evidence. Fixed-depth checks of both objects and executable live evidence were then added. Round 2 Claude processes could not authenticate; Codex completed. A final bounded Codex review of the exact chain guard passed, with no blocking defect. Do not label the full final ensemble complete until Claude is authenticated and the final patch is reviewed.

The native API observations do not establish all provider/version combinations or an atomic snapshot across Mail configuration changes. Qualified leaf representations that cannot match native components remain omitted. Native equality/reference behavior was checked against the [AppleScript language reference](https://developer.apple.com/library/archive/documentation/AppleScript/Conceptual/AppleScriptLangGuide/reference/ASLR_classes.html); the actual probes, not documentation alone, establish the tested Mail behavior. No claim is made that the unavailable real duplicate-folder fixture was executed.

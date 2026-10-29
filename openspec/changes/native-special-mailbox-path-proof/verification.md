## Status

The evidence below was recorded on PR #443's September 2026 base. On 2026-10-28 it was
re-integrated onto the current main as a local landing commit (not yet merged), where
the IDD ensemble ran on it (report on #376); see "Landing" at the end.

As of 2026-09: implementation complete; final Claude ensemble remains pending because the CLI OAuth session expired during round 2. Final Codex delta review passed. No merge, deployment or issue closure.

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

## Landing (2026-10-28)

- Per-account leaf names are read in process again, as on main. The PR moved that
  lookup to a subprocess because the in-process query did not finish; main later fixed
  that first-call hang (#471), and keeping the lookup off the proof's transport keeps the
  leaf names when the proof cannot run.
- The opt-in direct-write draft path (#472/#475) now finds Drafts through the same proof.
  It proves only Drafts candidates and writes to the components of the confirmed
  candidate; a proof that cannot run gives `drafts_unidentified`, one that confirms
  nothing gives `drafts_unmatched`, both before any write. `directDraftsTarget` is unit
  tested; the full direct-write flow has no test entry yet (#484).
- A proof that times out reports a read-only timeout instead of the generic subprocess
  message, which said a save or send may have happened.
- Folder names with control characters are no longer candidates; one such name used to
  break the proof script for every candidate of the account.
- The same-account lookalike (#376's own example, an ordinary `Projects/Drafts` with the
  real Drafts elsewhere) has still not been run on real Mail. #376 stays open with
  `blocked-on-setup`, and the tool description says so. The "40 wrong-role" controls
  above compare a role's real mailbox with another role's leaf; they do not exercise a
  same-account, same-leaf, different-parent folder.


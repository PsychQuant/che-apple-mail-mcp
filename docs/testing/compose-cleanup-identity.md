# Compose cleanup after window identification

Refs #333. This change addresses the post-identification discard risk found by
the historical PR #407 cross-model supplement: after the owned native window
closes or disappears, a remaining same-title AX window must not become the
cleanup target.

## Implemented boundaries

- Native window metadata is collected as paired IDs and titles. Missing/wrong
  types and incomplete reads do not establish ownership. A missing title is not
  coerced into the literal string `missing value`.
- Ownership states distinguish absent, owned, changed, ambiguous, unknown, and
  wrong-front. Verified absence ends cleanup without entering the AX phase.
- Native close requires the captured ID and unchanged text title. A changed or
  ambiguous owner is retained with an actionable disclosure.
- The AX scan must be complete and identify exactly one case-sensitive title
  match. Its matched target is retained rather than performing a second search
  with different comparison semantics.
- Native ownership is checked before AXRaise, after it with front-window
  validation, and immediately before the discard action. Only the recognized
  save-message sheet and supported exact discard labels are used.
- Unknown state is reported as unverified, not as proof the window is open or
  closed. The original compose error remains; post-dispatch sends still bypass
  cleanup.

## Executed evidence

The tests execute the generated orchestration, native-close selection, and AX
control flow with only external Mail/AX operations replaced. No real Mail
window is opened or discarded by these fixtures.

- Initial orchestration: 4 tests / 5 failures before the correction.
- Initial owner classifier: 1 test / 7 failures before implementation.
- Missing-title coercion and mismatched title-comparison regressions were
  observed before correction; the latter reached two actions instead of one.
- Removing the final native check was caught by the before-click failure case.
  The production source was restored byte-for-byte after this mutation.
- Native-close tests preserve other IDs and changed/unknown titles. AX fixtures
  cover owner loss, wrong front window, partial and ambiguous enumeration,
  title case, and the supported discard labels versus Save/Cancel/Done.
- Full generated draft and send scripts compile with `osacompile`.
- Adding the helper exposed a false-positive prelaunch test: it selected the
  first Mail block instead of the actual `_beforeIds` block. The extraction is
  now anchored, unexpected errors fail, and removing the collision refusal
  demonstrably reaches all three simulated launches.
- Final focused suite: 66 tests, zero failures. Final full Swift suite:
  **1,240 tests / 10 skipped / 0 failures** (312 SQLite + 928 server).
- Two bounded Codex reviews: the first identified the prelaunch test gap; the
  follow-up found no remaining actionable defect in this correction. These
  were static reviews and do not replace full IDD review.

## Limits and remaining gates

Native-to-AX checks and actions are not atomic. This work does not prove AX
reference lifetime behavior under every replacement race, or detect every
possible user body edit that preserves the window's title. Real Mail sheet
behavior, native metadata availability while a sheet is open, and cleanup/retry
idempotence still require controlled live validation.

The pre-identification case still lacks trusted evidence identifying which
window was created; do not close an arbitrary new or same-title window. That
work depends on the remaining creation-binding investigation. Signature menu
tracking also has its own constraints in #322: native Mail queries during an
open NSMenu can block. Integration must preserve that component's menu-dismissal
guard before invoking these native cleanup reads.

This is a tested correction to one unsafe path, not complete delivery of #333.

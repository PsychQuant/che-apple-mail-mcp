# Account-scoped draft ID baseline

Refs #409. This is an independent foundation component. It is not connected to
`create_draft`, `update_draft`, or the legacy receipt readers; the creation
adapter's live gate must pass before that wiring is completed.

`MailController.readDraftIDBaseline(accountIDs:)` takes a nonempty set of account
UUIDs and performs one bounded, non-GUI drafts scan. It reads Drafts role/account
metadata, then message IDs only for requested accounts. It never reads subject,
body, or recipient fields and has no Mail mutation. Multiple Drafts containers
for an account contribute to the same ID set. Identical numeric IDs in different
accounts remain distinct.

A requested account must have an observed Drafts container. An empty container
is a valid empty set; an absent scope or any enumeration/read failure makes the
whole result unavailable. There is no partial snapshot or automatic retry.
The result is membership data, not creation identity and not deletion authority.
It is not an atomic Mail snapshot or proof that row IDs survive later saves.

## Automated coverage

`DraftIDBaselineTests` executes the real collector with only native Mail access
helpers replaced by controlled inputs. It covers scoped reads, multiple
containers, empty/missing scopes, metadata/ID errors, large decimal ID strings,
malformed payloads, and controller no-retry/error normalization. The existing
receipt wire tests share duplicate-aware JSON validation with the baseline.

Both decoders require UTF-8, reject literal NUL and duplicate object members,
and decode escaped key names before checking duplicates. Quoted content and
escaped NUL inside string values remain data. UTF-16/32 auto-detection cannot
bypass duplicate validation.

## Optional native read-only check

Choose one existing account with exactly one native Drafts role for the
independent count control. Supply its UUID as a private environment value:

```sh
MAIL_APP_INTEGRATION_TESTS=1 CHE_MAIL_BASELINE_LIVE_ACCOUNT=ACCOUNT_UUID \
  swift test --filter DraftIDBaselineTests/testNativeReadOnlySnapshotMatchesStableCountWhenOptedIn
```

The test counts that role before and after invoking the real collector. If the
counts change, it skips the unstable observation rather than treating it as a
pass. It checks the returned scope and unique ID count, and prints counts only.
No fixture, draft, mailbox, rule, or permission change is created. The count
control limits this live check to a single role; the collector's multiple-role
behavior is exercised by the controlled execution tests.

On 2026-09-17, the final native check passed in 2.06 seconds: one requested
account, 65 IDs, and matching independent counts. This confirms the read path,
not same-subject replacement, stable identity, or the future pre-create order.
The first native attempt failed in the test's count-expression coercion before
the collector ran; parenthesizing the count corrected that test control.

Full ordinary Swift validation: 1,247 tests, 11 skipped, zero failures. This
includes the opt-in native test being skipped; the separate native run above is
the actual live evidence. Bounded Codex review found duplicate-member and
encoding issues; both had failing regression cases before correction. The final
bounded source review found no remaining actionable defect in this component.
Full IDD review and the rest of #409 remain incomplete.

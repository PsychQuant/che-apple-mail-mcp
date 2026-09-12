## Status

Implementation complete; final independent re-verification and the full IDD ensemble remain pending. Claude weekly quota is unavailable. No merge, deployment, account-setting change, address-cache file, archive migration or verified tag.

## Source and native evidence

Mail's installed scripting dictionary defines email addresses as the configured address list. Read-only metadata probes confirmed address availability and native-account/index-ID correlation without reading message content or printing address values. The fixed AppleScriptObjC producer emitted a valid counted JSON snapshot with boolean availability flags.

A probe linked to the actual final application objects called configuredAccountIdentities with no fake runner: permission_state=granted, snapshot_accounts=8, snapshot_complete=true, snapshot_address_count=8, exit=0. This verifies the real helper/JSON bridge on the current host. Each native account returned one address; actual multi-alias configuration was not changed or exercised. Alias collection and classification use synthetic multi-address fixtures plus the provider's documented property contract.

## Automated evidence

- Cache/export tests cover TTL, forced invalidation, backoff expiry, shared refresh, cancellation, caller timeout, no duplicate retry while pending, late success, EWS/alias/external direction, partial metadata and disclosed SQLite fallback.
- The native-controller fake-runner test exercises its actual snapshot method with one metadata script, not per-message headers calls.
- Address-boundary reproducers showed dropped malformed tails and incorrect prefix/comment handling before their fixes (each reproducer produced eight assertion failures). Dedicated configured-address scanning now rejects ambiguous prefixes/lists/trailing data, handles quoted names and nested comments, and preserves separator CFWS without joining atom text across comments. General From parsing remains unchanged. The boundary follows the name-addr/CFWS distinction in [RFC 5322](https://www.rfc-editor.org/rfc/rfc5322.html#section-3.4.1); underlying addr-spec shaping remains the existing conservative comparison helper, not a new complete SMTP validator.
- Final focused command: `swift test --filter 'AccountIdentityTests|CachedIdentityExportTests|EmailAddressCanonicalTests|ExportDirectionIdentityTests'` — 38 tests, zero failures.
- Final `swift test` — 1,257 tests, 10 skipped, zero failures.
- Tool manifest equality/regeneration passed (no manifest diff was needed for the input-schema-only additions). Spectra validation and `git diff --check` passed.

## Review

Codex round 1 passed the cache/export design but noted missing address-parser context. Parent inspection then reproduced a permissive-parser completeness gap. Round 2 found an unquoted-address prefix and legal-comment regression in the new configured-address helper. Both were reproduced and fixed, followed by focused/full tests and the final native probe. No third independent round was run; do not treat the earlier PASS as verification of the final helper.

## Limits

The cache represents Mail-configured addresses at refresh time, not every SMTP From permission or historical ownership. TTL is 300 seconds; explicit refresh invalidates the old view and joins existing work. Five seconds is the caller wait budget, not a promise that every underlying queued/native operation has terminated. A permanently stuck loader remains one flight and can require a server restart. Partial/failed metadata is disclosed; fallback positive matches also carry direction_inferred. Once export writes have begun, this change does not add cancellation/rollback semantics. New fixtures perform no real archive writes; existing broader tests retain their prior startup behavior.

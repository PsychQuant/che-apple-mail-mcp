# VIP classification protection (#586)

This patch is stacked on PR #447 at `34a40763905f337ad087f4b502b0653c3870825f`
(`codex/356-email-classification`), which was still open and draft when checked
on 2026-10-29. It does not implement #585's rule-specificity or approval changes.

## Behavior and source evidence

- Approved rules do not override `vip_protected` or `vip_status_unknown`.
  Both stay in proposed-trash preview and require actual confirmation of the
  selected message IDs. Confirmation does not bypass a changed fingerprint,
  changed policy, audit failure, or persistent duplicate-dispatch block.
- The existing `list_vip_senders` reader reads `VIPMailboxes.plist` on each call,
  does not normalize addresses, and collapses read/parse failure to an empty
  array. Its AppleScript fallback enumerates senders of existing VIP mailbox
  messages. Neither empty result proves that a sender is not a VIP.
- The new reader shares the existing MailData path, strictly parses bounded
  regular files, rejects symlinks and file changes during a read, and never
  retains a prior success after failure. Address comparison applies the same
  conservative canonicalization to both sides. Unsupported/ambiguous forms,
  including quoted local parts with equivalent spellings, yield unknown.
- Observation lifetime is 60 seconds; clock rollback also invalidates it.
  Freshness is measured from the read, not the file's modification time.
  Preview, apply refresh, and the native dispatch boundary each reread.
- **Current production source completeness is unverified.** The repository has
  no current native fixture proving that `VIPMailboxes.plist` contains every
  VIP sender. Historical V2 `VIPSenders.plist` examples are not proof of the
  current V10 source. `read()` therefore retains positive matches but returns
  unknown for all misses, including syntactically valid empty lists.
  **All production proposed-trash items require per-message confirmation in
  this release.** There is no MCP, CLI, environment, or configuration bypass.
- `parse()`'s complete-source contract is exercised with known complete
  synthetic fixtures to test the non-VIP automatic path. It is not exposed as
  an alternate production provider. A later change must establish native
  source/schema/update completeness before enabling negative proofs: use owned
  synthetic sender records to demonstrate add/remove/empty-list behavior and
  Mail persistence timing, record the OS/Mail version, and retain only a
  de-identified format fixture. A recent filesystem read alone cannot prove
  that Mail has flushed its current in-memory VIP settings.

No real mail was moved or real classification rule approved for this patch.
The earlier native #356 result in `classification-trash.md` does not validate
this patch's VIP source. Mail offers no atomic transaction between the last
VIP check and native movement; the external-change window remains explicit.

## Regression evidence

| Stage | Commit / macOS run | Result |
| --- | --- | --- |
| Original gap, before implementation | `383d0eb` / [40805595114](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40805595114) | Four VIP tests: the known non-VIP control passed; VIP, unknown, and fingerprint tests produced six failed assertions. |
| Initial integration | `e45d89a` / [40806428146](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40806428146) | 17 VIP tests and 51 existing classification tests passed. Full suite exposed manifest description drift (subsequently fixed) and a Mail-not-running test failure reproduced on the unchanged base. |
| Unverified-source gap, before completeness gate | `c18bc01` / [40806627389](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40806627389) | The new valid-empty/nonmatching file regression failed twice because the reader returned false instead of unknown. |
| Final implementation | `b9e95c3` / [40807222109](https://github.com/PsychQuant/che-apple-mail-mcp/actions/runs/40807222109) | 18 VIP tests and 53 classification tests passed; both plugin suites passed (111 + 140 assertions). Full Swift suite: 1,345 tests, 66 skipped, one pre-existing Mail-dependent failure; same failure reproduced on the unchanged base in the same job. |

The final implementation ran on macOS 15.7.9 with Apple Swift 6.1.2. The full
suite's only failure is
`SpecialMailboxesScriptBuilderTests.test_runScriptAsList_preservesEmptyStringPositions`:
the automation preflight reports that Mail.app is not running. The comparison
worktree uses the exact unchanged PR base `34a40763905f337ad087f4b502b0653c3870825f`
and reproduces that error. The workflow intentionally remains failed rather
than hiding it with an exclusion or `continue-on-error`. The manifest equality
test and the new unverified-source regression both pass. Live Mail tests remain
opt-in; skipped tests are not claimed as validated native behavior.

The follow-up commit only records these results and aligns the Spectra text;
it does not change source, tests, workflow, manifest, or plugin behavior from
the tested `b9e95c3` tree.

The targeted suites cover VIP/non-VIP/unknown, display-name/case normalization,
ambiguous and equivalent quoted addresses, expiry/rollback, missing/corrupt/
partial/oversize/nonregular files, atomic file replacement, approved and edited
rules, flagged/draft protection, stale-plan rejection even with confirmation,
actual server dispatch, final-boundary failure, audit-before-move, and duplicate
dispatch prevention.

## Local checks and review

The Linux development environment has no Swift executable. The local plugin
runner stopped in `test-session-start-hook.sh` with 103 passed and 8 failed
assertions in its mocked live-process warning cases; this is not reported as a
passing plugin run. The wrapper suite was also invoked independently after the
runner stopped; it exited 1 with release-metadata/mock-process failures and
unsupported BSD `stat` usage on Linux. Its production parser requires macOS `/usr/bin/plutil`, which is absent in this environment.
The macOS CI plugin step passes both shipped suites; Linux results are not a substitute.

`git diff --check` and `spxa validate local-email-classification` pass.
`spxa analyze` reports no coverage/consistency/gap/localization findings; its
remaining suggestions request concrete examples for existing scenarios.

Independent review found a quoted-local-part comparison gap and an unverified
source-completeness assumption; both were fixed with regression coverage. The
follow-up review found no reachable production bypass of the source gate.
This limited #586 review does not complete the parent change's open full IDD
review task or establish a native VIP data contract.

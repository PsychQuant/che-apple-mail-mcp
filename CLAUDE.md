<!-- SPECTRA:START v1.0.1 -->

# Spectra Instructions

This project uses Spectra for Spec-Driven Development(SDD). Specs live in `openspec/specs/`, change proposals in `openspec/changes/`.

## Use `/spectra:*` skills when:

- A discussion needs structure before coding → `/spectra:discuss`
- User wants to plan, propose, or design a change → `/spectra:propose`
- Tasks are ready to implement → `/spectra:apply`
- There's an in-progress change to continue → `/spectra:ingest`
- User asks about specs or how something works → `/spectra:ask`
- Implementation is done → `/spectra:archive`

## Workflow

discuss? → propose → apply ⇄ ingest → archive

- `discuss` is optional — skip if requirements are clear
- Requirements change mid-work? Plan mode → `ingest` → resume `apply`

## Parked Changes

Changes can be parked（暫存）— temporarily moved out of `openspec/changes/`. Parked changes won't appear in `spectra list` but can be found with `spectra list --parked`. To restore: `spectra unpark <name>`. The `/spectra:apply` and `/spectra:ingest` skills handle parked changes automatically.

<!-- SPECTRA:END -->

## Testing: 測試郵件的收件人只能是維護者自己（CRITICAL，安全規則）

**任何會產生、儲存或寄出郵件的測試，To／Cc／Bcc 只能是維護者自己的位址**（`list_accounts` 可查）。適用於 live 測試、手動 smoke、診斷重現、agent 自動測試，人與 agent 都一樣。單元測試（不碰 Mail）不受影響。

禁止：

- 拿**真實往來中的信件**當 `reply_email`／`forward_email`／`redirect_email` 的目標。這三個工具的預設收件人都來自原信，目標選錯，收件人就是真人。
- 在有第三方的信上用 `reply_all`。
- 用任何真實第三方的位址當測試收件人。

要測 reply／forward／redirect 這類工具，這樣做：

1. 先用 `compose_email` 寄一封**只寄給自己**的測試信（主旨標明「測試」）。
2. 在收件匣找到那封信，對它操作。
3. 動手前先說出收件人與目標信件，並確認目標信件的寄件人與收件人都只有維護者自己。
4. 草稿建出來後，先讀它的 `To`／`Cc`，確認只有自己，再做其他事。
5. 測完刪除測試草稿與測試信，並回報刪了哪些。

**為什麼這是安全邊界，不是風格規則**：草稿一旦存在，就只差一次按鍵就寄出，所以 `save_as_draft` 不算安全邊界。這個 server 自己記錄的失敗模式也說明「只存草稿」不可靠：#461（成功回報但內文為空）、#242（送出階段失敗時寄送狀態未知，信可能已寄出）。2026-10-15 診斷 #510 時，agent 拿真實往來的信件當 `reply_email(save_as_draft)` 的目標，草稿的預設收件人是真實第三方；沒有寄出，但維護者要求此後一律只寄給自己，並要求寫進本檔（#511）。

## Release Process

Releases are published with `scripts/release.sh`, which bundles the previously
error-prone manual sequence (`swift build` → `git tag` → `gh release create`
→ `gh release upload`) into one command. **Always use the script** — the v2.1.1
release was broken because the manual `gh release upload` step was forgotten
(see [#13](https://github.com/PsychQuant/che-apple-mail-mcp/issues/13)).

### Publishing a new release

Prerequisites:

1. CHANGELOG.md has a new `## [X.Y.Z]` section with the release notes
2. HEAD is on `main`, working tree is clean, and the commit is pushed to origin
3. `gh` CLI is authenticated

Run:

```bash
./scripts/release.sh vX.Y.Z
# or, with a custom title:
./scripts/release.sh vX.Y.Z "vX.Y.Z: short description"
```

The script will:

1. Sanity-check the working tree, tag absence, and CHANGELOG entry
2. Extract release notes from CHANGELOG.md's `[X.Y.Z]` section
3. Build a **universal** (arm64 + x86_64) binary into `.build/dist/`
4. Confirm with you before any destructive / remote operation
5. **Sign + notarize** the binary (Developer ID), unless `SKIP_CODESIGN=1` or no `DEVELOPER_ID` is set
6. Create git tag `vX.Y.Z`, push to origin
7. Create GitHub release and upload the signed binary + `.sha256`

For a signed release, export `DEVELOPER_ID` + `NOTARY_PROFILE` and prefer
`make release-signed VERSION=vX.Y.Z` (sets `REQUIRE_CODESIGN=1` so it refuses to
ship an unsigned binary). See README "Signing & Notarization" for one-time
setup and why signing is what keeps Full Disk Access working across upgrades
([#211](https://github.com/PsychQuant/che-apple-mail-mcp/issues/211)).

After the script finishes, bump `plugin/.claude-plugin/plugin.json`'s **`version`
and `binary_version`** in this repo — the installed-plugin cache is keyed by
`version`, so bumping only `binary_version` ships nothing (#335 verify). Mirror
the new `version` into `.claude-plugin/marketplace.json`'s plugin entry
(`ManifestVersionTests` pins the two equal; the root manifest deliberately
carries no `binary_version` — `plugin.json` is the single source for the binary
pin). Then run `/plugin marketplace update che-apple-mail-mcp` and
`/plugin update che-apple-mail-mcp@che-apple-mail-mcp`.

Fresh install (documented nowhere before #335 verify):
`claude plugin marketplace add PsychQuant/che-apple-mail-mcp`, then
`claude plugin install che-apple-mail-mcp@che-apple-mail-mcp`.

### Future: automate via GitHub Actions

A `.github/workflows/release.yml` triggered on tag push would remove the
manual step entirely, but requires a macOS runner (limited on GitHub free
tier) and potentially code signing / notarization. Tracked as a follow-up
to [#13](https://github.com/PsychQuant/che-apple-mail-mcp/issues/13).

### Why not tag from HEAD automatically in the script

The script intentionally tags **the current HEAD**. This means:

- If you forgot to commit the CHANGELOG, the sanity check catches it.
- If you have local commits not yet pushed, the sanity check catches it.
- You stay in control of what exactly gets tagged — no surprises.


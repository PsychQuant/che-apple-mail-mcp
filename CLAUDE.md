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
3. `swift build -c release` to produce `.build/release/CheAppleMailMCP`
4. Confirm with you before any destructive / remote operation
5. Create git tag `vX.Y.Z`, push to origin
6. Create GitHub release and upload the binary

After the script finishes, update `marketplace.json` in
[`psychquant-claude-plugins`](https://github.com/PsychQuant/psychquant-claude-plugins)
to bump the plugin's version, then run
`/plugin marketplace update psychquant-claude-plugins`
in Claude Code to pick up the new binary.

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


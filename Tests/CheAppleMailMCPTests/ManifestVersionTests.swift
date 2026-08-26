import XCTest

/// #311 — mcpb/manifest.json's `version` had no owner in the release pipeline
/// and froze at 2.7.2 for ~18 releases, masked because Server.swift's
/// then-hardcoded handshake version had rotted to the same value. This pins
/// the manifest to the newest released CHANGELOG header — the same invariant
/// `scripts/release.sh` now enforces at tag time — so the drift is caught in
/// CI between releases, not discovered by a user reading the bundle.
final class ManifestVersionTests: XCTestCase {

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CheAppleMailMCPTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
    }

    private func newestChangelogVersion() throws -> String {
        // #349: one shared parser (`scripts/changelog.py`). This used to be the
        // second of three independent readings of the same file — it required
        // three integer components while `VersionTests` went through `SemVer()`,
        // so a `## [2.27.0-rc1]` header made them measure different releases.
        let probe = try ChangelogParserTests.run(
            ["newest"], changelog: repoRoot().appendingPathComponent("CHANGELOG.md").path)
        guard probe.status == 0, !probe.out.isEmpty else {
            XCTFail("no released ## [x.y.z] header found in CHANGELOG.md")
            return ""
        }
        return probe.out
    }

    func testManifestVersionMatchesNewestRelease() throws {
        let data = try Data(contentsOf: repoRoot().appendingPathComponent("mcpb/manifest.json"))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let manifestVersion = try XCTUnwrap(obj["version"] as? String,
                                            "mcpb/manifest.json must declare a version")
        let newest = try newestChangelogVersion()
        XCTAssertEqual(manifestVersion, newest,
            "mcpb/manifest.json version ('\(manifestVersion)') must match the newest released "
            + "CHANGELOG header ('\(newest)') — it froze at 2.7.2 for ~18 releases because "
            + "nothing owned it (#311). Bump it alongside the CHANGELOG at release prep.")
    }

    func testMarketplaceEntryVersionMatchesPluginManifest() throws {
        // #335 verify: the self-hosted marketplace re-declares the shell `version`
        // (the marketplace schema wants one per entry), so the pair can drift exactly
        // the way marketplace/plugin `binary_version` did in the aggregator era.
        // Pin them equal — and pin the deliberate ABSENCE of `binary_version` in the
        // marketplace entry, which is #335's load-bearing single-source decision.
        let root = repoRoot()
        let mktData = try Data(contentsOf: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        let mkt = try XCTUnwrap(try JSONSerialization.jsonObject(with: mktData) as? [String: Any])
        let plugins = try XCTUnwrap(mkt["plugins"] as? [[String: Any]])
        let entry = try XCTUnwrap(plugins.first, "marketplace.json must list the plugin entry")
        let entryVersion = try XCTUnwrap(entry["version"] as? String)

        let pjData = try Data(contentsOf: root.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        let pluginVersion = try XCTUnwrap(pj["version"] as? String)

        XCTAssertEqual(entryVersion, pluginVersion,
            "marketplace entry version ('\(entryVersion)') must equal plugin.json version "
            + "('\(pluginVersion)') — the shell version is declared in both manifests, and "
            + "an unowned duplicated field is exactly how the aggregator-era binary_version "
            + "drift happened (#335 verify).")
        XCTAssertNil(entry["binary_version"],
            "the marketplace entry must NOT declare binary_version — plugin.json is the "
            + "single source for the binary pin (#335's design decision).")
    }

    func testDescriptionsCarryNoVersionNarrative() throws {
        // #396: the 18.8KB description-as-changelog convention is dead — narrative
        // lives in plugin/CHANGELOG.md. Round-2 hardening (#400 verify): every
        // description-carrying surface must EXIST (a deleted key must not pass
        // vacuously), stay short, and carry no semver-shaped token at all — the
        // round-1 literal markers ("Shell v", "binary stays") only locked the
        // last incident's exact strings, not the class.
        let root = repoRoot()
        var inspected = 0

        func check(_ desc: String, at label: String) {
            inspected += 1
            XCTAssertFalse(desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "\(label): description is empty")
            XCTAssertLessThan(desc.count, 1000,
                "\(label): description is \(desc.count) chars — narrative belongs in plugin/CHANGELOG.md (#396)")
            // Token-bounded so an IP address is not mistaken for a version.
            // The lookahead is (?!\.?[0-9A-Za-z]), NOT (?![0-9A-Za-z.]): the
            // latter let a version at the end of a sentence ("ships v2.28.0.")
            // escape the ban, because the trailing period satisfied it. Found
            // by mutation-testing this guard.
            XCTAssertNil(desc.range(of: #"(?<![0-9A-Za-z.])v?[0-9]+\.[0-9]+\.[0-9]+(?!\.?[0-9A-Za-z])"#,
                                    options: .regularExpression),
                "\(label): description contains a semver-shaped token — any version claim here "
                + "starts lying the release after it was written (#396)")
        }

        let pjData = try Data(contentsOf: root.appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        check(try XCTUnwrap(pj["description"] as? String, "plugin.json must declare a description"),
              at: "plugin.json")

        let mktData = try Data(contentsOf: root.appendingPathComponent(".claude-plugin/marketplace.json"))
        let mkt = try XCTUnwrap(try JSONSerialization.jsonObject(with: mktData) as? [String: Any])
        check(try XCTUnwrap(mkt["description"] as? String, "marketplace.json must declare a top-level description"),
              at: "marketplace.json (top-level)")
        // By NAME, not `plugins.first`: the moment this manifest lists a second
        // plugin, position stops identifying anything and the guard silently
        // moves to whichever entry happens to be first (#396 verify).
        let pluginName = try XCTUnwrap(pj["name"] as? String)
        let plugins = try XCTUnwrap(mkt["plugins"] as? [[String: Any]])
        let entry = try XCTUnwrap(plugins.first { ($0["name"] as? String) == pluginName },
            "marketplace.json lists no entry named '\(pluginName)'")
        check(try XCTUnwrap(entry["description"] as? String, "marketplace entry must declare a description"),
              at: "marketplace.json (entry)")

        // Not `== 3`, which would be true however few surfaces existed: assert
        // each named surface was reached.
        XCTAssertEqual(inspected, 3,
            "expected plugin.json + marketplace top-level + marketplace entry '\(pluginName)' "
            + "to be inspected; got \(inspected)")
    }

    func testPluginChangelogNewestMatchesPluginVersion() throws {
        // #396 round 2: plugin/CHANGELOG.md is the anointed single shell-narrative
        // source, but a single source with no owner rots (this repo's #311 lesson;
        // at anointing time it was already two minor versions behind). Pin its
        // newest released header to plugin.json's `version` — a shell release that
        // forgets its changelog entry now fails the suite.
        let probe = try ChangelogParserTests.run(
            ["newest"], changelog: repoRoot().appendingPathComponent("plugin/CHANGELOG.md").path)
        guard probe.status == 0, !probe.out.isEmpty else {
            XCTFail("no released ## [x.y.z] header found in plugin/CHANGELOG.md")
            return
        }
        let pjData = try Data(contentsOf: repoRoot().appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        let shellVersion = try XCTUnwrap(pj["version"] as? String)
        XCTAssertEqual(probe.out, shellVersion,
            "plugin/CHANGELOG.md newest released header ('\(probe.out)') must match plugin.json "
            + "version ('\(shellVersion)') — the single narrative source needs an owner (#396); "
            + "write the release entry alongside the version bump.")

        // Owning the header string alone is not owning the narrative: an empty
        // `## [x.y.z]` section satisfies the equality above while saying
        // nothing (#396 verify). Require prose under the newest header.
        let changelog = try String(
            contentsOf: repoRoot().appendingPathComponent("plugin/CHANGELOG.md"), encoding: .utf8)
        let lines = changelog.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headerIndex = lines.firstIndex(where: { $0.hasPrefix("## [\(probe.out)]") }) else {
            XCTFail("could not locate the '## [\(probe.out)]' section body")
            return
        }
        var body: [String] = []
        for line in lines[(headerIndex + 1)...] {
            if line.hasPrefix("## ") { break }
            body.append(line)
        }
        let substantive = body.filter {
            let s = $0.trimmingCharacters(in: .whitespaces)
            return !s.isEmpty && !s.hasPrefix("###")
        }
        XCTAssertFalse(substantive.isEmpty,
            "plugin/CHANGELOG.md's newest section '[\(probe.out)]' has a header and no content — "
            + "the guard owns the version string, but the point is owning the narrative (#396).")
    }

    func testPluginChangelogIsOrderedAndComplete() throws {
        // #396 verify round 3. The round-2 backfill shipped three defects that
        // NOTHING in this suite could see, because every guard here checked the
        // newest entry only:
        //   1. `[2.19.7]` was inserted ABOVE `[2.20.0]` — the version ordering
        //      silently broke;
        //   2. nine dates were an invented one-per-day descending sequence
        //      rather than looked-up values (2.29.0–2.33.0 all shipped on the
        //      SAME day, ~8 hours apart);
        //   3. `2.11.0` / `2.8.0` / `2.7.0` / `2.5.1` had no entry AND sat
        //      outside both declared gaps, while the file carried a sentence
        //      certifying that no such version existed.
        //
        // Dates cannot be re-derived offline — they live in another repo's
        // commit history. What CAN be enforced locally is the structure that
        // makes a fabricated or misfiled entry visible: strictly descending
        // versions, non-increasing dates, and no skipped minor. All three were
        // violated by the round-2 file and all three are cheap to check.
        let text = try String(
            contentsOf: repoRoot().appendingPathComponent("plugin/CHANGELOG.md"), encoding: .utf8)

        let re = try NSRegularExpression(
            pattern: #"^## \[(\d+)\.(\d+)\.(\d+)\] - (\d{4}-\d{2}-\d{2})$"#,
            options: [.anchorsMatchLines])
        var entries: [(v: [Int], date: String, raw: String)] = []
        let range = NSRange(text.startIndex..., in: text)
        re.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match,
                  let r1 = Range(match.range(at: 1), in: text),
                  let r2 = Range(match.range(at: 2), in: text),
                  let r3 = Range(match.range(at: 3), in: text),
                  let r4 = Range(match.range(at: 4), in: text) else { return }
            let v = [Int(text[r1])!, Int(text[r2])!, Int(text[r3])!]
            entries.append((v, String(text[r4]), "\(v[0]).\(v[1]).\(v[2])"))
        }
        XCTAssertGreaterThan(entries.count, 40,
            "expected the full release history in plugin/CHANGELOG.md, found \(entries.count) entries")

        // 1. strictly descending versions
        for i in 0..<(entries.count - 1) {
            let a = entries[i], b = entries[i + 1]
            XCTAssertTrue(a.v.lexicographicallyPrecedes(b.v) == false && a.v != b.v,
                "plugin/CHANGELOG.md: [\(a.raw)] appears before [\(b.raw)] — release headers "
                + "must strictly descend. An entry inserted at the wrong place reads as a "
                + "different release history than the one that happened (#396 round 3).")
        }

        // 2. non-increasing dates (an older release cannot post-date a newer one)
        for i in 0..<(entries.count - 1) {
            let a = entries[i], b = entries[i + 1]
            XCTAssertTrue(a.date >= b.date,
                "plugin/CHANGELOG.md: [\(a.raw)] is dated \(a.date) but the older [\(b.raw)] "
                + "is dated \(b.date) — dates must not increase going down the file.")
        }

        // 3. no skipped minor between the oldest and newest entry. The file
        //    claims completeness from its floor upward, so a hole is either a
        //    missing entry or an unpublished version that must be named here.
        let knownAbsentMinors: Set<Int> = []   // none as of 2.46.1; add with a reason
        let minors = Set(entries.map { $0.v[1] })
        let lo = entries.map { $0.v[1] }.min()!, hi = entries.map { $0.v[1] }.max()!
        for minor in lo...hi where !minors.contains(minor) && !knownAbsentMinors.contains(minor) {
            XCTFail("plugin/CHANGELOG.md skips 2.\(minor).x with no entry and no declared "
                + "absence — either backfill it (version/date/binary pin are recoverable from "
                + "the aggregator's plugin.json history) or add it to knownAbsentMinors with a "
                + "reason (#396 round 3).")
        }
    }

    func testBinaryPinNamesAShippedBinary() throws {
        // #396 verify: `binary_version` is the field that decides which binary
        // users actually download, and NOTHING owned it. This PR deletes the
        // surfaces that used to cross-check it by eye (README's "shell vX +
        // binary vY" pairs, and the description narrative), so without a
        // mechanical check the redundancy is removed and nothing replaces it.
        //
        // The repo has already paid for this once — plugin/CHANGELOG [2.44.1]
        // records v2.44.0 shipping an SOP documented against binary v2.26.0+
        // while plugin.json still pinned 2.25.0 and marketplace.json 2.24.0.
        // Users ran a binary without the fix; 24 self-sent messages were
        // mislabelled. The failure was silent.
        //
        // A pin can never legitimately name a binary that was never released,
        // so pin it to the ROOT changelog — the binary's own single source.
        let pjData = try Data(contentsOf: repoRoot().appendingPathComponent("plugin/.claude-plugin/plugin.json"))
        let pj = try XCTUnwrap(try JSONSerialization.jsonObject(with: pjData) as? [String: Any])
        let binaryPin = try XCTUnwrap(pj["binary_version"] as? String,
            "plugin.json must declare binary_version — the wrapper downloads whatever it names")

        let rootChangelog = try String(
            contentsOf: repoRoot().appendingPathComponent("CHANGELOG.md"), encoding: .utf8)
        let released = rootChangelog
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { line -> String? in
                guard line.hasPrefix("## ["), let close = line.firstIndex(of: "]") else { return nil }
                let v = String(line[line.index(line.startIndex, offsetBy: 4)..<close])
                return v == "Unreleased" ? nil : v
            }
        XCTAssertTrue(released.contains(binaryPin),
            "plugin.json pins binary_version '\(binaryPin)', which has no released section in the "
            + "root CHANGELOG.md — the wrapper would download a tag that was never shipped, or the "
            + "pin is a typo. Released binary versions: \(released.prefix(5).joined(separator: ", "))…")
    }
}

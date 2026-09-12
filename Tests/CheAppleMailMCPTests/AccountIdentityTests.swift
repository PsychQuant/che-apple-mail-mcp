import XCTest
import MCP
@testable import CheAppleMailMCP
@testable import MailSQLite

private func identitySnapshot(_ addresses: [String] = ["owner@example.test", "alias@example.test"], partial: Bool = false) throws -> AccountIdentitySnapshot {
    var records: [[String: Any]] = [["id": "ACCOUNT-A", "addresses": addresses, "available": true]]
    if partial { records.append(["id": "EWS-B", "addresses": [], "available": false]) }
    let data = try JSONSerialization.data(withJSONObject: ["version": 1, "count": records.count, "accounts": records])
    return try AccountIdentitySnapshot.parse(String(decoding: data, as: UTF8.self))
}

private final class IdentityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0
    func now() -> TimeInterval { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ delta: TimeInterval) { lock.lock(); value += delta; lock.unlock() }
}

private actor IdentityLoader {
    var calls = 0
    var snapshot: AccountIdentitySnapshot
    var fails = false
    var blocked = false
    var gate: CheckedContinuation<Void, Never>?
    init(_ snapshot: AccountIdentitySnapshot) { self.snapshot = snapshot }
    func configure(snapshot: AccountIdentitySnapshot? = nil, fails: Bool = false, blocked: Bool = false) {
        if let snapshot { self.snapshot = snapshot }
        self.fails = fails
        self.blocked = blocked
    }
    func load() async throws -> AccountIdentitySnapshot {
        calls += 1
        if blocked { await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if fails { throw NSError(domain: "identity-fixture", code: 1) }
        return snapshot
    }
    func release() { blocked = false; gate?.resume(); gate = nil }
}

final class AccountIdentityTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < end {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("fixture condition did not become true")
        throw NSError(domain: "identity-fixture-timeout", code: 1)
    }

    func testSnapshotIncludesEWSAndAliasesAndRejectsMalformedFraming() throws {
        let raw = #"{"version":1,"count":2,"accounts":[{"id":"EWS-A","addresses":["owner@exchange.example"],"available":true},{"id":"IMAP-B","addresses":["Primary <owner@example.test>","alias@example.test"],"available":true}]}"#
        let snapshot = try AccountIdentitySnapshot.parse(raw)
        XCTAssertTrue(snapshot.complete)
        XCTAssertEqual(snapshot.ownAddresses, ["owner@exchange.example", "owner@example.test", "alias@example.test"])
        XCTAssertNotNil(snapshot.addressesByID["ews-a"])
        for invalid in [raw.replacingOccurrences(of: "\"version\":1", with: "\"version\":2"),
                        raw.replacingOccurrences(of: "\"count\":2", with: "\"count\":3"),
                        raw.replacingOccurrences(of: "IMAP-B", with: "ews-a"),
                        raw.replacingOccurrences(of: "\"available\":true", with: "\"available\":\"true\""),
                        raw.replacingOccurrences(of: "\"available\":true", with: "\"available\":false")]
        { XCTAssertThrowsError(try AccountIdentitySnapshot.parse(invalid)) }
    }

    func testPartialSnapshotNeverClaimsCompleteNonMatchEvidence() throws {
        let snapshot = try identitySnapshot(["Owner <owner@example.test>", "not-an-address"], partial: true)
        XCTAssertFalse(snapshot.complete)
        XCTAssertEqual(snapshot.ownAddresses, ["owner@example.test"])
        let context = ExportAccountIdentity(lookup: AccountIdentityLookup(snapshot: snapshot, ageSeconds: 2, error: nil), sqliteAccounts: [])
        XCTAssertFalse(context.canClassifyNonMatch(accountID: "ACCOUNT-A"))
        XCTAssertFalse(context.canClassifyNonMatch(accountID: "EWS-B"))
        XCTAssertTrue(context.authoritativePositiveEvidence)
    }

    func testMalformedTailCannotMasqueradeAsACompleteAddressEntry() throws {
        for value in ["owner@example.test, invalid", "owner@example.test,",
                      "Owner <owner@example.test> trailing", "Owner <owner@example.test><other@example.test>",
                      "owner@example.test\u{001E}", "owner@example.test\u{2028}", "own(note)er@example.test"] {
            let snapshot = try identitySnapshot([value])
            XCTAssertFalse(snapshot.complete, value)
            XCTAssertTrue(snapshot.ownAddresses.isEmpty, value)
        }
    }

    func testConfiguredMailboxBoundaryKeepsLegitimateQuotedNamesAndComments() throws {
        for value in ["Owner <owner@example.test>", "\"Owner, Research\" <owner@example.test>",
                      "owner@example.test (comment <not-an-address>)", "owner@example.test"] {
            let snapshot = try identitySnapshot([value])
            XCTAssertTrue(snapshot.complete, value)
            XCTAssertEqual(snapshot.ownAddresses, ["owner@example.test"])
        }
    }

    func testConfiguredPrefixAndCommentBoundary() throws {
        let malformed = try identitySnapshot(["first@example.test <second@example.test>"])
        XCTAssertFalse(malformed.complete)
        XCTAssertTrue(malformed.ownAddresses.isEmpty)
        let quoted = try identitySnapshot(["\"first@example.test\" <second@example.test>"])
        XCTAssertTrue(quoted.complete)
        XCTAssertEqual(quoted.ownAddresses, ["second@example.test"])
        for value in ["owner@example.test (research < team)", "owner@example.test (6\" monitor)",
                      "owner@example.test (nested (research < team))", "owner@(note)example.test",
                      "owner(note)@example.test"] {
            let snapshot = try identitySnapshot([value])
            XCTAssertTrue(snapshot.complete, value)
            XCTAssertEqual(snapshot.ownAddresses, ["owner@example.test"])
        }
    }

    func testCacheTTLAndForceRefreshReplaceOldAddresses() async throws {
        let clock = IdentityClock(), loader = IdentityLoader(try identitySnapshot())
        let cache = AccountIdentityCache(clock: { clock.now() }, loader: { try await loader.load() })
        let initial = await cache.get()
        XCTAssertTrue(initial.snapshot?.ownAddresses.contains("alias@example.test") == true)
        await loader.configure(snapshot: try identitySnapshot(["new@example.test"]))
        clock.advance(299)
        let hit = await cache.get()
        XCTAssertEqual(hit.ageSeconds, 299)
        XCTAssertEqual(hit.snapshot, initial.snapshot)
        var calls = await loader.calls
        XCTAssertEqual(calls, 1)
        clock.advance(1)
        let expired = await cache.get()
        XCTAssertEqual(expired.snapshot?.ownAddresses, ["new@example.test"])
        await loader.configure(snapshot: try identitySnapshot(["forced@example.test"]))
        let forced = await cache.get(forceRefresh: true)
        XCTAssertEqual(forced.snapshot?.ownAddresses, ["forced@example.test"])
        calls = await loader.calls
        XCTAssertEqual(calls, 3)
    }

    func testFailureBackoffNeverRevivesExpiredSnapshotAndForceBypassesIt() async throws {
        let clock = IdentityClock(), loader = IdentityLoader(try identitySnapshot())
        let cache = AccountIdentityCache(clock: { clock.now() }, loader: { try await loader.load() })
        _ = await cache.get()
        clock.advance(300)
        await loader.configure(fails: true)
        let failed = await cache.get()
        XCTAssertNil(failed.snapshot)
        clock.advance(59)
        let backoff = await cache.get()
        XCTAssertNil(backoff.snapshot)
        var calls = await loader.calls
        XCTAssertEqual(calls, 2)
        await loader.configure()
        let forced = await cache.get(forceRefresh: true)
        XCTAssertNotNil(forced.snapshot)
        calls = await loader.calls
        XCTAssertEqual(calls, 3)
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        let loader = IdentityLoader(try identitySnapshot())
        await loader.configure(blocked: true)
        let cache = AccountIdentityCache(loader: { try await loader.load() })
        let tasks = (0..<16).map { _ in Task { await cache.get() } }
        try await eventually { await loader.calls == 1 }
        await loader.release()
        for task in tasks { let result = await task.value; XCTAssertNotNil(result.snapshot) }
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
    }

    func testWaitTimeoutKeepsFlightAndLateSuccessPopulatesCache() async throws {
        let loader = IdentityLoader(try identitySnapshot())
        await loader.configure(blocked: true)
        let cache = AccountIdentityCache(waitTimeout: 0.02, loader: { try await loader.load() })
        let first = await cache.get()
        XCTAssertNil(first.snapshot)
        let start = ProcessInfo.processInfo.systemUptime
        let second = await cache.get(forceRefresh: true)
        XCTAssertNil(second.snapshot)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 0.1)
        var calls = await loader.calls
        XCTAssertEqual(calls, 1)
        await loader.release()
        try await eventually { await cache.get().snapshot != nil }
        calls = await loader.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancellationDoesNotCancelSharedRefresh() async throws {
        let loader = IdentityLoader(try identitySnapshot())
        await loader.configure(blocked: true)
        let cache = AccountIdentityCache(loader: { try await loader.load() })
        let cancelled = Task { await cache.get() }
        let other = Task { await cache.get() }
        try await eventually { await loader.calls == 1 }
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertNil(result.snapshot)
        XCTAssertTrue(result.error?.contains("cancelled") == true)
        await loader.release()
        let survivor = await other.value
        XCTAssertNotNil(survivor.snapshot)
        let calls = await loader.calls
        XCTAssertEqual(calls, 1)
    }

    func testForcedRefreshInvalidatesFreshViewForConcurrentCallers() async throws {
        let loader = IdentityLoader(try identitySnapshot())
        let cache = AccountIdentityCache(waitTimeout: 0.02, loader: { try await loader.load() })
        _ = await cache.get()
        await loader.configure(snapshot: try identitySnapshot(["new@example.test"]), blocked: true)
        let forced = Task { await cache.get(forceRefresh: true) }
        try await eventually { await loader.calls == 2 }
        // The native refresh is still blocked: returning the old fresh snapshot
        // would be a false success after explicit invalidation.
        let follower = await cache.get()
        XCTAssertNil(follower.snapshot)
        let otherForce = await cache.get(forceRefresh: true)
        XCTAssertNil(otherForce.snapshot)
        let firstResult = await forced.value
        XCTAssertNil(firstResult.snapshot)
        var calls = await loader.calls
        XCTAssertEqual(calls, 2)
        await loader.release()
        try await eventually { await cache.get().snapshot?.ownAddresses == ["new@example.test"] }
        calls = await loader.calls
        XCTAssertEqual(calls, 2)
    }

    func testFailureBackoffExpiresWithoutForce() async throws {
        let clock = IdentityClock(), loader = IdentityLoader(try identitySnapshot())
        await loader.configure(fails: true)
        let cache = AccountIdentityCache(clock: { clock.now() }, loader: { try await loader.load() })
        _ = await cache.get()
        clock.advance(59)
        _ = await cache.get()
        var calls = await loader.calls
        XCTAssertEqual(calls, 1)
        await loader.configure()
        clock.advance(1)
        let result = await cache.get()
        XCTAssertNotNil(result.snapshot)
        calls = await loader.calls
        XCTAssertEqual(calls, 2)
    }

    func testAlreadyCancelledCallerDoesNotStartRefresh() async throws {
        let loader = IdentityLoader(try identitySnapshot())
        let cache = AccountIdentityCache(loader: { try await loader.load() })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await cache.get()
        }
        let result = await task.value
        XCTAssertNil(result.snapshot)
        let calls = await loader.calls
        XCTAssertEqual(calls, 0)
    }

    func testRefreshOptionOnlyAcceptsBoolean() throws {
        XCTAssertFalse(try parseRefreshIdentityOption(nil))
        XCTAssertTrue(try parseRefreshIdentityOption(.bool(true)))
        for value: Value in [.null, .string("true"), .int(1), .object([:]), .array([])] {
            XCTAssertThrowsError(try parseRefreshIdentityOption(value))
        }
    }

    func testActualControllerSnapshotMethodParsesOneScriptResult() async throws {
        let raw = #"{"version":1,"count":1,"accounts":[{"id":"EWS-A","addresses":["owner@exchange.example","alias@exchange.example"],"available":true}]}"#
        var scripts: [String] = []
        await MailController.shared.setTestSeams(scriptRunner: { scripts.append($0); return raw }, refusal: { nil })
        do {
            let snapshot = try await MailController.shared.configuredAccountIdentities()
            XCTAssertTrue(snapshot.complete)
            XCTAssertEqual(snapshot.ownAddresses.count, 2)
            XCTAssertEqual(scripts.count, 1)
            XCTAssertTrue(scripts[0].contains("NSJSONSerialization"))
            XCTAssertFalse(scripts[0].contains("messages of"))
        } catch {
            await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
            throw error
        }
        await MailController.shared.setTestSeams(scriptRunner: nil, refusal: nil)
    }
}

final class CachedIdentityExportTests: XCTestCase {
    private func export(sender: String, lookup: AccountIdentityLookup, accountID: String = "account-a") throws -> (ExportManifestItem, ExportManifest, String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("identity375-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = ExportAccountIdentity(lookup: lookup, sqliteAccounts: [["uuid": "account-a", "email_addresses": ["primary@example.test"]]])
        var manifest = try ExportEmailsMarkdown.run(
            ids: ["1"], outputDir: root, ownAddresses: context.ownAddresses, fallbackDirection: "received",
            includeAttachments: false, filenameTemplate: nil, filenameOverrides: [:], extraFrontmatter: [],
            identityResolvable: { _ in context.canClassifyNonMatch(accountID: accountID) },
            authoritativeIdentityEvidence: context.authoritativePositiveEvidence,
            fetch: { _ in EmailContent(subject: "fixture", sender: sender, toRecipients: [], ccRecipients: [],
                date: "Tue, 30 Jun 2026 12:00:00 +0000", messageId: "<fixture@example.test>", inReplyTo: "",
                textBody: "body", htmlBody: nil, rawSource: nil) },
            attachmentNamesFor: { _ in [] }, attachmentData: { _, _ in Data() })
        context.annotate(&manifest)
        let item = try XCTUnwrap(manifest.items.first)
        let text = try String(contentsOfFile: XCTUnwrap(item.writtenPath))
        let direction = text.split(separator: "\n").first { $0.hasPrefix("direction:") }
            .map { String($0.dropFirst("direction:".count)).trimmingCharacters(in: .whitespaces) } ?? ""
        return (item, manifest, direction)
    }

    func testEWSAndAliasAreConfidentSentAndExternalIsReceived() throws {
        let snapshot = try identitySnapshot(["owner@exchange.example", "alias@example.test"])
        let lookup = AccountIdentityLookup(snapshot: snapshot, ageSeconds: 12, error: nil)
        for sender in ["owner@exchange.example", "alias@example.test"] {
            let (item, manifest, direction) = try export(sender: sender, lookup: lookup)
            XCTAssertEqual(direction, "sent")
            XCTAssertNil(item.directionInferred)
            XCTAssertEqual(manifest.jsonObject["identity_source"] as? String, "mail_account_cache")
            XCTAssertEqual(manifest.jsonObject["identity_complete"] as? Bool, true)
            XCTAssertEqual(manifest.jsonObject["identity_cache_age_seconds"] as? Int, 12)
        }
        let (external, _, direction) = try export(sender: "external@example.test", lookup: lookup)
        XCTAssertEqual(direction, "received")
        XCTAssertNil(external.directionInferred)
    }

    func testPartialAndFallbackNonMatchesAreDisclosed() throws {
        let partial = AccountIdentityLookup(snapshot: try identitySnapshot(partial: true), ageSeconds: 0, error: nil)
        let (item, manifest, direction) = try export(sender: "external@example.test", lookup: partial)
        XCTAssertEqual(direction, "received")
        XCTAssertEqual(item.directionInferred, true)
        XCTAssertEqual(manifest.identityComplete, false)
        let (known, _, knownDirection) = try export(sender: "alias@example.test", lookup: partial)
        XCTAssertEqual(knownDirection, "sent")
        XCTAssertNil(known.directionInferred)
        for sender in ["primary@example.test", "alias@example.test", "external@example.test"] {
            let (fallback, report, direction) = try export(sender: sender, lookup: .unavailable("fixture"))
            XCTAssertEqual(direction, sender == "primary@example.test" ? "sent" : "received")
            XCTAssertEqual(fallback.directionInferred, true)
            XCTAssertEqual(report.identitySource, "sqlite_primary_fallback")
            XCTAssertNil(report.identityCacheAgeSeconds)
        }
    }

    func testUnrepresentedAccountCannotMakeConfidentNonMatch() throws {
        let lookup = AccountIdentityLookup(snapshot: try identitySnapshot(), ageSeconds: 0, error: nil)
        let (item, _, direction) = try export(sender: "external@example.test", lookup: lookup, accountID: "unknown")
        XCTAssertEqual(direction, "received")
        XCTAssertEqual(item.directionInferred, true)
    }
}

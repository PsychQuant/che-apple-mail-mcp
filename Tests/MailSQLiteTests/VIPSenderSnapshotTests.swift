import Darwin
import XCTest
@testable import MailSQLite

final class VIPSenderSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func plist(_ value: Any, format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: format, options: 0)
    }
    private func file() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("VIPMailboxes.plist")
    }

    func test_supported_records_use_same_canonical_parser_on_both_sides() throws {
        let entries = [["Name": "Fixture", "Addresses": ["  NEWS@Example.Invalid  ", "Other <other@example.invalid>"]]] as [[String: Any]]
        let roots: [Any] = [entries, ["Senders": entries], ["Senders": ["fixture-id": entries[0]]]]
        for root in roots {
            for format: PropertyListSerialization.PropertyListFormat in [.xml, .binary] {
                let snapshot = VIPSenderSnapshot.parse(try plist(root, format: format), observedAt: now)
                for from in ["news@example.invalid", "News <NEWS@EXAMPLE.INVALID>", "\"News, Team\" <news@example.invalid> (comment)"] {
                    XCTAssertEqual(snapshot.status(for: from, at: now), true, from)
                }
                XCTAssertEqual(snapshot.status(for: "other@example.invalid", at: now), true)
                XCTAssertEqual(snapshot.status(for: "unlisted@example.invalid", at: now), false)
                XCTAssertEqual(snapshot.status(for: "news+alias@example.invalid", at: now), false)
                XCTAssertEqual(snapshot.status(for: "news@example.invalid.evil", at: now), false)
            }
        }
    }

    func test_ambiguous_sender_never_proves_non_vip() throws {
        let snapshot = VIPSenderSnapshot.parse(try plist([["Addresses": ["vip@example.invalid"]]]), observedAt: now)
        for from in ["", "not an address", "vip@example.invalid, other@example.invalid", "vip@example.invalid <attacker@example.invalid>", "Name <a@example.invalid> trailing", "a@example.invalid\nBcc: victim@example.invalid"] {
            XCTAssertNil(snapshot.status(for: from, at: now), from)
        }
    }

    func test_equivalent_quoted_local_parts_and_unsupported_addresses_never_prove_absence() throws {
        let bare = VIPSenderSnapshot.parse(try plist([["Addresses": ["news@example.invalid"]]]), observedAt: now)
        for address in ["\"news\"@example.invalid", "\"n\\ews\"@example.invalid", "news@example.invalid.",
                        "news@[127.0.0.1]", "news@例子.invalid", "news..team@example.invalid"] {
            XCTAssertNil(bare.status(for: address, at: now), address)
            let unsupported = VIPSenderSnapshot.parse(try plist([["Addresses": [address]]]), observedAt: now)
            XCTAssertNil(unsupported.status(for: "news@example.invalid", at: now), address)
        }
    }

    func test_expiry_and_clock_rollback_cannot_reuse_negative_lookup() throws {
        let snapshot = VIPSenderSnapshot.parse(try plist([]), observedAt: now)
        XCTAssertEqual(snapshot.status(for: "a@example.invalid", at: now.addingTimeInterval(59)), false)
        XCTAssertNil(snapshot.status(for: "a@example.invalid", at: now.addingTimeInterval(60)))
        XCTAssertNil(snapshot.status(for: "a@example.invalid", at: now.addingTimeInterval(-1)))
        XCTAssertNil(VIPSenderSnapshot.unavailable.status(for: "a@example.invalid", at: now))
    }

    func test_malformed_or_partial_list_is_unknown_not_empty() throws {
        let roots: [Any] = [[:], ["Unknown": []], [["Name": "missing addresses"]],
            [["Addresses": "a@example.invalid"]], [["Addresses": []]],
            [["Addresses": ["a@example.invalid", "broken"]]],
            [["Addresses": ["a@example.invalid"]], ["Name": "partial"]],
            ["Senders": ["bad": "a@example.invalid"]]]
        for root in roots {
            let snapshot = VIPSenderSnapshot.parse(try plist(root), observedAt: now)
            XCTAssertNil(snapshot.status(for: "unlisted@example.invalid", at: now), "\(root)")
        }
        XCTAssertNil(VIPSenderSnapshot.parse(Data("not a plist".utf8), observedAt: now).status(for: "a@example.invalid", at: now))
    }

    func test_reader_rereads_changes_and_does_not_reuse_last_success_on_failure() throws {
        let url = try file()
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
        try plist([["Addresses": ["A@EXAMPLE.INVALID"]]]).write(to: url)
        // An old mtime does not invalidate a freshly observed positive match.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: url.path)
        XCTAssertEqual(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now), true)
        try plist([]).write(to: url, options: .atomic)
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
        try plist([["Addresses": ["A@EXAMPLE.INVALID"]]]).write(to: url, options: .atomic)
        XCTAssertEqual(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now), true)
        try Data("corrupt".utf8).write(to: url)
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
    }

    func test_unverified_mail_source_never_proves_non_vip_even_for_valid_empty_list() throws {
        let url = try file()
        for records: [[String: Any]] in [[], [["Addresses": ["vip@example.invalid"]]]] {
            try plist(records).write(to: url, options: .atomic)
            let observed = VIPSenderSnapshot.read(from: url, observedAt: now)
            XCTAssertNil(observed.status(for: "unlisted@example.invalid", at: now),
                "The repository has no native evidence that this Mail file is a complete sender source")
        }
        XCTAssertEqual(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "vip@example.invalid", at: now), true)
    }

    func test_nonregular_symlink_and_oversize_sources_are_unknown() throws {
        let url = try file()
        XCTAssertNil(VIPSenderSnapshot.read(from: url.deletingLastPathComponent(), observedAt: now).status(for: "a@example.invalid", at: now))
        let target = url.deletingLastPathComponent().appendingPathComponent("target.plist")
        try plist([]).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
        try FileManager.default.removeItem(at: url)
        XCTAssertEqual(mkfifo(url.path, 0o600), 0)
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 0, count: 1_048_577).write(to: url)
        XCTAssertNil(VIPSenderSnapshot.read(from: url, observedAt: now).status(for: "a@example.invalid", at: now))
    }
}

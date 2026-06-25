import XCTest
import Foundation
@testable import CheAppleMailMCP
import MailSQLite

/// #194: the `search_emails` AppleScript fallback must honor the same
/// `field` / `date_from` / `date_to` filters the SQLite primary path honors.
/// These structural tests pin the pure builder fragments (no live Mail).
final class SearchEmailsScriptBuilderTests: XCTestCase {

    // MARK: - Field predicate (the `whose` substring fast-path)

    /// Regression pin: the `any` predicate must stay **byte-identical** to the
    /// pre-refactor hardcoded `subject contains … or sender contains …`, proving
    /// the refactor preserved the fast-path behavior for the default field.
    func testAnyFieldPredicate_byteCompatibleWithLegacy() {
        XCTAssertEqual(
            searchEmailsFieldPredicate(field: .any, escapedQuery: "Q"),
            "subject contains \"Q\" or sender contains \"Q\"")
    }

    func testSubjectFieldPredicate_subjectOnly() {
        let p = searchEmailsFieldPredicate(field: .subject, escapedQuery: "Q")
        XCTAssertEqual(p, "subject contains \"Q\"")
        XCTAssertFalse(p?.contains("sender") ?? false)
    }

    func testSenderFieldPredicate_senderOnly() {
        let p = searchEmailsFieldPredicate(field: .sender, escapedQuery: "Q")
        XCTAssertEqual(p, "sender contains \"Q\"")
        XCTAssertFalse(p?.contains("subject") ?? false)
    }

    /// recipient has no reliable `whose` form → builder signals "filter in-loop"
    /// by returning nil.
    func testRecipientFieldPredicate_isNil() {
        XCTAssertNil(searchEmailsFieldPredicate(field: .recipient, escapedQuery: "Q"))
    }

    func testFieldPredicate_interpolatesEscapedQueryVerbatim() {
        // Builder receives an ALREADY-escaped query; it must not re-escape/mangle.
        let escaped = appleScriptEscape("a\"b")   // -> a\"b
        let p = searchEmailsFieldPredicate(field: .subject, escapedQuery: escaped)
        XCTAssertEqual(p, "subject contains \"\(escaped)\"")
    }

    // MARK: - Recipient in-loop match block

    func testRecipientMatchBlock_scansToAndCcAddressAndName() {
        let block = searchEmailsRecipientMatchBlock(escapedQuery: "Q")
        XCTAssertTrue(block.contains("to recipients of msg"))
        XCTAssertTrue(block.contains("cc recipients of msg"))
        XCTAssertTrue(block.contains("address of"))
        XCTAssertTrue(block.contains("name of"))
        XCTAssertTrue(block.contains("\"Q\""))
        XCTAssertTrue(block.contains("_matched"))
    }

    // MARK: - Date clause (locale-independent)

    func testDateClause_bothNil_isEmpty() {
        let c = searchEmailsDateClause(dateFrom: nil, dateTo: nil)
        XCTAssertEqual(c.setup, "")
        XCTAssertEqual(c.predicate, "")
    }

    func testDateClause_fromOnly_lowerBoundOnly() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let c = searchEmailsDateClause(dateFrom: from, dateTo: nil)
        XCTAssertTrue(c.setup.contains("_qFrom"))
        XCTAssertTrue(c.setup.contains("year of"))
        XCTAssertTrue(c.setup.contains("month of"))
        XCTAssertTrue(c.setup.contains("day of"))
        XCTAssertTrue(c.predicate.contains("date received ≥ _qFrom"))
        XCTAssertFalse(c.predicate.contains("_qTo"))
        XCTAssertFalse(c.predicate.contains("≤"))
    }

    func testDateClause_fromAndTo_bothBounds() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_701_000_000)
        let c = searchEmailsDateClause(dateFrom: from, dateTo: to)
        XCTAssertTrue(c.predicate.contains("date received ≥ _qFrom"))
        XCTAssertTrue(c.predicate.contains("date received ≤ _qTo"))
        XCTAssertTrue(c.setup.contains("_qFrom"))
        XCTAssertTrue(c.setup.contains("_qTo"))
    }

    /// A locale-dependent `date "1/1/2026"` literal is parsed in the user's
    /// region/locale → wrong instant. Construction must use component setters.
    func testDateClause_noLocaleDependentDateLiteral() {
        let from = Date(timeIntervalSince1970: 1_700_000_000)
        let to = Date(timeIntervalSince1970: 1_701_000_000)
        let c = searchEmailsDateClause(dateFrom: from, dateTo: to)
        XCTAssertFalse(c.setup.contains("date \""))
    }

    // MARK: - whose-suffix assembly

    func testWhoseSuffix_anyFieldNoDate() {
        XCTAssertEqual(
            searchEmailsWhoseSuffix(field: .any, escapedQuery: "Q", datePredicate: ""),
            " whose subject contains \"Q\" or sender contains \"Q\"")
    }

    func testWhoseSuffix_recipientNoDate_empty() {
        // recipient + no date → no `whose` at all (enumerate, filter in-loop).
        XCTAssertEqual(
            searchEmailsWhoseSuffix(field: .recipient, escapedQuery: "Q", datePredicate: ""),
            "")
    }

    func testWhoseSuffix_recipientWithDate_dateOnly() {
        XCTAssertEqual(
            searchEmailsWhoseSuffix(field: .recipient, escapedQuery: "Q",
                                    datePredicate: "date received ≥ _qFrom"),
            " whose date received ≥ _qFrom")
    }

    func testWhoseSuffix_fieldAndDate_combined() {
        XCTAssertEqual(
            searchEmailsWhoseSuffix(field: .subject, escapedQuery: "Q",
                                    datePredicate: "date received ≤ _qTo"),
            " whose subject contains \"Q\" and date received ≤ _qTo")
    }

    // MARK: - #221 guard: never emit a full-corpus content scan

    func testNoWhoseContentContainsAnywhere() {
        let outputs: [String] = [
            searchEmailsFieldPredicate(field: .any, escapedQuery: "Q") ?? "",
            searchEmailsFieldPredicate(field: .subject, escapedQuery: "Q") ?? "",
            searchEmailsFieldPredicate(field: .sender, escapedQuery: "Q") ?? "",
            searchEmailsRecipientMatchBlock(escapedQuery: "Q"),
            searchEmailsWhoseSuffix(field: .any, escapedQuery: "Q", datePredicate: ""),
            searchEmailsWhoseSuffix(field: .recipient, escapedQuery: "Q",
                                    datePredicate: "date received ≥ _qFrom"),
        ]
        for out in outputs {
            XCTAssertFalse(out.contains("content contains"),
                           "fallback must never emit a `content contains` full-corpus scan (#221)")
        }
    }
}

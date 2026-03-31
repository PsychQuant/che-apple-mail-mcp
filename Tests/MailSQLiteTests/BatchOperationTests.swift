import XCTest
@testable import MailSQLite

final class BatchOperationTests: XCTestCase {

    func testBatchSizeWithinLimit() throws {
        XCTAssertNoThrow(try BatchValidator.validateBatchSize(30))
    }

    func testBatchSizeAtExactLimit() throws {
        XCTAssertNoThrow(try BatchValidator.validateBatchSize(50))
    }

    func testBatchSizeExceedsLimit() throws {
        XCTAssertThrowsError(try BatchValidator.validateBatchSize(51)) { error in
            guard let mailError = error as? MailSQLiteError else {
                XCTFail("Expected MailSQLiteError, got \(type(of: error))")
                return
            }
            if case .batchSizeExceeded(let limit) = mailError {
                XCTAssertEqual(limit, 50)
            } else {
                XCTFail("Expected .batchSizeExceeded(limit: 50), got \(mailError)")
            }
        }
    }

    func testBatchSizeZero() throws {
        XCTAssertNoThrow(try BatchValidator.validateBatchSize(0))
    }
}

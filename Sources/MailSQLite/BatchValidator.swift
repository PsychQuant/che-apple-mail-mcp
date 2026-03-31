/// Validates batch operation constraints.
public enum BatchValidator {
    public static let maxBatchSize = 50

    public static func validateBatchSize(_ count: Int) throws {
        guard count <= maxBatchSize else {
            throw MailSQLiteError.batchSizeExceeded(limit: maxBatchSize)
        }
    }
}

import Foundation

/// #465 — gives accounts per-response codes (`A`, `B`, …) so the brief output
/// can still say "these two events are the same account" after the `%@` that
/// carries the account name has been dropped.
///
/// Parsing a private message prefix: `[<account> - <mailbox>] …`, where the
/// ` - <mailbox>` part is not always there (`[iCloud] …`). If it does not
/// parse, the answer is `nil`, never an error. The key is used only to decide
/// "same or different"; it is never returned.
struct AccountAliaser {
    private var aliases: [String: String] = [:]

    /// Distinct accounts seen so far in this response.
    var count: Int { aliases.count }

    mutating func alias(forMessage message: String) -> String? {
        guard message.hasPrefix("["), let close = message.firstIndex(of: "]") else { return nil }
        let inner = message[message.index(after: message.startIndex)..<close]
        // Only the `[account - mailbox]` form carries an account. A bare label (`[Fixture.Server]`,
        // `[iCloud]`) is a connection or server name: aliasing it made one account look like two
        // across categories and inflated `accounts_seen` (verify round 1, finding #13).
        guard let dash = inner.range(of: " - ") else { return nil }
        let key = inner[inner.startIndex..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        if let existing = aliases[key] { return existing }
        let alias = Self.letters(forIndex: aliases.count)
        aliases[key] = alias
        return alias
    }

    /// 0 → A … 25 → Z, 26 → AA, 27 → AB … (spreadsheet-column style).
    private static func letters(forIndex index: Int) -> String {
        var n = index + 1
        var result = ""
        while n > 0 {
            n -= 1
            result = String(UnicodeScalar(UInt8(65 + n % 26))) + result
            n /= 26
        }
        return result
    }
}

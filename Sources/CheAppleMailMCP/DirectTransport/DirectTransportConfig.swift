import Foundation

/// The accounts that may use direct transport (#742), read from
/// `direct-transport.json` in the server's state directory.
///
/// The file holds an object with one key, `accounts`, whose value is a list of
/// entries with exactly these keys: `account_id`, `address`, `smtp`, `imap`,
/// `sent_copy`, `allowed_from`. It never holds a password: that lives in the
/// keychain (`DirectTransportCredential`). A file that exists and cannot be
/// used is an error, never "not configured", so a typo cannot quietly turn the
/// feature off or on.
struct DirectTransportConfig: Equatable {
    struct Endpoint: Equatable {
        let host: String
        let port: Int
    }

    /// Whether the tool stores the sent copy itself (`append`) or the provider
    /// does (`provider`). No default: the file has to say.
    enum SentCopy: String, Equatable {
        case append
        case provider
    }

    struct Account: Equatable {
        let accountID: String
        let address: String
        let smtp: Endpoint
        let imap: Endpoint
        let sentCopy: SentCopy
        let allowedFrom: [String]

        /// Whether `address` may appear in the From field of a draft this account sends.
        func mayUseFrom(_ candidate: String) -> Bool {
            let wanted = candidate.lowercased()
            return ([address] + allowedFrom).contains { $0.lowercased() == wanted }
        }
    }

    static let fileName = "direct-transport.json"

    let accounts: [Account]

    /// The configured account a call names. A non-empty `accountID` chooses it
    /// by itself (ASCII case is ignored), and the name is not consulted; without
    /// one, `accountName` is compared with each account's `address`.
    func account(accountID: String?, accountName: String?) -> Account? {
        if let id = accountID, !id.isEmpty {
            return accounts.first { $0.accountID.lowercased() == id.lowercased() }
        }
        guard let name = accountName, !name.isEmpty else { return nil }
        return accounts.first { $0.address.lowercased() == name.lowercased() }
    }

    struct Problem: Error, CustomStringConvertible {
        let detail: String
        var description: String { "\(DirectTransportConfig.fileName): \(detail)" }
    }

    /// Reads the file. `nil` when it does not exist; throws `Problem` when it
    /// exists and cannot be used.
    static func load(from url: URL) throws -> DirectTransportConfig? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            throw Problem(detail: "cannot be read (\(error.localizedDescription))")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw Problem(detail: "is not valid JSON")
        }
        guard let top = object as? [String: Any] else { throw Problem(detail: "must hold an object") }
        try onlyKeys(top, ["accounts"], in: "the top level")
        guard let list = top["accounts"] as? [Any] else { throw Problem(detail: "`accounts` must be a list") }
        var accounts: [Account] = []
        for (index, item) in list.enumerated() {
            let account = try parseAccount(item, at: index)
            if accounts.contains(where: { $0.accountID.lowercased() == account.accountID.lowercased() }) {
                throw Problem(detail: "account \(account.accountID) appears more than once")
            }
            accounts.append(account)
        }
        return DirectTransportConfig(accounts: accounts)
    }

    private static let accountKeys: Set<String> = ["account_id", "address", "smtp", "imap", "sent_copy", "allowed_from"]

    private static func parseAccount(_ item: Any, at index: Int) throws -> Account {
        let place = "accounts[\(index)]"
        guard let entry = item as? [String: Any] else { throw Problem(detail: "\(place) must be an object") }
        try onlyKeys(entry, accountKeys, in: place)
        for key in accountKeys where entry[key] == nil { throw Problem(detail: "\(place) lacks `\(key)`") }
        let accountID = try nonEmptyString(entry["account_id"], "\(place).account_id")
        let address = try nonEmptyString(entry["address"], "\(place).address")
        guard isAddress(address) else { throw Problem(detail: "\(place).address is not an email address") }
        guard let sentCopyText = entry["sent_copy"] as? String, let sentCopy = SentCopy(rawValue: sentCopyText) else {
            throw Problem(detail: "\(place).sent_copy must be \"append\" or \"provider\"")
        }
        guard let fromList = entry["allowed_from"] as? [Any] else {
            throw Problem(detail: "\(place).allowed_from must be a list")
        }
        let allowedFrom = try fromList.enumerated().map { offset, value -> String in
            guard let text = value as? String, isAddress(text) else {
                throw Problem(detail: "\(place).allowed_from[\(offset)] must be an email address")
            }
            return text
        }
        return Account(accountID: accountID, address: address,
                       smtp: try endpoint(entry["smtp"], "\(place).smtp"),
                       imap: try endpoint(entry["imap"], "\(place).imap"),
                       sentCopy: sentCopy, allowedFrom: allowedFrom)
    }

    private static func endpoint(_ value: Any?, _ place: String) throws -> Endpoint {
        guard let object = value as? [String: Any] else { throw Problem(detail: "\(place) must be an object") }
        try onlyKeys(object, ["host", "port"], in: place)
        let host = try nonEmptyString(object["host"], "\(place).host")
        // JSONSerialization reads 587 as an NSNumber; a string or a fraction is refused.
        guard let number = object["port"] as? NSNumber, CFGetTypeID(number) == CFNumberGetTypeID(),
              !CFNumberIsFloatType(number), (1...65535).contains(number.intValue) else {
            throw Problem(detail: "\(place).port must be a whole number from 1 to 65535")
        }
        return Endpoint(host: host, port: number.intValue)
    }

    private static func nonEmptyString(_ value: Any?, _ place: String) throws -> String {
        guard let text = value as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Problem(detail: "\(place) must be a non-empty string")
        }
        return text
    }

    private static func onlyKeys(_ object: [String: Any], _ allowed: Set<String>, in place: String) throws {
        if let extra = object.keys.sorted().first(where: { !allowed.contains($0) }) {
            throw Problem(detail: "\(place) has a key this version does not read: `\(extra)`")
        }
    }

    /// One `@` with something on each side and no white space: enough to catch a
    /// mistyped entry. The server checks the address itself.
    private static func isAddress(_ text: String) -> Bool {
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        return parts.count == 2 && !parts[0].isEmpty && !parts[1].isEmpty
            && !text.contains(where: { $0.isWhitespace })
    }
}

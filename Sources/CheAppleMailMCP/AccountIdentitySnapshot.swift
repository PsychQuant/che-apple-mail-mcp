import Foundation
import MailSQLite

struct AccountIdentitySnapshot: Sendable, Equatable {
    let addressesByID: [String: Set<String>]
    let complete: Bool
    var ownAddresses: Set<String> { addressesByID.values.reduce(into: []) { $0.formUnion($1) } }

    private struct Envelope: Decodable {
        let version: Int
        let count: Int
        let accounts: [Record]
    }
    private struct Record: Decodable {
        let id: String
        let addresses: [String]
        let available: Bool
    }
    enum Invalid: Error { case snapshot }

    static func parse(_ raw: String) throws -> Self {
        let value = try JSONDecoder().decode(Envelope.self, from: Data(raw.utf8))
        guard value.version == 1, value.count == value.accounts.count else { throw Invalid.snapshot }
        var accounts: [String: Set<String>] = [:]
        var complete = !value.accounts.isEmpty
        for record in value.accounts {
            let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.isEmpty, !id.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
                  accounts[id] == nil, record.available || record.addresses.isEmpty else { throw Invalid.snapshot }
            var addresses: Set<String> = []
            var recordComplete = record.available && !record.addresses.isEmpty
            for rawAddress in record.addresses {
                guard let parsed = EmailAddress.singleCanonical(rawAddress) else { recordComplete = false; continue }
                addresses.insert(parsed)
            }
            accounts[id] = addresses
            complete = complete && recordComplete && !addresses.isEmpty
        }
        return Self(addressesByID: accounts, complete: complete)
    }
}

struct AccountIdentityLookup: Sendable {
    let snapshot: AccountIdentitySnapshot?
    let ageSeconds: Int?
    let error: String?

    static func unavailable(_ error: String) -> Self {
        Self(snapshot: nil, ageSeconds: nil, error: error)
    }
}

struct ExportAccountIdentity {
    let ownAddresses: Set<String>
    let accountIDs: Set<String>
    let complete: Bool
    let authoritativePositiveEvidence: Bool
    let source: String
    let ageSeconds: Int?

    init(lookup: AccountIdentityLookup, sqliteAccounts: [[String: Any]]) {
        if let snapshot = lookup.snapshot {
            ownAddresses = snapshot.ownAddresses
            accountIDs = Set(snapshot.addressesByID.keys)
            complete = snapshot.complete
            authoritativePositiveEvidence = true
            source = "mail_account_cache"
            ageSeconds = lookup.ageSeconds
        } else {
            ownAddresses = ExportIdentity.ownAddresses(from: sqliteAccounts)
            accountIDs = []
            complete = false
            authoritativePositiveEvidence = false
            source = "sqlite_primary_fallback"
            ageSeconds = nil
        }
    }

    func canClassifyNonMatch(accountID: String) -> Bool {
        complete && accountIDs.contains(accountID.lowercased())
    }

    func annotate(_ manifest: inout ExportManifest) {
        manifest.identitySource = source
        manifest.identityComplete = complete
        manifest.identityCacheAgeSeconds = ageSeconds
    }
}

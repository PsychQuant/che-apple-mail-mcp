import Foundation

/// Which mailbox is the drafts mailbox, or the sent mailbox (#748).
///
/// The decision table is closed. Rows are tried in this order and the first
/// that applies decides:
///
/// 1. The plain mailbox list marks exactly one mailbox with the attribute: that one.
/// 2. The plain list marks more than one: refused.
/// 3. The plain list marks none and the server advertises SPECIAL-USE: the
///    server is asked for its special-use mailboxes. Exactly one marked: that
///    one. More than one: refused. None: continue.
/// 4. `direct-transport.json` names a mailbox for the account: it is used when
///    the server lists exactly one mailbox whose name is that name scalar by
///    scalar and that mailbox can be selected; refused otherwise.
/// 5. Otherwise: refused, saying what was seen.
///
/// The capabilities are asked for only when rules 1 and 2 did not decide, so a
/// failure to fetch them cannot override a mark the server already gave.
///
/// A mailbox is never chosen by what it is called on the server: the name in
/// row 4 is the maintainer's statement, not a guess. A server that does not
/// advertise SPECIAL-USE is not asked (row 3), because SwiftMail's special-use
/// listing then guesses from mailbox names.
///
/// No text built here holds a mailbox name or the server's capability string:
/// only counts and yes or no.
enum MailboxLookup {
    enum Role: Sendable {
        case drafts, sent

        var attribute: String { self == .drafts ? "\\Drafts" : "\\Sent" }
        var configurationKey: String { self == .drafts ? "drafts_mailbox" : "sent_mailbox" }
        var noun: String { self == .drafts ? "drafts mailbox" : "sent mailbox" }
        /// What a refusal means for the call.
        var consequence: String { self == .drafts ? "nothing was submitted" : "the sent copy was not stored" }
    }

    enum Source: Equatable, Sendable {
        case plainList, explicitRequest, configuration
    }

    /// A mailbox as the plain list gave it.
    struct Listed: Equatable, Sendable {
        let name: String
        /// False when the server marks it `\\Noselect` (a hierarchy placeholder).
        let selectable: Bool
    }

    /// Names compared scalar by scalar, not by Unicode canonical equivalence
    /// (Swift's `==`): IMAP mailbox names are opaque to the server.
    static func sameName(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    struct Found: Equatable, Sendable {
        let name: String
        let source: Source
        /// One sentence for the result's notes: where the mailbox came from.
        let note: String
    }

    /// - Parameters:
    ///   - listed: every mailbox the plain list returned.
    ///   - markedInList: the names the plain list marked with the role's attribute.
    ///   - declared: the name `direct-transport.json` gives for the role, if any.
    ///   - advertisesSpecialUse: fetches the capabilities after login and says
    ///     whether they hold SPECIAL-USE. Called at most once, and only when the
    ///     plain list marked none.
    ///   - markedOnRequest: asks the server for its special-use mailboxes and
    ///     returns the names marked with the role's attribute. Called at most
    ///     once, and only when the server advertises SPECIAL-USE.
    static func resolve(_ role: Role, listed: [Listed], markedInList: [String], declared: String?,
                        advertisesSpecialUse: @Sendable () async throws -> Bool,
                        markedOnRequest: @Sendable () async throws -> [String]) async throws -> Found {
        let attribute = role.attribute
        func tooMany(_ count: Int) -> SendDraftRefusal {
            SendDraftRefusal(description: "the server marks \(count) mailboxes \(attribute); \(role.consequence)")
        }
        func disagreement(with name: String) -> String {
            guard let declared, !sameName(declared, name) else { return "" }
            return " `\(role.configurationKey)` in direct-transport.json names another mailbox; the server's mark was used."
        }

        if markedInList.count > 1 { throw tooMany(markedInList.count) }
        if let only = markedInList.first {
            return Found(name: only, source: .plainList,
                         note: "The \(role.noun) is the one the server marks \(attribute) in its mailbox list."
                            + disagreement(with: only))
        }

        let advertises = try await advertisesSpecialUse()
        if advertises {
            let marked = try await markedOnRequest()
            if marked.count > 1 { throw tooMany(marked.count) }
            if let only = marked.first {
                return Found(name: only, source: .explicitRequest,
                             note: "The \(role.noun) is the one the server marks \(attribute) when asked for its special-use mailboxes (it advertises SPECIAL-USE; its plain mailbox list marked none)."
                                + disagreement(with: only))
            }
        }

        let seen = "it lists \(listed.count) \(listed.count == 1 ? "mailbox" : "mailboxes") and \(advertises ? "advertises SPECIAL-USE" : "does not advertise SPECIAL-USE")"
        let key = "`\(role.configurationKey)`"
        guard let declared else {
            throw SendDraftRefusal(description: "the server marks no mailbox \(attribute) (\(seen)), and direct-transport.json names none for this account: add \(key) with the mailbox's exact name; \(role.consequence)")
        }
        let matches = listed.filter { sameName($0.name, declared) }
        guard !matches.isEmpty else {
            throw SendDraftRefusal(description: "the server marks no mailbox \(attribute) (\(seen)), and it does not list the mailbox \(key) names in direct-transport.json (the name must match exactly, letter case and accents included); \(role.consequence)")
        }
        guard matches.count == 1, let match = matches.first else {
            throw SendDraftRefusal(description: "the server marks no mailbox \(attribute) (\(seen)), and it lists more than one mailbox with the name \(key) gives; \(role.consequence)")
        }
        guard match.selectable else {
            throw SendDraftRefusal(description: "the server marks no mailbox \(attribute) (\(seen)), and the mailbox \(key) names cannot be selected (the server marks it \\Noselect); \(role.consequence)")
        }
        return Found(name: match.name, source: .configuration,
                     note: "The server marks no mailbox \(attribute) (\(seen)), so the \(role.noun) is the one \(key) names in direct-transport.json.")
    }
}

import Foundation

struct SpecialMailboxPathCandidate: Equatable, Sendable {
    let key: String
    let leaf: String
    let path: String
    let components: [String]
}

/// Names discover candidates; they never prove a role.
func specialMailboxPathCandidates(
    leaves: [(key: String, leaf: String)],
    mailboxes: [(path: String, components: [String])]
) -> [SpecialMailboxPathCandidate] {
    var result: [SpecialMailboxPathCandidate] = []
    for entry in leaves where !entry.leaf.isEmpty {
        guard perAccountSpecialMailboxes.contains(where: { $0.key == entry.key }) else { continue }
        for mailbox in mailboxes {
            guard !mailbox.components.isEmpty,
                  mailbox.components.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") }),
                  mailbox.path == mailbox.components.joined(separator: "/"),
                  mailbox.components.last == entry.leaf || mailbox.path == entry.leaf else { continue }
            let candidate = SpecialMailboxPathCandidate(key: entry.key, leaf: entry.leaf,
                                                       path: mailbox.path, components: mailbox.components)
            if !result.contains(candidate) { result.append(candidate) }
        }
    }
    return result
}

struct SpecialMailboxPathProof: Decodable {
    struct Result: Decodable {
        let index: Int
        let available: Bool
        let matches: Bool
    }
    let version: Int
    let count: Int
    let results: [Result]

    static func parse(_ raw: String, candidateCount: Int) throws -> Self {
        guard candidateCount >= 0 else { throw MailError.invalidParameter("Invalid candidate count") }
        let proof = try JSONDecoder().decode(Self.self, from: Data(raw.utf8))
        guard proof.version == 1, proof.count == candidateCount,
              proof.results.count == candidateCount,
              Set(proof.results.map(\.index)) == Set(0..<candidateCount),
              proof.results.allSatisfy({ $0.available || !$0.matches }) else {
            throw MailError.operationFailed("Invalid native special-mailbox path proof")
        }
        return proof
    }
}

func confirmedSpecialMailboxPaths(candidates: [SpecialMailboxPathCandidate], proof: SpecialMailboxPathProof) -> [String: String] {
    // Do not allow manually constructed/inconsistent proof values to bypass parsing.
    guard proof.version == 1, proof.count == candidates.count,
          proof.results.count == candidates.count,
          Set(proof.results.map(\.index)) == Set(candidates.indices),
          proof.results.allSatisfy({ $0.available || !$0.matches }) else { return [:] }
    var confirmed: [String: [String]] = [:]
    for result in proof.results where result.available && result.matches {
        let candidate = candidates[result.index]
        confirmed[candidate.key, default: []].append(candidate.path)
    }
    return confirmed.compactMapValues { $0.count == 1 ? $0[0] : nil }
}

func buildSpecialMailboxPathProofScript(accountId: String, candidates: [SpecialMailboxPathCandidate]) throws -> String {
    guard !accountId.isEmpty, !accountId.contains("\0") else {
        throw MailError.invalidParameter("Native mailbox verification requires an account_id")
    }
    let account = "(account id \"\(appleScriptEscape(accountId))\")"
    var blocks: [String] = []
    for (index, candidate) in candidates.enumerated() {
        guard let role = perAccountSpecialMailboxes.first(where: { $0.key == candidate.key }),
              !candidate.leaf.isEmpty, !candidate.leaf.contains("\0"),
              !candidate.components.isEmpty,
              candidate.components.last == candidate.leaf || candidate.path == candidate.leaf,
              candidate.components.allSatisfy({ !$0.isEmpty && !$0.contains("/") && !$0.contains("\0") }),
              candidate.path == candidate.components.joined(separator: "/") else {
            throw MailError.invalidParameter("Invalid special-mailbox candidate")
        }
        var reference = account
        for component in candidate.components {
            reference = "(mailbox \"\(appleScriptEscape(component))\" of \(reference))"
        }
        var chainChecks: [String] = []
        for depth in candidate.components.indices.reversed() {
            let component = appleScriptEscape(candidate.components[depth])
            chainChecks.append("""
            considering case
                set actualName to name of actualBox as string
                if actualName is not "\(component)" then set chainMatches to false
            end considering
            set actualBox to (get container of actualBox)
            """)
        }
        blocks.append("""
        set availableFlag to false
        set matchFlag to false
        try
            set roleProxy to missing value
            set roleCount to 0
            repeat with roleChild in every mailbox of \(role.container)
                try
                    if (id of account of roleChild) is "\(appleScriptEscape(accountId))" then
                        set roleCount to roleCount + 1
                        set roleProxy to contents of roleChild
                    end if
                end try
            end repeat
            if roleCount is 1 then
                considering case
                    set leafMatches to ((name of roleProxy as string) is "\(appleScriptEscape(candidate.leaf))")
                end considering
                if leafMatches then
                    set candidateBox to \(reference)
                    set checkedName to name of candidateBox
                    set actualBox to candidateBox
                    set chainMatches to true
                    \(chainChecks.joined(separator: "\n"))
                    if actualBox is not \(account) then set chainMatches to false
                    set actualBox to roleProxy
                    \(chainChecks.joined(separator: "\n"))
                    if actualBox is not \(account) then set chainMatches to false
                    set matchFlag to (chainMatches and (candidateBox is roleProxy))
                    set availableFlag to true
                end if
            end if
        end try
        set rowValue to current application's NSMutableDictionary's dictionary()
        rowValue's setObject:\(index) forKey:"index"
        rowValue's setObject:availableFlag forKey:"available"
        rowValue's setObject:matchFlag forKey:"matches"
        proofRows's addObject:rowValue
        """)
    }
    return """
    use framework "Foundation"
    use scripting additions
    set proofRows to current application's NSMutableArray's array()
    tell application "Mail"
        \(blocks.joined(separator: "\n"))
    end tell
    set payload to current application's NSMutableDictionary's dictionary()
    payload's setObject:1 forKey:"version"
    payload's setObject:\(candidates.count) forKey:"count"
    payload's setObject:proofRows forKey:"results"
    set jsonData to current application's NSJSONSerialization's dataWithJSONObject:payload options:0 |error|:(missing value)
    if jsonData is missing value then error "special mailbox proof serialization failed"
    return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as string
    """
}

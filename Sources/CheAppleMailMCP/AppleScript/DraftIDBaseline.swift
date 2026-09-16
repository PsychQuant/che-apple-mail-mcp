import Foundation

enum DraftIDBaselineOutcome: Equatable {
    case complete([UUID: Set<String>])
    case unavailable(DraftReceiptUnavailableReason)
}

/// ID membership only, never creation evidence. Missing scopes and failed
/// scans must not become empty baselines or authorize a receipt/deletion.
func decodeDraftIDBaseline(_ data: Data, expectedAccountIDs: Set<UUID>) -> DraftIDBaselineOutcome {
    guard !expectedAccountIDs.isEmpty else { return .unavailable(.missingScope) }
    let invalid = DraftIDBaselineOutcome.unavailable(.invalidPayload)
    guard let value = decodeUniqueMemberJSON(data),
          let object = value as? [String: Any],
          Set(object.keys) == ["version", "status", "accounts"],
          object["version"] as? String == "1", object["status"] as? String == "complete",
          let accounts = object["accounts"] as? [[String: Any]] else { return invalid }
    var result: [UUID: Set<String>] = [:]
    for record in accounts {
        guard Set(record.keys) == ["account_id", "ids"],
              let text = record["account_id"] as? String, let account = UUID(uuidString: text),
              result[account] == nil, let ids = record["ids"] as? [String],
              ids.allSatisfy(isASCIIDigits) else { return invalid }
        result[account] = Set(ids)
    }
    guard Set(result.keys) == expectedAccountIDs else { return .unavailable(.wrongScope) }
    return .complete(result)
}

func buildDraftIDBaselineScript(accountIDs: Set<UUID>) throws -> String {
    guard !accountIDs.isEmpty else { throw MailError.invalidParameter("Draft baseline requires account scope") }
    let wanted = accountIDs.map(\.uuidString).sorted().map { "\"\($0)\"" }.joined(separator: ", ")
    return """
    use framework "Foundation"
    use scripting additions

    on baselineMailboxes()
        tell application "Mail" to return every mailbox of drafts mailbox
    end baselineMailboxes

    on baselineAccountID(theBox)
        tell application "Mail" to return id of account of theBox as string
    end baselineAccountID

    on baselineMessageIDs(theBox)
        tell application "Mail"
            set resultIDs to {}
            repeat with draftMessage in messages of theBox
                set end of resultIDs to id of draftMessage as string
            end repeat
            return resultIDs
        end tell
    end baselineMessageIDs

    set requestedIDs to {\(wanted)}
    set idsByAccount to current application's NSMutableDictionary's dictionary()
    set seenAccounts to current application's NSMutableSet's |set|()
    repeat with wantedID in requestedIDs
        idsByAccount's setObject:(current application's NSMutableArray's array()) forKey:(wantedID as string)
    end repeat
    set draftBoxes to my baselineMailboxes()
    repeat with draftBox in draftBoxes
        set actualID to my baselineAccountID(contents of draftBox)
        set actualID to ((current application's NSString's stringWithString:actualID)'s uppercaseString()) as string
        if actualID is in requestedIDs then
            seenAccounts's addObject:actualID
            set scopedIDs to idsByAccount's objectForKey:actualID
            set nativeIDs to my baselineMessageIDs(contents of draftBox)
            repeat with messageID in nativeIDs
                scopedIDs's addObject:(messageID as string)
            end repeat
        end if
    end repeat
    set baselineRecords to current application's NSMutableArray's array()
    repeat with wantedID in requestedIDs
        set accountText to wantedID as string
        if not ((seenAccounts's containsObject:accountText) as boolean) then error "Draft baseline scope unavailable"
        set recordValue to current application's NSMutableDictionary's dictionary()
        recordValue's setObject:accountText forKey:"account_id"
        recordValue's setObject:(idsByAccount's objectForKey:accountText) forKey:"ids"
        baselineRecords's addObject:recordValue
    end repeat
    set envelope to current application's NSMutableDictionary's dictionary()
    envelope's setObject:"1" forKey:"version"
    envelope's setObject:"complete" forKey:"status"
    envelope's setObject:baselineRecords forKey:"accounts"
    set encoded to current application's NSJSONSerialization's dataWithJSONObject:envelope options:0 |error|:(missing value)
    if encoded is missing value then error "Draft baseline encoding failed"
    return (current application's NSString's alloc()'s initWithData:encoded encoding:(current application's NSUTF8StringEncoding)) as string
    """
}

extension MailController {
    /// Independent foundation for #409. The creation adapter must pass its live
    /// gate before a caller can wire this read before creation or use a receipt.
    /// Enumerates role/account metadata, then IDs only within requested scopes.
    func readDraftIDBaseline(accountIDs: Set<UUID>) -> DraftIDBaselineOutcome {
        guard !accountIDs.isEmpty else { return .unavailable(.missingScope) }
        do {
            let source = try buildDraftIDBaselineScript(accountIDs: accountIDs)
            let raw = try runDraftScanScript(source)
            return decodeDraftIDBaseline(Data(raw.utf8), expectedAccountIDs: accountIDs)
        } catch {
            // Never substitute partial IDs or expose native diagnostics that
            // might contain account metadata. No automatic read retry here.
            return .unavailable(.readFailed)
        }
    }
}

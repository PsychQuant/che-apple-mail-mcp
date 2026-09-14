import Foundation

/// A single native operation rechecks identity and classification inputs before
/// moving to the account's actual Trash role. No delete/empty-trash operation.
func buildClassificationTrashScript(_ message: ClassificationMessage, deadline: Date = Date().addingTimeInterval(60)) throws -> String {
    guard message.hasVerifiableIdentity else { throw ClassificationError.invalidPlan("unverifiable native identity") }
    guard let nativeSource = message.nativeSource,
          classificationDigest(Data(normalizedClassificationSource(nativeSource).utf8)) == message.contentDigest else {
        throw ClassificationError.invalidPlan("native source comparison unavailable")
    }
    let sourceBase64 = Data(normalizedClassificationSource(nativeSource).utf8).base64EncodedString()
    let deadlineSeconds = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), deadline.timeIntervalSince1970)
    let timeGuard = "if my classifierExpired(\(deadlineSeconds)) then return \"CLASSIFY_REFUSED\""
    let account = appleScriptEscape(message.accountID)
    let mid = appleScriptEscape(message.messageID)
    let bareMID = appleScriptEscape(String(message.messageID.dropFirst().dropLast()))
    let components = message.mailboxComponents.map { "\"\(appleScriptEscape($0))\"" }.joined(separator: ", ")
    let expectedList = message.listID.flatMap(EmailClassifier.canonicalListID)
    // Invalid List-ID cannot be checked reliably against Mail's fresh source.
    guard message.listID == nil || expectedList != nil else {
        throw ClassificationError.invalidPlan("unparseable List-ID needs manual review")
    }
    var chainChecks: [String] = []
    for component in message.mailboxComponents.reversed() {
        chainChecks.append("if (name of checkedBox as string) is not \"\(appleScriptEscape(component))\" then return \"CLASSIFY_REFUSED\"")
        chainChecks.append("set checkedBox to get container of checkedBox")
    }
    return """
    use framework "Foundation"
    use scripting additions

    on classifierExpired(deadlineSeconds)
        set moment to current application's NSDate's |date|()
        return ((moment's timeIntervalSince1970()) as real) is greater than deadlineSeconds
    end classifierExpired

    on classifierSourceEquals(sourceText, expectedBase64)
        set normalized to current application's NSString's stringWithString:sourceText
        set normalized to normalized's stringByReplacingOccurrencesOfString:(return & linefeed) withString:linefeed
        set normalized to normalized's stringByReplacingOccurrencesOfString:return withString:linefeed
        set actualBytes to normalized's dataUsingEncoding:(current application's NSUTF8StringEncoding)
        set expectedBytes to current application's NSData's alloc()'s initWithBase64EncodedString:expectedBase64 options:0
        if expectedBytes is missing value then return false
        return (actualBytes's isEqualToData:expectedBytes) as boolean
    end classifierSourceEquals

    on classifierListID(sourceText)
        set textValue to current application's NSString's stringWithString:sourceText
        set textValue to textValue's stringByReplacingOccurrencesOfString:(return & linefeed) withString:linefeed
        set textValue to textValue's stringByReplacingOccurrencesOfString:return withString:linefeed
        set boundary to textValue's rangeOfString:(linefeed & linefeed)
        if (location of boundary) is (current application's NSNotFound) then return missing value
        set headerText to textValue's substringToIndex:(location of boundary)
        set linesList to (headerText's componentsSeparatedByString:linefeed) as list
        set listCount to 0
        set collecting to false
        set collected to ""
        repeat with headerLine in linesList
            set lineText to headerLine as string
            set lowerLine to ((current application's NSString's stringWithString:lineText)'s lowercaseString()) as string
            if (lineText starts with space) or (lineText starts with tab) then
                if collecting then set collected to collected & space & lineText
            else
                set collecting to false
                if lowerLine starts with "list-id:" then
                    set listCount to listCount + 1
                    set collecting to true
                    if (count characters of lineText) > 8 then set collected to text 9 thru -1 of lineText
                end if
            end if
        end repeat
        if listCount is 0 then return ""
        if listCount is not 1 then return missing value
        set valueText to current application's NSString's stringWithString:collected
        set valueText to valueText's stringByTrimmingCharactersInSet:(current application's NSCharacterSet's whitespaceAndNewlineCharacterSet())
        set openingParts to (valueText's componentsSeparatedByString:"<") as list
        if (count openingParts) is 2 then
            set closingParts to ((current application's NSString's stringWithString:(item 2 of openingParts))'s componentsSeparatedByString:">") as list
            if (count closingParts) is not 2 then return missing value
            set suffixText to (current application's NSString's stringWithString:(item 2 of closingParts))'s stringByTrimmingCharactersInSet:(current application's NSCharacterSet's whitespaceAndNewlineCharacterSet())
            if (suffixText as string) is not "" then return missing value
            set valueText to current application's NSString's stringWithString:(item 1 of closingParts)
        else if (count openingParts) is not 1 then
            return missing value
        end if
        set checker to current application's NSPredicate's predicateWithFormat:"SELF MATCHES %@" argumentArray:{"[A-Za-z0-9][A-Za-z0-9._-]*"}
        if not (checker's evaluateWithObject:valueText) then return missing value
        return (valueText's lowercaseString()) as string
    end classifierListID

    \(timeGuard)
    tell application "Mail"
        set targetAccount to account id "\(account)"
        set sourceBox to targetAccount
        considering case
            repeat with wantedName in {\(components)}
                set boxMatches to every mailbox of sourceBox whose name is (wantedName as string)
                if (count boxMatches) is not 1 then return "CLASSIFY_REFUSED"
                set sourceBox to item 1 of boxMatches
            end repeat
            set checkedBox to sourceBox
            \(chainChecks.joined(separator: "\n"))
            if checkedBox is not targetAccount then return "CLASSIFY_REFUSED"
            set candidates to every message of sourceBox whose id is \(message.id)
            if (count candidates) is not 1 then return "CLASSIFY_REFUSED"
            set msg to item 1 of candidates
            set nativeMID to message id of msg as string
            if nativeMID is not "\(mid)" and nativeMID is not "\(bareMID)" then return "CLASSIFY_REFUSED"
            if (subject of msg as string) is not "\(appleScriptEscape(message.subject))" then return "CLASSIFY_REFUSED"
            if (sender of msg as string) is not "\(appleScriptEscape(message.sender))" then return "CLASSIFY_REFUSED"
        end considering
        if (flagged status of msg) is not \(message.isFlagged ? "true" : "false") then return "CLASSIFY_REFUSED"
        if deleted status of msg then return "CLASSIFY_REFUSED"
        set currentList to my classifierListID(source of msg as string)
        if currentList is missing value then return "CLASSIFY_REFUSED"
        if currentList is not "\(appleScriptEscape(expectedList ?? ""))" then return "CLASSIFY_REFUSED"
        set trashCount to 0
        set trashBox to missing value
        repeat with roleChild in every mailbox of trash mailbox
            if (id of account of roleChild as string) is "\(account)" then
                set trashCount to trashCount + 1
                set trashBox to contents of roleChild
            end if
        end repeat
        if trashCount is not 1 then return "CLASSIFY_REFUSED"
        if sourceBox is trashBox then return "CLASSIFY_ALREADY_TRASH"
        \(message.isDraft == false ? """
        repeat with draftBox in every mailbox of drafts mailbox
            if (id of account of draftBox as string) is "\(account)" then
                if sourceBox is (contents of draftBox) then return "CLASSIFY_REFUSED"
                considering case
                    set draftMatches to every message of draftBox whose message id is "\(mid)" or message id is "\(bareMID)"
                end considering
                if (count draftMatches) > 0 then return "CLASSIFY_REFUSED"
            end if
        end repeat
        """ : "")
        -- Last source read immediately precedes the move. Mail exposes no
        -- atomic compare-and-move primitive; an external edit can still race.
        if not (my classifierSourceEquals(source of msg as string, "\(sourceBase64)")) then return "CLASSIFY_REFUSED"
        \(timeGuard)
        move msg to trashBox
        return "CLASSIFY_MOVED"
    end tell
    """
}

/// Read-only fallback when a located SQLite message has no usable local RFC source.
func buildClassificationSourceReadScript(id: String, accountID: String, components: [String]) throws -> String {
    try validateClassificationIDs([id])
    guard !accountID.isEmpty, !components.isEmpty,
          ([accountID] + components).allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) }) }) else {
        throw ClassificationError.invalidPlan("invalid classification source location")
    }
    let names = components.map { "\"\(appleScriptEscape($0))\"" }.joined(separator: ", ")
    let checks = components.reversed().map { component in
        "if (name of checkedBox as string) is not \"\(appleScriptEscape(component))\" then error \"Classification source changed\"\nset checkedBox to get container of checkedBox"
    }.joined(separator: "\n")
    return """
    tell application "Mail"
        set targetAccount to account id "\(appleScriptEscape(accountID))"
        set sourceBox to targetAccount
        considering case
            repeat with wantedName in {\(names)}
                set matches to every mailbox of sourceBox whose name is (wantedName as string)
                if (count matches) is not 1 then error "Classification source is ambiguous"
                set sourceBox to item 1 of matches
            end repeat
            set checkedBox to sourceBox
            \(checks)
            if checkedBox is not targetAccount then error "Classification source account changed"
        end considering
        set candidates to every message of sourceBox whose id is \(id)
        if (count candidates) is not 1 then error "Classification message is ambiguous"
        return source of item 1 of candidates
    end tell
    """
}

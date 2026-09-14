import Foundation

let composeSignatureHandlers = """
on composeWindowMatches(_ids, _names, _frontId, _expectedId, _expectedTitle, _requireFront)
    if (count _ids) is not (count _names) then return false
    set _matches to 0
    repeat with _i from 1 to count _ids
        if (item _i of _ids) is _expectedId then
            considering case
                if (item _i of _names) is not _expectedTitle then return false
            end considering
            set _matches to _matches + 1
        end if
    end repeat
    if _matches is not 1 then return false
    if _requireFront and _frontId is not _expectedId then return false
    return true
end composeWindowMatches

on assertComposeWindowOwner(_expectedId, _expectedTitle, _requireFront)
    tell application "Mail"
        set _nativeIds to {}
        set _nativeNames to {}
        repeat with _window in windows
            try
                set _nativeId to id of _window
                set _nativeName to name of _window as string
                set end of _nativeIds to _nativeId
                set end of _nativeNames to _nativeName
            end try
        end repeat
        set _frontId to missing value
        if _requireFront then
            try
                set _frontId to id of front window
            end try
        end if
    end tell
    if not (my composeWindowMatches(_nativeIds, _nativeNames, _frontId, _expectedId, _expectedTitle, _requireFront)) then error "COMPOSEIDENTITY: original window disappeared, changed title, or is not frontmost"
end assertComposeWindowOwner

on signaturePopupFor(_window)
    tell application "System Events"
        set _found to missing value
        set _matches to 0
        try
            set _total to count of pop up buttons of _window
        on error
            return missing value
        end try
        repeat with _i from 1 to _total
            try
                set _candidate to pop up button _i of _window
                if (value of attribute "AXIdentifier" of _candidate) is "popup_signature" then
                    set _matches to _matches + 1
                    set _found to _candidate
                end if
            end try
        end repeat
        if _matches is not 1 then return missing value
        return _found
    end tell
end signaturePopupFor

on openedSignatureMenu(_popup, _expectedId, _expectedTitle)
    my assertComposeWindowOwner(_expectedId, _expectedTitle, true)
    tell application "System Events"
        click _popup
        repeat 12 times
            try
                if (count of menu items of menu 1 of _popup) > 0 then return menu 1 of _popup
            end try
            delay 0.1
        end repeat
        error "SIGNATURE: menu did not become available"
    end tell
end openedSignatureMenu

on signatureChoiceLimit(_menu)
    tell application "System Events"
        repeat with _i from 3 to (count of menu items of _menu)
            set _entry to menu item _i of _menu
            set _label to ""
            try
                set _label to name of _entry as string
            end try
            if not (enabled of _entry) and _label is "" then return _i - 1
        end repeat
    end tell
    return 0
end signatureChoiceLimit

on signatureChoiceIndex(_labels, _enabled, _marks, _mode, _wanted)
    set _total to count _labels
    if _total < 2 or (count _enabled) is not _total or (count _marks) is not _total then return 0
    if (item 1 of _labels) is not "None" and (item 1 of _labels) is not "無" then return 0
    if not (item 1 of _enabled) or (item 2 of _enabled) or (item 2 of _labels) is not "" then return 0
    set _expected to 1
    if _mode is "named" then
        set _expected to 0
        set _matches to 0
        set _limit to 0
        repeat with _i from 3 to _total
            if not (item _i of _enabled) and (item _i of _labels) is "" then
                set _limit to _i - 1
                exit repeat
            end if
        end repeat
        if _limit < 3 then return 0
        repeat with _i from 3 to _limit
            considering case
                if (item _i of _labels) is _wanted and (item _i of _enabled) then
                    set _expected to _i
                    set _matches to _matches + 1
                end if
            end considering
        end repeat
        if _matches is not 1 then return 0
    end if
    set _marked to 0
    repeat with _i from 1 to _total
        if (item _i of _marks) is not "" then
            if (item _i of _marks) is not "✓" and (item _i of _marks) is not "✔" then return 0
            if _marked is not 0 then return 0
            set _marked to _i
        end if
    end repeat
    if _marked is not _expected then return 0
    return _expected
end signatureChoiceIndex

on verifySignatureMenuChoice(_popup, _mode, _wanted, _expectedId, _expectedTitle)
    set _menu to my openedSignatureMenu(_popup, _expectedId, _expectedTitle)
    tell application "System Events"
        set _labels to {}
        set _enabled to {}
        set _marks to {}
        repeat with _i from 1 to (count of menu items of _menu)
            set _entry to menu item _i of _menu
            set _label to ""
            set _mark to ""
            try
                set _label to name of _entry as string
            end try
            try
                set _mark to value of attribute "AXMenuItemMarkChar" of _entry as string
            end try
            set end of _labels to _label
            set end of _enabled to enabled of _entry
            set end of _marks to _mark
        end repeat
        set _index to my signatureChoiceIndex(_labels, _enabled, _marks, _mode, _wanted)
        if _index is 0 then error "SIGNATURE: selected menu item is not independently verifiable"
        -- Select the already-checked item to close this exact menu, not a
        -- global Escape keystroke that could hit another window.
        my assertComposeWindowOwner(_expectedId, _expectedTitle, true)
        click menu item _index of _menu
    end tell
end verifySignatureMenuChoice

on signatureReceipt(_mode, _selected, _verified, _changed)
    set _record to current application's NSMutableDictionary's dictionary()
    _record's setObject:_mode forKey:"mode"
    _record's setObject:_selected forKey:"selection"
    _record's setObject:_verified forKey:"selection_verified"
    _record's setObject:_changed forKey:"selection_applied"
    set _data to current application's NSJSONSerialization's dataWithJSONObject:_record options:0 |error|:(missing value)
    if _data is missing value then error "SIGNATURE: cannot encode selection receipt"
    return " [signature-receipt:" & ((_data's base64EncodedStringWithOptions:0) as string) & "]"
end signatureReceipt

"""

func signatureDefinitionPreflight(_ selection: ComposeSignatureSelection) -> String {
    guard selection.mode == .named, let name = selection.name else { return "" }
    return """
    tell application "Mail"
        considering case
            if (count of (every signature whose name is "\(appleScriptEscape(name))")) is not 1 then error "SIGNATURE: name is missing or ambiguous in Mail"
        end considering
    end tell

    """
}

func buildComposeSignaturePhase(_ selection: ComposeSignatureSelection, guardWindow: String,
                                stepDelay: Double) -> String {
    let explicit = selection.mode != .mailDefault
    let named = selection.mode == .named
    let name = appleScriptEscape(selection.name ?? "")
    var script = """

        set _signatureSelected to ""
        set _signatureVerified to false
        set _signatureChanged to false
        tell application "System Events"
            tell process "Mail"
                set frontmost to true
                \(guardWindow)
                set _signaturePopup to my signaturePopupFor(_w)
    """
    if explicit {
        script += """

                if _signaturePopup is missing value then error "SIGNATURE: unique popup_signature control not found"
                set _signatureMenu to my openedSignatureMenu(_signaturePopup, _ourId, _t)
                set _noneItem to menu item 1 of _signatureMenu
                set _noneLabel to name of _noneItem as string
                if (role of _noneItem) is not "AXMenuItem" or not (enabled of _noneItem) then error "SIGNATURE: native None item is unavailable"
                if _noneLabel is not "None" and _noneLabel is not "無" then error "SIGNATURE: unrecognized native None item; no guessed selection"
                if (count of menu items of _signatureMenu) < 2 then error "SIGNATURE: missing native separator"
                set _separator to menu item 2 of _signatureMenu
                set _separatorName to ""
                try
                    set _separatorName to name of _separator as string
                end try
                if (enabled of _separator) or _separatorName is not "" then error "SIGNATURE: None section is not recognizable"
    """
        if named {
            // Validate the desired choice before changing the native signature.
            script += """

                set _signatureMatches to 0
                set _signatureLimit to my signatureChoiceLimit(_signatureMenu)
                if _signatureLimit < 3 then error "SIGNATURE: named-signature section is unavailable"
                repeat with _i from 3 to _signatureLimit
                    set _entry to menu item _i of _signatureMenu
                    considering case
                        if (name of _entry as string) is "\(name)" and (enabled of _entry) then set _signatureMatches to _signatureMatches + 1
                    end considering
                end repeat
                if _signatureMatches is not 1 then error "SIGNATURE: requested name is missing or ambiguous in this account menu"
            """
        }
        script += """

                my assertComposeWindowOwner(_ourId, _t, true)
                click _noneItem
                delay \(stepDelay)
                \(guardWindow)
                set _signaturePopup to my signaturePopupFor(_w)
                if _signaturePopup is missing value then error "SIGNATURE: popup disappeared after None selection"
                set _signatureSelected to value of _signaturePopup as string
                if _signatureSelected is not _noneLabel then error "SIGNATURE: None read-back mismatch"
                my verifySignatureMenuChoice(_signaturePopup, "none", "", _ourId, _t)
                delay \(stepDelay)
                set _signatureChanged to true
        """
        if named {
            script += """

                set _signatureMenu to my openedSignatureMenu(_signaturePopup, _ourId, _t)
                set _signatureMatches to 0
                set _signaturePicked to missing value
                set _signatureLimit to my signatureChoiceLimit(_signatureMenu)
                if _signatureLimit < 3 then error "SIGNATURE: named-signature section is unavailable"
                repeat with _i from 3 to _signatureLimit
                    set _entry to menu item _i of _signatureMenu
                    considering case
                        if (name of _entry as string) is "\(name)" and (enabled of _entry) then
                            set _signatureMatches to _signatureMatches + 1
                            set _signaturePicked to _entry
                        end if
                    end considering
                end repeat
                if _signatureMatches is not 1 then error "SIGNATURE: requested name changed after clearing signature"
                my assertComposeWindowOwner(_ourId, _t, true)
                click _signaturePicked
                delay \(stepDelay)
                \(guardWindow)
                set _signaturePopup to my signaturePopupFor(_w)
                if _signaturePopup is missing value then error "SIGNATURE: popup disappeared after named selection"
                set _signatureSelected to value of _signaturePopup as string
                considering case
                    if _signatureSelected is not "\(name)" then error "SIGNATURE: named read-back mismatch"
                end considering

                my verifySignatureMenuChoice(_signaturePopup, "named", "\(name)", _ourId, _t)
                delay \(stepDelay)
            """
        }
        script += "\n                set _signatureVerified to true"
    } else {
        script += """

                if _signaturePopup is not missing value then
                    try
                        set _signatureSelected to value of _signaturePopup as string
                        set _signatureVerified to (_signatureSelected is not "")
                    end try
                end if
        """
    }
    script += """

            end tell
        end tell
        set _signatureTag to my signatureReceipt("\(selection.mode.rawValue)", _signatureSelected, _signatureVerified, _signatureChanged)
    """
    return script
}


func composeSignatureDispatchCheck(_ selection: ComposeSignatureSelection) -> String {
    guard selection.mode != .mailDefault else { return "" }
    return """
                set _signaturePopup to my signaturePopupFor(_w)
                if _signaturePopup is missing value then error "SIGNATURE: popup unavailable at dispatch"
                considering case
                    if (value of _signaturePopup as string) is not _signatureSelected then error "SIGNATURE: selection changed before dispatch"
                end considering
                my verifySignatureMenuChoice(_signaturePopup, "\(selection.mode.rawValue)", "\(appleScriptEscape(selection.name ?? ""))", _ourId, _t)
    """
}

import Foundation

let composeCleanupIdentityHandlers = """
on classifyComposeCleanupOwner(_ids, _names, _frontId, _expectedId, _expectedTitle, _requireFront)
    if class of _expectedId is not integer or class of _expectedTitle is not text then return "unknown"
    if class of _ids is not list or class of _names is not list then return "unknown"
    if (count _ids) is not (count _names) then return "unknown"
    set _ownedMatches to 0
    set _titleMatches to 0
    set _ownedTitle to ""
    repeat with _i from 1 to count _ids
        if class of item _i of _ids is not integer or class of item _i of _names is not text then return "unknown"
        set _thisId to (item _i of _ids) as integer
        set _thisTitle to (item _i of _names) as string
        if _thisId is _expectedId then
            set _ownedMatches to _ownedMatches + 1
            set _ownedTitle to _thisTitle
        end if
        considering case
            if _thisTitle is _expectedTitle then set _titleMatches to _titleMatches + 1
        end considering
    end repeat
    if _ownedMatches is 0 then return "absent"
    if _ownedMatches is not 1 then return "unknown"
    considering case
        if _ownedTitle is not _expectedTitle then return "changed"
    end considering
    if _titleMatches is not 1 then return "ambiguous"
    if _requireFront and class of _frontId is not integer then return "unknown"
    if _requireFront and _frontId is not _expectedId then return "wrong_front"
    return "owned"
end classifyComposeCleanupOwner

on composeCleanupOwnerState(_expectedId, _expectedTitle, _requireFront)
    try
        tell application "Mail"
            set _ids to {}
            set _names to {}
            repeat with _window in windows
                set end of _ids to id of _window
                set end of _names to name of _window
            end repeat
            set _frontId to missing value
            if _requireFront and (count _ids) > 0 then set _frontId to id of front window
        end tell
    on error number _identityNumber
        error "CLEANUPIDENTITY: native window metadata unavailable" number _identityNumber
    end try
    return my classifyComposeCleanupOwner(_ids, _names, _frontId, _expectedId, _expectedTitle, _requireFront)
end composeCleanupOwnerState

"""

import Foundation

func buildAccountIdentitySnapshotScript() -> String {
    #"""
    use framework "Foundation"
    use scripting additions
    if application "Mail" is not running then error "Mail is not running; account identity metadata unavailable"
    set identityRows to current application's NSMutableArray's array()
    tell application "Mail"
        set accountRefs to accounts
        set expectedCount to count of accountRefs
        repeat with acc in accountRefs
            set accountID to id of acc as string
            set accountAddresses to {}
            set addressAvailable to true
            try
                set accountAddresses to email addresses of acc
                if accountAddresses is missing value then
                    set accountAddresses to {}
                    set addressAvailable to false
                end if
            on error
                set accountAddresses to {}
                set addressAvailable to false
            end try
            set recordValue to current application's NSMutableDictionary's dictionary()
            recordValue's setObject:accountID forKey:"id"
            recordValue's setObject:accountAddresses forKey:"addresses"
            recordValue's setObject:addressAvailable forKey:"available"
            identityRows's addObject:recordValue
        end repeat
    end tell
    set payload to current application's NSMutableDictionary's dictionary()
    payload's setObject:1 forKey:"version"
    payload's setObject:expectedCount forKey:"count"
    payload's setObject:identityRows forKey:"accounts"
    set jsonData to current application's NSJSONSerialization's dataWithJSONObject:payload options:0 |error|:(missing value)
    if jsonData is missing value then error "account identity JSON serialization failed"
    return (current application's NSString's alloc()'s initWithData:jsonData encoding:(current application's NSUTF8StringEncoding)) as string
    """#
}

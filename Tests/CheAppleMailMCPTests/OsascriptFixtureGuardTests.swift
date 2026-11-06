import XCTest

/// #572: the fixture guard must refuse every way a fragment can address an application,
/// not only the literal `tell application`. None of these fragments is ever run.
final class OsascriptFixtureGuardTests: XCTestCase {

    func testRefusesEveryApplicationAddressingForm() {
        let forms = [
            "tell application \"Mail\"\nclose window 1\nend tell",
            "tell app \"Mail\" to close window 1",
            "set _n to name of front window of application \"Mail\"",
            "activate application \"Mail\"",
            "tell application id \"com.apple.mail\" to activate",
            "set _app to \"Mail\"\ntell application _app to activate",
            "tell application \"System Events\"\ntell process \"Mail\" to click button 1\nend tell",
            "tell process \"Mail\" to perform action \"AXRaise\" of window 1",
            "tell «class capp» \"Mail\" to activate",
            "run script \"tell app \\\"Mail\\\" to activate\"",
            "do shell script \"osascript -e 'tell app \\\"Mail\\\" to activate'\"",
            "set _s to load script (POSIX file \"/tmp/x.scpt\")",
            "TELL APP \"Mail\" TO ACTIVATE",
            // #572 verify:
            "-- x\r\ntell app \"Mail\" to activate",                      // CRLF ends the comment
            "set |a\"| to 1\ntell app \"Mail\" to activate",              // a quote inside |…|
            "set x to |a--| & (name of application \"Mail\")",            // a comment marker inside |…|
            "do ¬\nshell script \"true\"",                               // ¬ continuation
            "open location \"mailto:a@example.invalid\"",                  // launches the mail handler
            "store script me in (POSIX file \"/tmp/x.scpt\")",
            "use framework \"AppKit\"\nreturn its NSWorkspace's sharedWorkspace()",
            "set x to 1\ruse framework \"Foundation\"\rreturn its NSWorkspace's sharedWorkspace()",  // CR ends a line
            // #572 verify, round 2: `\|` and `\\` are escapes inside |…|, so any `|` is refused.
            "set |a\\| \" | to 1\ntell app \"Mail\" to activate",
            "set |a\\| (* | to 1\ntell app \"Mail\" to activate",
            "set |x\\\\\\|-- | to name of application \"Mail\"",
            "set |x\\\\\\|\"| to name of application \"Mail\"",
        ]
        for fragment in forms {
            XCTAssertThrowsError(try OsascriptFixtureGuard.check(fragment), "must refuse: \(fragment.debugDescription)")
        }
    }

    /// #617: handlers that use the Objective-C bridge pass only with the allowance, and the bridge
    /// is not a way around the check.
    func testTheFoundationBridgeAllowanceLetsThroughOnlyTheBridge() throws {
        let handler = """
            use framework "Foundation"
            use scripting additions
            on normalized(s)
                return (current application's NSString's stringWithString:s) as text
            end normalized
            """
        XCTAssertThrowsError(try OsascriptFixtureGuard.check(handler), "without the allowance it is refused")
        XCTAssertNoThrow(try OsascriptFixtureGuard.check(handler, foundationBridge: true))
        XCTAssertNoThrow(try OsascriptFixtureGuard.check("use (* x *) framework \"Foundation\"\nreturn 1", foundationBridge: true),
                         "a comment does not change which framework it is")
        XCTAssertNoThrow(try OsascriptFixtureGuard.check(
            "return current application's NSPredicate's predicateWithFormat:\"SELF MATCHES %@\" argumentArray:{\"x\"}",
            foundationBridge: true), "the one format the handlers use")
        XCTAssertNoThrow(try OsascriptFixtureGuard.check("if class of x is text then return 1", foundationBridge: true))
        XCTAssertNoThrow(try OsascriptFixtureGuard.check(
            "return current application's NSJSONSerialization's dataWithJSONObject:x options:0 |error|:(missing value)",
            foundationBridge: true), "a keyword label the bridge needs")
        XCTAssertThrowsError(try OsascriptFixtureGuard.check("set |a\\| \" | to 1", foundationBridge: true), "any other |…| stays refused")
        let refused = [
            "use framework \"AppKit\"\nreturn 1",
            "use framework \"Foundation\"\nreturn current application's NSWorkspace's sharedWorkspace()",
            "return current application's NSAppleScript's alloc()",
            "return current application's NSTask's launchedTaskWithLaunchPath:\"/bin/sh\" arguments:{}",
            "return its NSRunningApplication's currentApplication()",
            "use framework \"Foundation\"\ntell application \"Mail\" to activate",
            "use framework \"Foundation\"\ntell app \"Mail\" to activate",
            "use framework \"Foundation\"\nreturn current application's NSString's performSelector:\"x\"",
            // #617 verify: the framework's name is read the way the import is removed.
            "use (* x *) framework \"AppKit\"\nreturn 1",
            "(* x *) use framework \"ScriptingBridge\"\nreturn 1",
            "use ¬\nframework \"AppKit\"\nreturn 1",
            "return current application's SBApplication's applicationWithBundleIdentifier:\"com.apple.mail\"",
            // A class named in a string: the literal is empty by the time the list is read.
            "return current application's class \"NSWorkspace\"",
            "return current application's NSClassFromString(\"NSTask\")",
            "return current application's NSSelectorFromString(\"x\")",
            "return current application's NSInvocation",
            "return x's valueForKey:\"y\"",
            "return current application's nstask",
            "return current\napplication \"Mail\"",
            // #617 verify: a format string is code. These are read, never run.
            "use framework \"Foundation\"\nset e to current application's NSExpression's expressionWithFormat:\"FUNCTION(CAST('NSTask', 'Class'), 'x')\" argumentArray:{}",
            "return current application's NSPredicate's predicateWithFormat:\"FUNCTION(CAST('NSTask', 'Class'), 'x') == 1\" argumentArray:{}",
            "return current application's NSPredicate's predicateWithFormat:aFormat argumentArray:{}",
            "set p to current application's NSPredicate\nreturn p's predicateWithFormat:\"SELF MATCHES %@\" argumentArray:{}",
            // The allowed text has to be the whole format argument, not its start.
            "return current application's NSPredicate's predicateWithFormat:\"SELF MATCHES %@\" & aSuffix argumentArray:{\"x\"}",
            "return current application's NSPredicate's predicateWithFormat:\"SELF MATCHES %@\" & \" OR x\" argumentArray:{\"x\"}",
            "return current application's NSPredicate's predicateWithFormat:\"SELF MATCHES %@\" ¬\n& aSuffix argumentArray:{\"x\"}",
            "return current application's NSPredicate's predicateWithFormat:\"SELF MATCHES %@\"",
            // A closed list: Foundation or not, loaded or not.
            "return current application's NSSharingService",
            "return its NSFileManager's defaultManager()",
            "return its CIFilter",
            "return its OSAScript's alloc()",
            "return current application's class (\"NS\" & \"Task\")",
            "return its class \"NSTask\"",
            "return its class (\"NS\" & \"Task\")",
            "return x's makeObjectsPerformSelector:\"y\"",
            // `current application` passes only before a listed name; the `application` check refuses the rest.
            "set ca to current application\nreturn ca's NSString",
            // Pipes pass only around the listed words, so these stay in reach of the word checks.
            "tell |application| \"Mail\" to activate",
            "return |process|",
            "return |NSString|",
        ]
        for fragment in refused {
            XCTAssertThrowsError(try OsascriptFixtureGuard.check(fragment, foundationBridge: true), "must refuse: \(fragment.debugDescription)")
        }
    }

    func testNeutralisingDropsApplicationBlocksAndLeavesTheRest() throws {
        let source = """
            on pure(x)
                return x + 1
            end pure
            on gui()
                tell application "System Events"
                    tell process "Mail"
                        click button 1
                    end tell
                end tell
                return 1
            end gui
            """
        let out = OsascriptFixtureGuard.neutralisingApplicationBlocks(source)
        XCTAssertNoThrow(try OsascriptFixtureGuard.check(out))
        XCTAssertTrue(out.contains("return x + 1"))
        XCTAssertTrue(out.contains("end gui"))
        XCTAssertThrowsError(try OsascriptFixtureGuard.check(OsascriptFixtureGuard.neutralisingApplicationBlocks(
            "on gui()\ntell application \"Mail\" to activate\nend gui")), "a one-line tell stays and is refused")
    }

    func testAcceptsTheShapesTheFixturesActuallyRun() throws {
        let fixtures = [
            "set _activated to true\nset _launchCount to _launchCount + 1",
            "if _beforeTitles contains \"S\" then error \"a window titled S already existed before this compose\"",
            "set _ourId to item 1 of _cw\nset _title to item 2 of _cw",
            "tell me\nset _titleMatches to 1\nend tell",
            "set _stillOpen to (my fixtureState is not \"absent\")",
        ]
        for fragment in fixtures {
            XCTAssertNoThrow(try OsascriptFixtureGuard.check(fragment), fragment)
        }
    }

    /// Words inside a string literal or a comment are text, not code: an error message that mentions
    /// an application must not trip the checks. `application "Mail"` in code still does.
    func testCommentsAndStringLiteralsAreNotCode() throws {
        // The production cleanup block mentions System Events in both places (#572).
        XCTAssertNoThrow(try OsascriptFixtureGuard.check(
            "-- with \"System Events: connection error\" while Mail was still setting\n"
            + "set _r to \"no window was visible to System Events, so nothing was clicked\""))
        XCTAssertNoThrow(try OsascriptFixtureGuard.check("# tell application \"Mail\"\n(* tell app \"Mail\" (* nested *) *)\nset x to 1"))
        XCTAssertEqual(OsascriptFixtureGuard.code(of: "a \"b \\\" c\" d \"e -- f\" -- g"), "a \"\" d \"\" ")
        // A comment marker inside a literal does not hide the code after the literal.
        XCTAssertThrowsError(try OsascriptFixtureGuard.check("set x to \"--\" & (name of application \"Mail\")"))
    }
}

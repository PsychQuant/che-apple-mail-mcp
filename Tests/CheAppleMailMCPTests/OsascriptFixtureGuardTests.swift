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
        ]
        for fragment in forms {
            XCTAssertThrowsError(try OsascriptFixtureGuard.check(fragment), "must refuse: \(fragment.debugDescription)")
        }
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

    /// Words inside a string literal are text, not code: an error message that mentions an
    /// application must not trip the code checks. The raw checks still catch `application "`.
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

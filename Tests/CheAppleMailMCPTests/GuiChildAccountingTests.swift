import XCTest
@testable import CheAppleMailMCP

final class GuiChildAccountingTests: XCTestCase {
    // With registration atomic, the former flag/increment gap has no exposed
    // intermediate state. These ordered tests cover both legal linearizations.
    func testExitBeforeRegistrationDoesNotCount() {
        let accounting = GuiChildAccounting()
        let child = accounting.trackChild()
        child.didExit()
        child.markUnreaped()
        XCTAssertEqual(accounting.current(), 0)
    }

    func testRegistrationBeforeExitCountsUntilExit() {
        let accounting = GuiChildAccounting()
        let child = accounting.trackChild()
        XCTAssertEqual(accounting.current(), 0)
        child.markUnreaped()
        XCTAssertEqual(accounting.current(), 1)
        child.didExit()
        XCTAssertEqual(accounting.current(), 0)
    }

    func testRepeatedNotificationsAreIdempotent() {
        let accounting = GuiChildAccounting()
        let child = accounting.trackChild()
        child.markUnreaped()
        child.markUnreaped()
        XCTAssertEqual(accounting.current(), 1)
        child.didExit()
        child.didExit()
        child.markUnreaped()
        XCTAssertEqual(accounting.current(), 0)
    }

    func testOnlyOutstandingChildrenContributeToLimit() {
        let accounting = GuiChildAccounting()
        let limit = MailController.maxUnreapedGuiChildren
        let children = (0..<limit).map { _ in accounting.trackChild() }
        children.forEach { $0.markUnreaped() }
        XCTAssertEqual(accounting.current(), limit)
        children[0].didExit()
        XCTAssertEqual(accounting.current(), limit - 1)
        children[0].didExit()
        children[0].markUnreaped()
        XCTAssertEqual(accounting.current(), limit - 1, "one child's duplicate exit must not uncount another")
        children.dropFirst().forEach { $0.didExit() }
        XCTAssertEqual(accounting.current(), 0)
    }

    func testLateRegistrationsCannotExhaustLimit() {
        let accounting = GuiChildAccounting()
        for _ in 0..<(MailController.maxUnreapedGuiChildren * 2) {
            let child = accounting.trackChild()
            child.didExit()
            child.markUnreaped()
            XCTAssertEqual(accounting.current(), 0, "already-exited children cannot accumulate a false wedge")
        }
    }

    func testConcurrentRegistrationsAndExitsLeaveNoResidualCount() {
        let accounting = GuiChildAccounting()
        let children = (0..<500).map { _ in accounting.trackChild() }
        let queue = DispatchQueue(label: "test.child-accounting", attributes: .concurrent)
        let group = DispatchGroup()
        for child in children {
            queue.async(group: group) { child.markUnreaped() }
            queue.async(group: group) { child.didExit() }
            queue.async(group: group) { child.markUnreaped() }
            queue.async(group: group) { child.didExit() }
        }
        guard group.wait(timeout: .now() + 10) == .success else {
            XCTFail("lifecycle transitions must complete without deadlock")
            return
        }
        XCTAssertEqual(accounting.current(), 0)
    }
}

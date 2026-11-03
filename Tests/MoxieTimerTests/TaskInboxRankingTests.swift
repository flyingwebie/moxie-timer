import XCTest
@testable import MoxieTimer

@MainActor
final class TaskInboxRankingTests: XCTestCase {
    func testOverdueOutranksFarFutureDue() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var overdue = makeTask(id: "1", name: "Overdue")
        overdue.dueDate = MoxieTask.dayFormatter.string(from: now.addingTimeInterval(-86_400 * 3))
        var farFuture = makeTask(id: "2", name: "Far future")
        farFuture.dueDate = MoxieTask.dayFormatter.string(from: now.addingTimeInterval(86_400 * 30))

        let ranked = TaskInbox.ranked([farFuture, overdue], now: now)
        XCTAssertEqual(ranked.map(\.id), ["1", "2"])
    }

    func testFlaggedPredicateOutranksUnflagged() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let flagged = makeTask(id: "flagged", name: "Flagged")
        let normal = makeTask(id: "normal", name: "Normal")

        let ranked = TaskInbox.ranked([normal, flagged], now: now) { $0.id == "flagged" }
        XCTAssertEqual(ranked.map(\.id), ["flagged", "normal"])
    }

    func testTiesBreakByNameAscending() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let b = makeTask(id: "b", name: "Bravo")
        let a = makeTask(id: "a", name: "Alpha")

        let ranked = TaskInbox.ranked([b, a], now: now)
        XCTAssertEqual(ranked.map(\.name), ["Alpha", "Bravo"])
    }
}

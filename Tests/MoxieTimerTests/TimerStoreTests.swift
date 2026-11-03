import XCTest
@testable import MoxieTimer

@MainActor
final class TimerStoreTests: MoxieTestCase {
    func makeTimer(holdForReview: Bool = true) -> (TimerStore, HistoryStore, AppSettings) {
        let settings = makeSettings(holdForReview: holdForReview)
        let history = HistoryStore()
        let timer = TimerStore(settings: settings, history: history)
        return (timer, history, settings)
    }

    func testStartCreatesRunningSession() {
        let (timer, _, _) = makeTimer()
        XCTAssertNil(timer.session)
        timer.start()
        XCTAssertNotNil(timer.session)
        XCTAssertTrue(timer.session?.isRunning ?? false)
    }

    func testPauseAndResume() {
        let (timer, _, _) = makeTimer()
        timer.start()
        timer.pause()
        XCTAssertFalse(timer.session?.isRunning ?? true)
        timer.resume()
        XCTAssertTrue(timer.session?.isRunning ?? false)
    }

    func testPauseWhenNotRunningIsNoOp() {
        let (timer, _, _) = makeTimer()
        timer.start()
        timer.pause()
        let before = timer.session
        timer.pause()  // already paused
        XCTAssertEqual(timer.session, before)
    }

    func testAdjustAddsToElapsed() {
        let (timer, _, _) = makeTimer()
        timer.start()
        let before = timer.session!.elapsed(at: .now)
        timer.adjust(by: 120)
        let after = timer.session!.elapsed(at: .now)
        XCTAssertEqual(after - before, 120, accuracy: 0.5)
    }

    func testSetDurationOverridesElapsed() {
        let (timer, _, _) = makeTimer()
        timer.start()
        timer.setDuration(600)
        XCTAssertEqual(timer.session!.elapsed(at: .now), 600, accuracy: 0.5)
    }

    func testSetStartMovesStartKeepingEnd() {
        let (timer, _, _) = makeTimer()
        timer.start()
        let now = Date.now
        let newStart = now.addingTimeInterval(-3600)
        timer.setStart(newStart)
        XCTAssertEqual(timer.session!.start(at: now).timeIntervalSince(newStart), 0, accuracy: 1)
    }

    func testDiscardClearsSessionAndDraftNotesTicket() {
        let (timer, _, _) = makeTimer()
        timer.start()
        timer.draft.notes = "scratch"
        timer.draft.ticket = makeRef("Ticket A")
        timer.discard()
        XCTAssertNil(timer.session)
        XCTAssertEqual(timer.draft.notes, "")
        XCTAssertNil(timer.draft.ticket)
    }

    func testCanSaveCurrentReviewModeAlwaysTrue() {
        let (timer, _, _) = makeTimer(holdForReview: true)
        XCTAssertTrue(timer.canSaveCurrent)
    }

    func testCanSaveCurrentNonReviewRequiresClient() {
        let (timer, _, _) = makeTimer(holdForReview: false)
        XCTAssertFalse(timer.canSaveCurrent)
        timer.draft.client = makeRef("Acme")
        XCTAssertTrue(timer.canSaveCurrent)
    }

    /// Review mode: `stopAndSave` never hits the network, so this is safe without mocking `MoxieAPI`.
    func testStopAndSaveInReviewModeAddsPendingWholeSecondEntry() async {
        let (timer, history, _) = makeTimer(holdForReview: true)
        timer.draft.client = makeRef("Acme")
        timer.draft.notes = "working on it"
        timer.draft.ticket = makeRef("Ticket A")
        timer.start()
        timer.setDuration(90.7)  // fractional seconds should be dropped, not rounded

        await timer.stopAndSave()

        XCTAssertNil(timer.lastError)
        XCTAssertNil(timer.session)
        XCTAssertEqual(timer.draft.notes, "")
        XCTAssertNil(timer.draft.ticket)
        XCTAssertEqual(history.pending.count, 1)
        let saved = history.pending[0]
        XCTAssertTrue(saved.isPending)
        XCTAssertEqual(saved.start.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0)
        XCTAssertEqual(saved.end.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0)
    }

    /// Not in review mode and no client configured: the only path available (`log`/`send`) must throw
    /// `notConfigured` rather than touch the network, since settings have no API key in this test.
    func testStopAndSaveWithoutClientOrConfigSurfacesError() async {
        let (timer, _, _) = makeTimer(holdForReview: false)
        timer.start()
        timer.setDuration(60)

        await timer.stopAndSave()

        // No client → `send` throws `.missingClientOrProject` before ever touching the network.
        XCTAssertNotNil(timer.lastError)
        // The session is kept (paused) so nothing is lost.
        XCTAssertNotNil(timer.session)
    }

    func testHoldCurrentMovesTimeToHistoryWhenOverAMinute() {
        let (timer, history, _) = makeTimer()
        timer.draft.client = makeRef("Acme")
        timer.start()
        timer.setDuration(90)
        let held = timer.holdCurrent()
        XCTAssertEqual(held, 90, accuracy: 1)
        XCTAssertNil(timer.session)
        XCTAssertEqual(history.pending.count, 1)
    }

    func testHoldCurrentDropsSubMinuteTime() {
        let (timer, history, _) = makeTimer()
        timer.start()
        timer.setDuration(30)
        let held = timer.holdCurrent()
        XCTAssertEqual(held, 0)
        XCTAssertNil(timer.session)
        XCTAssertEqual(history.pending.count, 0)
    }

    func testStartAgainReusesDraftWithoutNotes() {
        let (timer, _, _) = makeTimer()
        let entry = LoggedEntry(id: "x", moxieId: nil, start: .now, end: .now.addingTimeInterval(60),
                                 draft: EntryDraft(client: makeRef("Acme"), notes: "old notes"), pending: nil)
        timer.startAgain(from: entry)
        XCTAssertNotNil(timer.session)
        XCTAssertEqual(timer.draft.client, makeRef("Acme"))
        XCTAssertEqual(timer.draft.notes, "")
    }

    func testAdoptPicksUpRemoteRunningTimer() {
        let (timer, _, _) = makeTimer()
        let remote = MoxieTimeEntry.fixture(timerStart: Date.now.addingTimeInterval(-300), pausedAt: nil, pausedSeconds: 0)
        timer.adopt(remote)
        XCTAssertNotNil(timer.session)
        XCTAssertTrue(timer.session?.isRunning ?? false)
        XCTAssertEqual(timer.session!.elapsed(at: .now), 300, accuracy: 2)
    }

    func testAdoptIgnoredWhenSessionAlreadyRunning() {
        let (timer, _, _) = makeTimer()
        timer.start()
        let before = timer.session
        let remote = MoxieTimeEntry.fixture(timerStart: Date.now.addingTimeInterval(-300), pausedAt: nil, pausedSeconds: 0)
        timer.adopt(remote)
        XCTAssertEqual(timer.session, before)
    }
}

extension MoxieTimeEntry {
    /// Builds a `MoxieTimeEntry` through JSON, since all its properties are `let` with no public init.
    static func fixture(timerStart: Date, pausedAt: Date?, pausedSeconds: Double?) -> MoxieTimeEntry {
        var dict: [String: Any] = [
            "timerStart": ISO8601DateFormatter().string(from: timerStart),
        ]
        if let pausedAt { dict["pausedAt"] = ISO8601DateFormatter().string(from: pausedAt) }
        if let pausedSeconds { dict["pausedSeconds"] = pausedSeconds }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(MoxieTimeEntry.self, from: data)
    }
}

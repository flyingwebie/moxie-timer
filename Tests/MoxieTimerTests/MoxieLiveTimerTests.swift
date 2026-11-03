import XCTest
@testable import MoxieTimer

/// `MoxieLiveTimer` talks to Moxie over the network for everything interesting (poll, start, stop…).
/// Without mocking `MoxieMCP`/`URLSession` (out of scope here — see the task brief's guidance to skip
/// anything that would need a heavier refactor), the only safe-to-exercise surface is the `isActive`
/// short-circuit every mirroring method starts with: not connected (no Keychain tokens, via the test
/// seam) and not stopping/active, so each call below returns before it would ever reach the network.
@MainActor
final class MoxieLiveTimerTests: MoxieTestCase {
    func makeLive() -> MoxieLiveTimer {
        MoxieLiveTimer(skipKeychainForTesting: true)
    }

    func testNotConnectedByDefaultWithTestSeam() {
        let live = makeLive()
        XCTAssertFalse(live.isActive)
    }

    func testStartedIsNoOpWhenNotActive() {
        let live = makeLive()
        live.started(EntryDraft())
        // No crash, no network task spun up, and nothing about connection state changed.
        XCTAssertFalse(live.isActive)
        XCTAssertNil(live.pendingRemote)
    }

    func testPausedResumedDiscardedAreNoOpsWhenNotActive() {
        let live = makeLive()
        live.paused()
        live.resumed()
        live.discarded()
        XCTAssertFalse(live.isActive)
    }

    func testStopReturnsNilWhenNotActive() async {
        let live = makeLive()
        let result = await live.stop(start: .now, end: .now.addingTimeInterval(60), draft: EntryDraft())
        XCTAssertNil(result)
    }

    func testPollIsNoOpWhenNotActive() {
        let live = makeLive()
        let timer = TimerStore(settings: makeSettings(), history: HistoryStore())
        live.timer = timer
        live.poll()
        // Nothing to assert beyond "didn't crash / didn't touch the network"; pendingRemote stays clear.
        XCTAssertNil(live.pendingRemote)
    }

    func testIgnoreAndDiscardPendingRemoteAreNoOpsWithNothingPending() {
        let live = makeLive()
        live.ignorePendingRemote()
        live.discardPendingRemote()
        XCTAssertNil(live.pendingRemote)
    }

    func testClearPendingOfferIsAlwaysSafe() {
        let live = makeLive()
        live.clearPendingOffer()
        XCTAssertNil(live.pendingRemote)
    }

    func testDisconnectResetsState() {
        let live = makeLive()
        live.disconnect()
        XCTAssertFalse(live.isConnected)
    }
}

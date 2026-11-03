import XCTest
@testable import MoxieTimer

@MainActor
final class FocusStoreTests: MoxieTestCase {
    struct Rig {
        let settings: AppSettings
        let history: HistoryStore
        let timer: TimerStore
        let catalog: Catalog
        let inbox: TaskInbox
        let stats: StatsStore
        let focus: FocusStore
    }

    func makeRig(holdForReview: Bool = true) -> Rig {
        let settings = makeSettings(holdForReview: holdForReview)
        let history = HistoryStore()
        let timer = TimerStore(settings: settings, history: history)
        let catalog = Catalog(settings: settings)
        let inbox = TaskInbox(settings: settings, catalog: catalog)
        let stats = StatsStore()
        let focus = FocusStore(timer: timer, inbox: inbox, stats: stats)
        return Rig(settings: settings, history: history, timer: timer, catalog: catalog, inbox: inbox, stats: stats, focus: focus)
    }

    // MARK: followTimer

    func testFollowTimerMirrorsTaskWhileRunning() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Write report")
        rig.timer.start()
        XCTAssertEqual(rig.focus.target?.taskId, "Write report")
        XCTAssertEqual(rig.focus.target?.clientName, "Acme")
    }

    func testFollowTimerMirrorsTicketNameWhenNoNotes() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.ticket = makeRef("Fix the thing")
        rig.timer.start()
        XCTAssertEqual(rig.focus.target?.name, "Fix the thing")
    }

    func testFollowTimerMirrorsNotesOverTicketName() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.ticket = makeRef("Fix the thing")
        rig.timer.draft.notes = "Investigating root cause"
        rig.timer.start()
        XCTAssertEqual(rig.focus.target?.name, "Investigating root cause")
    }

    func testFollowTimerFallsBackToProjectThenCurrentWork() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.project = makeRef("Website")
        rig.timer.start()
        XCTAssertEqual(rig.focus.target?.name, "Website")

        rig.timer.discard()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.project = nil  // discard() doesn't clear project/client; clear it to hit the final fallback
        rig.focus.clearTarget()
        rig.timer.start()
        XCTAssertEqual(rig.focus.target?.name, "Current work")
    }

    func testFollowTimerKeepsFirstStepAndDueForSameTask() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Write report", id: "task-1")
        rig.timer.start()
        rig.focus.target?.firstStep = "Outline"
        rig.focus.target?.due = "2099-01-01"

        // Draft changes but stays on the same task: firstStep/due must survive.
        rig.timer.draft.notes = "a note"
        XCTAssertEqual(rig.focus.target?.firstStep, "Outline")
        XCTAssertEqual(rig.focus.target?.due, "2099-01-01")
    }

    func testFollowTimerResetsFirstStepAndDueForDifferentTask() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Write report", id: "task-1")
        rig.timer.start()
        rig.focus.target?.firstStep = "Outline"

        rig.timer.draft.task = makeRef("Different task", id: "task-2")
        XCTAssertEqual(rig.focus.target?.taskId, "task-2")
        XCTAssertEqual(rig.focus.target?.firstStep, "")
    }

    func testFollowTimerDoesNothingWithNoSession() {
        let rig = makeRig()
        rig.focus.target = FocusTarget(name: "Pre-existing")
        rig.timer.draft.task = makeRef("Ignored", id: "ignored")
        // No session running: followTimer (called via timer.onChange on didSet) must not touch target.
        XCTAssertEqual(rig.focus.target?.name, "Pre-existing")
        XCTAssertNil(rig.focus.target?.taskId)
    }

    /// Reproduces the original bug: focused on task A, then the Timer tab's draft is pointed at ticket B
    /// and the timer started there — Focus must follow to B, not keep showing A.
    func testFollowTimerSwitchesWhenDraftChangesBeforeStart() {
        let rig = makeRig()
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Task A", id: "task-a")
        rig.timer.start()
        XCTAssertEqual(rig.focus.target?.taskId, "task-a")

        rig.timer.draft.task = nil
        rig.timer.draft.ticket = makeRef("Ticket B", id: "ticket-b")
        XCTAssertEqual(rig.focus.target?.ticketId, "ticket-b")
        XCTAssertNil(rig.focus.target?.taskId)
        XCTAssertEqual(rig.focus.target?.name, "Ticket B")
    }

    // MARK: select(_:) switching

    /// With a client set and review mode off, switching tries to send the previous time to Moxie right
    /// away (`stopAndSave` → `log` → `send`). Settings here have no API key, so `send` throws
    /// `.notConfigured` before ever touching the network — the documented way to exercise this path
    /// without mocking `MoxieAPI` (see HOW in the task brief). The switch itself must be aborted so the
    /// unsaved time isn't lost: target/draft stay on the old task.
    func testSelectTaskWithClientAndNoReviewSurfacesSaveErrorAndAbortsSwitch() async {
        let rig = makeRig(holdForReview: false)
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Old task", id: "old")
        rig.timer.start()
        rig.timer.setDuration(120)  // elapsed time, so `log` gets past its end > start check to the config check

        let newTask = makeTask(id: "new", name: "New task", client: makeRef("Beta"))
        await rig.focus.select(newTask)

        XCTAssertEqual(rig.focus.lastError, "Couldn't save the previous time: \(LogError.notConfigured.localizedDescription)")
        XCTAssertEqual(rig.history.pending.count, 0)  // never sent, never held: still sitting in the timer
        XCTAssertNotNil(rig.timer.session)
        XCTAssertEqual(rig.timer.draft.task?.id, "old", "switch must be aborted so the unsaved time isn't lost")
        XCTAssertEqual(rig.focus.target?.taskId, "old")
    }

    func testSelectTaskInReviewModeHoldsPreviousTime() async {
        let rig = makeRig(holdForReview: true)
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Old task", id: "old")
        rig.timer.start()
        rig.timer.setDuration(120)

        let newTask = makeTask(id: "new", name: "New task", client: makeRef("Beta"))
        await rig.focus.select(newTask)

        XCTAssertNil(rig.focus.lastError)
        XCTAssertTrue((rig.focus.banner ?? "").contains("Held"), "banner was: \(rig.focus.banner ?? "nil")")
        XCTAssertEqual(rig.history.pending.count, 1)
        XCTAssertTrue(rig.history.pending[0].isPending)
        XCTAssertEqual(rig.timer.draft.task?.id, "new")
        XCTAssertEqual(rig.focus.target?.taskId, "new")
    }

    func testSelectTaskNoClientRunningUnderTenMinutesCarriesOver() async {
        let rig = makeRig(holdForReview: false)
        // No client set: canSaveCurrent is false. Just started, so under the carry-over limit.
        rig.timer.start()
        rig.timer.setDuration(60)

        let newTask = makeTask(id: "new", name: "New task", client: makeRef("Beta"))
        await rig.focus.select(newTask)

        XCTAssertNil(rig.focus.lastError)
        XCTAssertEqual(rig.history.pending.count, 0)  // carried over, not held
        XCTAssertNotNil(rig.timer.session)  // the running time continued, under the new task
        XCTAssertEqual(rig.timer.draft.task?.id, "new")
        XCTAssertEqual(rig.focus.target?.taskId, "new")
    }

    func testSelectTaskNoClientPausedMovesToReview() async {
        let rig = makeRig(holdForReview: false)
        rig.timer.start()
        rig.timer.setDuration(120)
        rig.timer.pause()  // paused, no client: must go to Review regardless of age

        let newTask = makeTask(id: "new", name: "New task", client: makeRef("Beta"))
        await rig.focus.select(newTask)

        XCTAssertNil(rig.focus.lastError)
        XCTAssertEqual(rig.history.pending.count, 1)
        XCTAssertTrue((rig.focus.banner ?? "").contains("Review"), "banner was: \(rig.focus.banner ?? "nil")")
        XCTAssertEqual(rig.timer.draft.task?.id, "new")
        XCTAssertEqual(rig.focus.target?.taskId, "new")
    }

    func testSelectTaskNoClientOlderThanCarryOverLimitMovesToReview() async {
        let rig = makeRig(holdForReview: false)
        rig.timer.start()
        rig.timer.setDuration(FocusStore.carryOverLimit + 60)  // older than the carry-over window, still running

        let newTask = makeTask(id: "new", name: "New task", client: makeRef("Beta"))
        await rig.focus.select(newTask)

        XCTAssertNil(rig.focus.lastError)
        XCTAssertEqual(rig.history.pending.count, 1)
        XCTAssertEqual(rig.timer.draft.task?.id, "new")
    }

    // MARK: saveForLater / finish

    func testSaveForLaterKeepsTarget() async {
        let rig = makeRig(holdForReview: true)
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Task", id: "t1")
        rig.timer.start()
        rig.timer.setDuration(60)
        XCTAssertNotNil(rig.focus.target)

        await rig.focus.saveForLater()

        XCTAssertNil(rig.focus.lastError)
        XCTAssertNotNil(rig.focus.target, "saveForLater must keep the task as 'up next'")
        XCTAssertNil(rig.timer.session)
        XCTAssertEqual(rig.history.pending.count, 1)
    }

    func testFinishClearsTargetAndCountsTaskDone() async {
        let rig = makeRig(holdForReview: true)
        rig.timer.draft.client = makeRef("Acme")
        rig.timer.draft.task = makeRef("Task", id: "t1")
        rig.timer.start()
        rig.timer.setDuration(60)
        let before = rig.stats.day(.now).tasksDone

        await rig.focus.finish(closeInMoxie: false)

        XCTAssertNil(rig.focus.lastError)
        XCTAssertNil(rig.focus.target, "finish must clear the target")
        XCTAssertNil(rig.timer.session)
        XCTAssertEqual(rig.history.pending.count, 1)
        XCTAssertEqual(rig.stats.day(.now).tasksDone, before + 1)
    }
}

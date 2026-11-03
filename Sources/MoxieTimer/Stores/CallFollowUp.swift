import Foundation
import Observation

/// Once a call ends, offers one-click ways to pick back up: resume the task that was paused for the
/// call, and/or log the call's own time if nothing was tracking it. Builds the offer from what the
/// timer was doing when the call started and what it's doing now; never fires during the call itself.
@MainActor @Observable
final class CallFollowUp {
    struct Offer: Identifiable {
        let id = UUID()
        var taskName: String?
        var callStart: Date
        var callEnd: Date
        /// The paused task can be resumed with one click.
        var canResume: Bool
        /// The call's own time wasn't tracked by anything, so it's worth logging as an entry.
        var canLogCall: Bool
    }

    private(set) var offer: Offer?

    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private let ui: WidgetUI
    @ObservationIgnored private var callStart: Date?
    @ObservationIgnored private var pausedAtCallStart = false
    @ObservationIgnored private var draftAtCallStart: EntryDraft?
    @ObservationIgnored private var dismissTimer: Timer?

    /// Calls shorter than this aren't worth a follow-up.
    private static let minCallLength: TimeInterval = 60
    /// Auto-dismiss so a stale offer doesn't linger once the moment has passed.
    private static let autoDismissAfter: TimeInterval = 240

    init(timer: TimerStore, ui: WidgetUI) {
        self.timer = timer
        self.ui = ui
    }

    /// Call whenever `CallDetector.inCall` changes.
    func callStateChanged(inCall: Bool) {
        if inCall {
            callStart = .now
            draftAtCallStart = timer.session != nil ? timer.draft : nil
            pausedAtCallStart = timer.session?.isRunning == false
        } else {
            handleCallEnded()
        }
    }

    private func handleCallEnded() {
        defer { callStart = nil }
        guard let start = callStart else { return }
        let end = Date.now
        guard end.timeIntervalSince(start) >= Self.minCallLength else { return }

        let stillPaused = timer.session?.isRunning == false
        let sameTask = sameWork(timer.draft, draftAtCallStart)
        let canResume = draftAtCallStart != nil && stillPaused && sameTask

        // Approximation: if it was running when the call started and is still running (not paused) now,
        // treat the call as already tracked under that task — nothing more to offer.
        let trackedThroughout = draftAtCallStart != nil && !pausedAtCallStart && !stillPaused
        let canLogCall = !trackedThroughout

        guard canResume || canLogCall else { return }
        offer = Offer(taskName: draftAtCallStart?.task?.name ?? draftAtCallStart?.ticket?.name,
                       callStart: start, callEnd: end, canResume: canResume, canLogCall: canLogCall)
        scheduleAutoDismiss()
    }

    private func sameWork(_ a: EntryDraft, _ b: EntryDraft?) -> Bool {
        guard let b else { return false }
        return a.client?.id == b.client?.id && a.project?.id == b.project?.id && a.task?.id == b.task?.id && a.ticket?.id == b.ticket?.id
    }

    /// Resumes the task that was paused for the call.
    func resume() {
        timer.resume()
        dismiss()
    }

    /// Opens the manual entry editor, prefilled with the call's start/end.
    func logCall() {
        guard let offer else { return }
        ui.editorSeed = .init(start: offer.callStart, end: offer.callEnd)
        ui.expand(route: .addEntry)
        dismiss()
    }

    func dismiss() {
        offer = nil
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    private func scheduleAutoDismiss() {
        dismissTimer?.invalidate()
        let timer = Timer(timeInterval: Self.autoDismissAfter, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dismissTimer = timer
    }
}

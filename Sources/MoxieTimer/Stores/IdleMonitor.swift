import AppKit
import CoreGraphics
import Observation

/// Notices when you walk away (or the Mac sleeps) while the timer runs, and asks what to do with that time.
@MainActor @Observable
final class IdleMonitor {
    struct Away: Equatable {
        let start: Date
        let end: Date
        var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// Set when you come back; the widget shows Keep / Discard / Discard & pause.
    private(set) var pending: Away?

    var thresholdMinutes: Int {
        didSet { UserDefaults.standard.set(thresholdMinutes, forKey: "idleThresholdMinutes") }
    }

    @ObservationIgnored var onReturn: (() -> Void)?
    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private let focus: FocusStore
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init(timer: TimerStore, focus: FocusStore) {
        self.timer = timer
        self.focus = focus
        thresholdMinutes = UserDefaults.standard.object(forKey: "idleThresholdMinutes") as? Int ?? 5

        let poller = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller

        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.markAway(since: .now) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        })
    }

    /// Seconds since the last keyboard/mouse/trackpad event anywhere in the session. No permission needed.
    private var secondsIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// Set by the app: on a call you may not touch the keyboard for a long time, so that isn't "away".
    @ObservationIgnored var isInCall: () -> Bool = { false }
    @ObservationIgnored private var lastCallSeen: Date?

    private func poll() {
        guard thresholdMinutes > 0, pending == nil else { return }
        if isInCall() {
            awaySince = nil
            lastCallSeen = .now
            return
        }
        // Keyboard silence during a call isn't time away: only count idle time since the call ended.
        let sinceCall = lastCallSeen.map { Date.now.timeIntervalSince($0) } ?? .infinity
        let idle = min(secondsIdle, sinceCall)
        if awaySince == nil {
            if timer.session?.isRunning == true, idle >= TimeInterval(thresholdMinutes * 60) {
                markAway(since: Date.now.addingTimeInterval(-idle))
            }
        } else if idle < 5 {
            cameBack()
        }
    }

    private func markAway(since start: Date) {
        guard timer.session?.isRunning == true, awaySince == nil else { return }
        awaySince = start
    }

    private func cameBack() {
        guard let start = awaySince else { return }
        awaySince = nil
        let away = Away(start: start, end: .now)
        // Ignore short blips (e.g. a quick sleep/wake).
        guard away.duration >= 60, timer.session != nil else { return }
        pending = away
        NSSound(named: "Pop")?.play()
        onReturn?()
    }

    func keep() {
        pending = nil
    }

    func discard(andPause: Bool) {
        guard let away = pending else { return }
        pending = nil
        timer.adjust(by: -away.duration)
        focus.discardIdle(away.duration)
        if andPause {
            if focus.block?.isWorking == true { focus.pauseBlock() } else { timer.pause() }
        }
    }
}

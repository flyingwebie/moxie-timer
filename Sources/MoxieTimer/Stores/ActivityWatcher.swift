import AppKit
import CoreGraphics
import Observation
import UserNotifications

/// Watches what you're doing (frontmost app, idle time) to:
/// - learn and suggest client/projects from apps and window titles,
/// - nudge when you work without a timer: amber pill → notification (2 min) → centred prompt (5 min),
/// - prompt the end-of-day review.
@MainActor @Observable
final class ActivityWatcher {
    enum Nudge: Int, Comparable {
        case none, visual, notified, prompted
        static func < (a: Nudge, b: Nudge) -> Bool { a.rawValue < b.rawValue }
    }

    private(set) var nudge: Nudge = .none
    private(set) var suggestion: ContextLearner.Suggestion?
    private(set) var context: AppContext?
    /// When the current stretch of untracked work began.
    private(set) var untrackedSince: Date?

    @ObservationIgnored var onNotify: (() -> Void)?
    @ObservationIgnored var onPrompt: (() -> Void)?
    @ObservationIgnored var onDismissPrompt: (() -> Void)?
    @ObservationIgnored var onReviewDue: (() -> Void)?

    @ObservationIgnored let learner = ContextLearner()
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private let focus: FocusStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var snoozedUntil: Date?

    init(settings: AppSettings, timer: TimerStore, focus: FocusStore, history: HistoryStore) {
        self.settings = settings
        self.timer = timer
        self.focus = focus
        self.history = history
        let poller = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller
    }

    private var secondsIdle: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func poll() {
        let now = Date.now
        let idle = secondsIdle
        let tracking = timer.session?.isRunning == true

        if let current = AppContext.current(includeTitle: settings.useWindowTitles) {
            context = current
        }
        if tracking, idle < 60, let context, let client = timer.draft.client, let project = timer.draft.project {
            learner.learn(context, ProjectChoice(client: client, project: project))
        }
        suggestion = context.flatMap { learner.suggest(for: $0) }

        checkReview(now: now)
        checkTracking(now: now, idle: idle, tracking: tracking)
    }

    // MARK: Not-tracking reminder

    private func checkTracking(now: Date, idle: TimeInterval, tracking: Bool) {
        let onBreak: Bool = {
            guard let phase = focus.block?.phase else { return false }
            return phase == .breakDue || phase == .onBreak || phase == .breakOver
        }()
        let eligible = settings.trackingReminders && settings.isConfigured && settings.isWorkTime(now)
            && !tracking && !onBreak && (snoozedUntil ?? .distantPast) < now
        guard eligible, idle < 120 else {
            reset()
            return
        }
        if idle < 60, untrackedSince == nil {
            untrackedSince = now.addingTimeInterval(-min(idle, 10))
        }
        guard let since = untrackedSince else { return }
        let elapsed = now.timeIntervalSince(since)
        if elapsed >= 300, nudge < .prompted {
            nudge = .prompted
            onPrompt?()
        } else if elapsed >= 120, nudge < .notified {
            nudge = .notified
            onNotify?()
        } else if elapsed >= 60, nudge < .visual {
            nudge = .visual
        }
    }

    private func reset() {
        if nudge == .prompted { onDismissPrompt?() }
        if nudge >= .notified { Notifier.shared.clearNotTracking() }
        nudge = .none
        untrackedSince = nil
    }

    /// Starts the timer, back-dated to when the untracked work began, optionally with the suggested project.
    func startTracking(useSuggestion: Bool) {
        if useSuggestion, let suggestion {
            timer.draft.setClient(suggestion.choice.client)
            timer.draft.setProject(suggestion.choice.project)
        }
        let since = untrackedSince
        if timer.session == nil {
            timer.start()
            if let since { timer.adjust(by: Date.now.timeIntervalSince(since)) }
        } else {
            timer.resume()
        }
        reset()
    }

    func notWorking() {
        snoozedUntil = Date.now.addingTimeInterval(30 * 60)
        reset()
    }

    func remindLater() {
        snoozedUntil = Date.now.addingTimeInterval(10 * 60)
        reset()
    }

    func applySuggestion() {
        guard let suggestion else { return }
        timer.draft.setClient(suggestion.choice.client)
        timer.draft.setProject(suggestion.choice.project)
    }

    // MARK: End-of-day review

    private func checkReview(now: Date) {
        guard settings.holdForReview, !history.pending.isEmpty else { return }
        let calendar = Calendar.current
        let reviewAt = calendar.startOfDay(for: now).addingTimeInterval(TimeInterval(settings.reviewMinutes * 60))
        guard now >= reviewAt else { return }
        let today = calendar.startOfDay(for: now).timeIntervalSince1970
        guard UserDefaults.standard.double(forKey: "lastReviewPrompt") < today else { return }
        UserDefaults.standard.set(today, forKey: "lastReviewPrompt")
        onReviewDue?()
    }
}

/// macOS notifications for the not-tracking reminder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var onStart: (() -> Void)?
    var onNotWorking: (() -> Void)?
    var onOpen: (() -> Void)?

    private let notTrackingId = "not-tracking"
    private var center: UNUserNotificationCenter { .current() }
    /// UNUserNotificationCenter throws outside an .app bundle (e.g. `swift run`), so notifications are off there.
    private let isAvailable = Bundle.main.bundleURL.pathExtension == "app"

    func setUp() {
        guard isAvailable else { return }
        center.delegate = self
        let start = UNNotificationAction(identifier: "START", title: "Start timer")
        let notWorking = UNNotificationAction(identifier: "NOT_WORKING", title: "Not working")
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "TRACKING", actions: [start, notWorking], intentIdentifiers: []),
        ])
    }

    func requestAuthorization() {
        guard isAvailable else { return }
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postNotTracking(since: Date?, suggestion: String?) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "You're working without a timer"
        var body = since.map { "Since \($0.formatted(date: .omitted, time: .shortened))." } ?? ""
        if let suggestion { body += " Looks like \(suggestion)." }
        content.body = (body + " Start tracking so this time isn't lost.").trimmingCharacters(in: .whitespaces)
        content.sound = .default
        content.categoryIdentifier = "TRACKING"
        center.add(UNNotificationRequest(identifier: notTrackingId, content: content, trigger: nil))
    }

    func clearNotTracking() {
        guard isAvailable else { return }
        center.removeDeliveredNotifications(withIdentifiers: [notTrackingId])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        DispatchQueue.main.async {
            switch action {
            case "START": self.onStart?()
            case "NOT_WORKING": self.onNotWorking?()
            default: self.onOpen?()
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

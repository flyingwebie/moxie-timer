import AppKit
import Observation

/// Ticks once a second so every timer readout (widget + menu bar) stays live.
@MainActor @Observable
final class Clock {
    private(set) var now = Date()
    @ObservationIgnored private var timer: Timer?

    init() {
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.now = Date() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}

/// Which screen the expanded widget is showing.
@MainActor @Observable
final class WidgetUI {
    enum Tab { case focus, timer, recent }
    enum Route { case settings, addEntry, tasks, capture, review }

    /// How the entry editor should open: blank, prefilled with a time range (filling a gap), or editing a held entry.
    struct EditorSeed {
        var start: Date?
        var end: Date?
        var editId: String?
        var returnTo: Route?
    }

    private(set) var expanded = false
    var tab: Tab = .focus
    var route: Route?
    var editorSeed: EditorSeed?
    /// Set by the panel controller; shows/hides the floating widget.
    @ObservationIgnored var onVisibilityRequest: ((Bool) -> Void)?

    func expand(route: Route? = nil) {
        self.route = route
        expanded = true
        NSApp.activate()
        NSApp.windows.first { $0 is FloatingPanel }?.makeKey()
    }

    func collapse() {
        expanded = false
        route = nil
    }

    func toggle() {
        expanded ? collapse() : expand()
    }
}

@MainActor
final class AppModel {
    static let shared = AppModel()

    let settings: AppSettings
    let history: HistoryStore
    let stats = StatsStore()
    let catalog: Catalog
    let timer: TimerStore
    let ui = WidgetUI()
    let clock = Clock()
    let updater = Updater()
    let ai = AIService()
    let inbox: TaskInbox
    let focus: FocusStore
    let idle: IdleMonitor
    let activity: ActivityWatcher

    private init() {
        settings = AppSettings()
        history = HistoryStore()
        catalog = Catalog(settings: settings)
        timer = TimerStore(settings: settings, history: history)
        inbox = TaskInbox(settings: settings, catalog: catalog)
        focus = FocusStore(timer: timer, inbox: inbox, stats: stats)
        idle = IdleMonitor(timer: timer, focus: focus)
        activity = ActivityWatcher(settings: settings, timer: timer, focus: focus, history: history, stats: stats)
    }
}

import AppKit
import SwiftUI

@main
struct MoxieTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(delegate: appDelegate)
                .environment(model.timer)
                .environment(model.ui)
                .environment(model.updater)
                .environment(model.focus)
                .environment(model.history)
        } label: {
            MenuBarLabel()
                .environment(model.timer)
                .environment(model.clock)
                .environment(model.focus)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var panelController: PanelController?
    private var breakOverlay: BreakOverlayController?
    private var nudgePrompt: NudgePromptController?
    private var captureHotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated {
            let model = AppModel.shared
            let panel = PanelController(model: model)
            panelController = panel
            if !model.settings.isConfigured { model.ui.expand(route: .settings) }

            let overlay = BreakOverlayController(model: model)
            breakOverlay = overlay
            model.focus.onPhaseChange = { [weak overlay] in overlay?.sync() }
            overlay.sync()

            model.idle.onReturn = { [weak panel] in
                panel?.setVisible(true)
                model.ui.expand()
            }

            // Not-tracking reminder: amber pill → notification → centred prompt.
            let prompt = NudgePromptController(model: model)
            nudgePrompt = prompt
            let notifier = Notifier.shared
            notifier.setUp()
            if model.settings.trackingReminders { notifier.requestAuthorization() }
            notifier.onStart = { model.activity.startTracking(useSuggestion: model.activity.suggestion != nil) }
            notifier.onNotWorking = { model.activity.notWorking() }
            notifier.onOpen = { [weak panel] in
                panel?.setVisible(true)
                model.ui.tab = .timer
                model.ui.expand()
            }
            model.activity.onNotify = {
                notifier.postNotTracking(since: model.activity.untrackedSince, suggestion: model.activity.suggestion?.choice.label)
            }
            model.activity.onPrompt = { [weak prompt] in prompt?.show() }
            model.activity.onDismissPrompt = { [weak prompt] in prompt?.hide() }
            model.activity.onReviewDue = { [weak panel] in
                panel?.setVisible(true)
                model.ui.expand(route: .review)
                NSSound(named: "Purr")?.play()
            }

            captureHotKey = HotKey { [weak panel] in
                MainActor.assumeIsolated {
                    panel?.setVisible(true)
                    model.ui.expand(route: .capture)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.activity.learner.save() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { panelController?.setVisible(true) }
        return true
    }
}

private struct MenuBarLabel: View {
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock

    @Environment(FocusStore.self) private var focus

    var body: some View {
        if let block = focus.block, block.isWorking {
            let remaining = Int(block.remaining(at: clock.now).rounded(.up))
            Text("◎ " + String(format: "%d:%02d", remaining / 60, remaining % 60) + (block.pausedAt == nil ? "" : " ⏸"))
                .monospacedDigit()
        } else if let session = timer.session {
            Text(DurationFormat.clock(session.elapsed(at: clock.now)) + (session.isRunning ? "" : " ⏸"))
                .monospacedDigit()
        } else {
            Image(systemName: "stopwatch")
        }
    }
}

private struct MenuBarMenu: View {
    let delegate: AppDelegate
    @Environment(TimerStore.self) private var timer
    @Environment(WidgetUI.self) private var ui
    @Environment(Updater.self) private var updater
    @Environment(HistoryStore.self) private var history

    var body: some View {
        if !history.pending.isEmpty {
            Button("Review & Send (\(history.pending.count))…") {
                delegate.panelController?.setVisible(true)
                ui.expand(route: .review)
            }
            Divider()
        }
        if let release = updater.latest {
            Button("Install Update \(release.version)…") {
                delegate.panelController?.setVisible(true)
                ui.expand()
            }
            Divider()
        }
        if let session = timer.session {
            Button(session.isRunning ? "Pause" : "Resume") { timer.toggle() }
            Button("Stop & Save") {
                if !timer.canSaveCurrent {
                    delegate.panelController?.setVisible(true)
                    ui.tab = .timer
                    ui.expand()
                    timer.lastError = LogError.missingClientOrProject.localizedDescription
                } else {
                    Task { await timer.stopAndSave() }
                }
            }
            .disabled(timer.isSaving)
            Button("Discard Timer") { timer.discard() }
        } else {
            Button("Start Timer") { timer.start() }
        }
        Divider()
        Button("Capture Task…  (\(HotKey.captureDescription))") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .capture)
        }
        Button("Focus…") {
            delegate.panelController?.setVisible(true)
            ui.tab = .focus
            ui.expand()
        }
        Button("Add Time Entry…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .addEntry)
        }
        Button("Show / Hide Widget") {
            delegate.panelController?.setVisible(!(delegate.panelController?.isVisible ?? false))
        }
        Button("Reset Widget Position") {
            delegate.panelController?.setVisible(true)
            delegate.panelController?.resetPosition()
        }
        Button("Check for Updates…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .settings)
            Task { await updater.check(userInitiated: true) }
        }
        .disabled(updater.isBusy)
        Button("Settings…") {
            delegate.panelController?.setVisible(true)
            ui.expand(route: .settings)
        }
        Divider()
        Button("Quit Moxie Timer") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

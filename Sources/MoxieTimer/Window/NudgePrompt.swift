import AppKit
import SwiftUI

/// The last step of the not-tracking reminder: a small prompt in the middle of the screen.
@MainActor
final class NudgePromptController {
    private var panel: NSPanel?
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        guard panel == nil else { return }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .aqua)

        let root = NudgePromptView { [weak self] in self?.hide() }
            .environment(model.activity)
            .environment(model.ui)
            .environment(model.pet)
            .environment(model.settings)
            .environment(model.inbox)
            .environment(model.focus)
        let host = NSHostingView(rootView: root)
        panel.contentView = host
        self.panel = panel
        fit()
        panel.orderFrontRegardless()
        panel.makeKey()  // nonactivating, so this doesn't steal focus from whatever app you're in
        NSSound(named: "Ping")?.play()
        // The urgent list comes from the task inbox; refresh it if it's old and refit once it lands.
        Task {
            await model.inbox.refreshIfStale(mcp: model.live.isActive ? model.live.mcp : nil)
            fit()
        }
    }

    /// Sizes the panel to its content, centred a little above the middle of the screen.
    private func fit() {
        guard let panel, let host = panel.contentView else { return }
        let size = host.fittingSize
        guard let screen = NSScreen.main?.visibleFrame else { return }
        panel.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2 + screen.height * 0.12,
                              width: size.width, height: size.height), display: true)
    }

    func hide() {
        panel?.orderOut(nil)
        panel = nil
    }
}

struct NudgePromptView: View {
    @Environment(ActivityWatcher.self) private var activity
    @Environment(WidgetUI.self) private var ui
    @Environment(TaskInbox.self) private var inbox
    @Environment(FocusStore.self) private var focus
    let close: () -> Void
    /// Which urgent row Return would start; arrow keys move it.
    @State private var selectedUrgentIndex = 0

    var body: some View {
        Group {
            if activity.promptKind == .drift {
                driftContent
            } else {
                notTrackingContent
            }
        }
        .padding(20)
        .frame(width: 400)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.onBreak.opacity(0.5), lineWidth: 1.5))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
        .padding(30)
    }

    // MARK: Drifting to a distraction while the timer runs

    private var driftContent: some View {
        let minutes = max(1, Int((Date.now.timeIntervalSince(activity.driftSince ?? .now) / 60).rounded()))
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                PetView(size: 46, expression: .upset)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Back to “\(activity.currentTaskName)”?")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Text("You've been on \(activity.driftLabel ?? "something else") for \(minutes) min while the timer runs.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
            }

            Button {
                activity.backToWork(dropDrift: false)
                close()
            } label: { Text("Back to it").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)

            HStack(spacing: 8) {
                Button {
                    activity.backToWork(dropDrift: true)
                    close()
                } label: { Text("Back, drop \(minutes) min").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
                    .help("Return to work and remove the drifted time from the timer")
                Button {
                    activity.takeBreak()
                    close()
                } label: { Text("Take a break").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
            }

            HStack {
                Button("It's for work — allow 15 min") {
                    activity.allowForWork()
                    close()
                }
                Spacer()
                Button("Switch task") {
                    activity.allowForWork()
                    close()
                    ui.tab = .focus
                    ui.onVisibilityRequest?(true)
                    ui.expand(route: .tasks)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
        }
    }

    // MARK: Working with no timer running

    private var notTrackingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "stopwatch")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Theme.onBreak)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Working on something?")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Theme.ink)
                    if let since = activity.untrackedSince {
                        Text("You've been active since \(since.formatted(date: .omitted, time: .shortened)) with no timer running.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                    }
                }
            }

            urgentList

            if let suggestion = activity.suggestion {
                Button {
                    activity.startTracking(useSuggestion: true)
                    close()
                } label: {
                    VStack(spacing: 2) {
                        Text("Track \(suggestion.choice.label)").lineLimit(1)
                        Text("from \(activity.untrackedSince?.formatted(date: .omitted, time: .shortened) ?? "now") · \(suggestion.reason)")
                            .font(.system(size: 10, weight: .regular))
                            .opacity(0.8)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(PrimaryButtonStyle())
            }

            HStack(spacing: 8) {
                Button {
                    activity.startTracking(useSuggestion: false)
                    close()
                } label: { Text(activity.suggestion == nil ? "Start timer" : "Something else").frame(maxWidth: .infinity) }
                    .buttonStyle(activity.suggestion == nil ? AnyButtonStyle(PrimaryButtonStyle()) : AnyButtonStyle(ChipButtonStyle()))
                Button {
                    activity.startTracking(useSuggestion: false)
                    close()
                    ui.tab = .timer
                    ui.onVisibilityRequest?(true)
                    ui.expand()
                } label: { Text("Choose…").frame(maxWidth: .infinity) }
                    .buttonStyle(ChipButtonStyle())
            }

            HStack {
                Button("Remind me in 10 min") {
                    activity.remindLater()
                    close()
                }
                Spacer()
                Button("Not working right now") {
                    activity.notWorking()
                    close()
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Most urgent

extension NudgePromptView {
    /// The few most urgent open tasks/tickets (same ranking as Up next): one click starts a focus block on it.
    /// The first item is pre-selected; Return starts whichever is selected, arrow keys move the selection.
    @ViewBuilder var urgentList: some View {
        let items = Array(inbox.visibleTasks.prefix(4))
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CapsLabel("Most urgent")
                    Spacer()
                    if let since = activity.untrackedSince {
                        Text("tracks from \(since.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.faint)
                    }
                }
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, task in
                        UrgentRow(task: task, selected: index == selectedUrgentIndex) { start(task) }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream.opacity(0.7)))
                // Invisible default-action button: Return starts the selected row without a visible focus ring.
                Button("") {
                    guard items.indices.contains(selectedUrgentIndex) else { return }
                    start(items[selectedUrgentIndex])
                }
                .keyboardShortcut(.defaultAction)
                .frame(width: 0, height: 0)
                .opacity(0)
            }
            .onMoveCommand { direction in
                switch direction {
                case .up: selectedUrgentIndex = max(0, selectedUrgentIndex - 1)
                case .down: selectedUrgentIndex = min(items.count - 1, selectedUrgentIndex + 1)
                default: break
                }
            }
        }
    }

    /// Focus on the task, start the timer from when you became active, and run a focus block.
    private func start(_ task: MoxieTask) {
        close()
        Task {
            await focus.select(task)
            guard focus.target?.name == task.name else { return }  // switching failed; the error shows in Focus
            activity.startTracking(useSuggestion: false)
            focus.startFromTimer()
        }
    }
}

private struct UrgentRow: View {
    let task: MoxieTask
    var selected: Bool = false
    let action: () -> Void
    @State private var hovering = false

    private var highlighted: Bool { hovering || selected }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(highlighted ? .white : Theme.navy)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(highlighted ? Theme.navy : Theme.navy.opacity(0.08)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        KindBadge(isTicket: task.isTicket)
                        if let client = task.client?.name {
                            Text([client, task.project?.name].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.muted)
                                .lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 4)
                if let due = task.due { DueBadge(date: due) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(highlighted ? 1 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Theme.navy.opacity(0.35) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start a focus block on this now (Return starts the selected row)")
    }
}

/// Lets one button pick between two styles at runtime.
struct AnyButtonStyle: ButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        make(configuration)
    }
}

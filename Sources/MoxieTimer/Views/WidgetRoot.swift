import SwiftUI

struct WidgetRoot: View {
    /// Reports the content size so the panel can hug it.
    let onSize: (CGSize) -> Void
    @Environment(WidgetUI.self) private var ui

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            PillBar()
            if ui.expanded {
                ExpandedCard()
            }
        }
        // Room for the drop shadows inside the transparent window.
        .padding(EdgeInsets(top: 6, leading: 18, bottom: 22, trailing: 10))
        .fixedSize()
        .onGeometryChange(for: CGSize.self, of: \.size) { onSize($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }
}

/// The always-visible strip: `[+]  ( ● 0:00:08  ⏸  ■ )`
struct PillBar: View {
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui
    @Environment(Updater.self) private var updater

    var body: some View {
        HStack(spacing: 8) {
            if let release = updater.latest {
                Button { ui.expand() } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(.white, Theme.running)
                        .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                }
                .buttonStyle(.plain)
                .help("Moxie Timer \(release.version) is available")
            }

            Button { ui.expand(route: .addEntry) } label: {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.navy))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Add a time entry manually")

            HStack(spacing: 6) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 7, height: 7)
                    Text(timeText)
                        .font(.system(size: 14, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                }
                .padding(.leading, 12)
                .padding(.vertical, 6)
                .overlay(WindowDragArea { ui.toggle() })
                .help("Click to open, drag to move")

                if let session = timer.session {
                    pillButton(session.isRunning ? "pause.fill" : "play.fill", filled: false, help: session.isRunning ? "Pause" : "Resume") {
                        timer.toggle()
                    }
                    pillButton("stop.fill", filled: true, help: "Stop & save") {
                        if timer.draft.client == nil || timer.draft.project == nil {
                            ui.tab = .timer
                            ui.expand()
                            timer.lastError = LogError.missingClientOrProject.localizedDescription
                        } else {
                            Task { await timer.stopAndSave() }
                        }
                    }
                    .disabled(timer.isSaving)
                } else {
                    pillButton("play.fill", filled: true, help: "Start timer") { timer.start() }
                }
            }
            .padding(.trailing, 4)
            .frame(height: 36)
            .background(Capsule().fill(Theme.pill))
            .overlay(Capsule().strokeBorder(Theme.navy.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }

    private var timeText: String {
        guard let session = timer.session else { return "0:00:00" }
        return DurationFormat.clock(session.elapsed(at: clock.now))
    }

    private var dotColor: Color {
        guard let session = timer.session else { return Theme.faint }
        return session.isRunning ? Theme.running : Theme.muted
    }

    private func pillButton(_ systemName: String, filled: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(filled ? .white : Theme.ink)
                .frame(width: 28, height: 28)
                .background(Circle().fill(filled ? Theme.navy : .white))
                .overlay(Circle().strokeBorder(filled ? .clear : Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// The dropdown card under the pill.
struct ExpandedCard: View {
    @Environment(WidgetUI.self) private var ui
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if ui.route == .settings || !settings.isConfigured {
                SettingsView()
            } else if ui.route == .addEntry {
                ManualEntryView()
            } else {
                VStack(spacing: 0) {
                    UpdateBanner()
                    header
                    switch ui.tab {
                    case .timer: TimerTab()
                    case .recent: RecentTab()
                    }
                }
            }
        }
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(.white))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
        .onExitCommand { ui.collapse() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                tabButton("Timer", systemName: "stopwatch", tab: .timer)
                tabButton("Recent", systemName: "clock.arrow.circlepath", tab: .recent)
            }
            .padding(3)
            .fixedSize()
            .background(RoundedRectangle(cornerRadius: 11).fill(Theme.cream))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border))

            WindowDragArea()
                .frame(maxWidth: .infinity, minHeight: 30)

            headerIcon("gearshape", help: "Settings") { ui.route = .settings }
            headerIcon("chevron.up", help: "Collapse (Esc)") { ui.collapse() }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private func tabButton(_ title: String, systemName: String, tab: WidgetUI.Tab) -> some View {
        let selected = ui.tab == tab
        return Button { ui.tab = tab } label: {
            Label(title, systemImage: systemName)
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? Theme.ink : Theme.muted)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(RoundedRectangle(cornerRadius: 8).fill(selected ? .white : .clear)
                    .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func headerIcon(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

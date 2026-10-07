import AppKit
import SwiftUI

/// Full-screen break overlay shown on every display when a focus block ends.
@MainActor
final class BreakOverlayController {
    private var windows: [NSWindow] = []
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    func sync() {
        model.focus.needsOverlay ? show() : hide()
    }

    private func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = OverlayWindow(screen: screen)
            let root = BreakOverlayView()
                .environment(model.focus)
                .environment(model.clock)
                .environment(model.ui)
            window.contentView = NSHostingView(rootView: root)
            window.orderFrontRegardless()
            windows.append(window)
        }
        NSApp.activate()
        windows.first?.makeKey()
    }

    private func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { true }
}

private struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .fullScreenUI
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct BreakOverlayView: View {
    @Environment(FocusStore.self) private var focus
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui

    var body: some View {
        ZStack {
            BlurBackground().ignoresSafeArea()
            Color.black.opacity(0.35).ignoresSafeArea()

            if let block = focus.block {
                VStack(spacing: 22) {
                    content(block)
                }
                .padding(40)
                .frame(width: 520)
                .background(RoundedRectangle(cornerRadius: 28, style: .continuous).fill(.white.opacity(0.1)))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(.white.opacity(0.15)))
            }
        }
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func content(_ block: FocusBlock) -> some View {
        switch block.phase {
        case .breakDue:
            Text("🌿").font(.system(size: 54))
            Text("Time for a break").font(.system(size: 30, weight: .bold))
            Text("You focused for \(Int(block.length / 60)) minutes\(taskSuffix). Step away for \(Int(block.breakLength / 60)) — it keeps the next block sharp.")
                .font(.system(size: 15))
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.8))
            Button { focus.startBreak() } label: {
                Text("Start \(Int(block.breakLength / 60))-minute break").frame(width: 280)
            }
            .buttonStyle(OverlayButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            if !block.snoozed {
                Button { focus.snoozeBreak() } label: { Text("Snooze 5 minutes").frame(width: 280) }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
            } else {
                Text("Already snoozed once — time to rest.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
            }
            skipLink

        case .onBreak:
            Text("Break").font(.system(size: 18, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            Text(minutesSeconds(block.remaining(at: clock.now)))
                .font(.system(size: 72, weight: .bold).monospacedDigit())
            VStack(spacing: 6) {
                Text("Stand up · drink some water · look at something far away")
                Text("Your timer is paused.")
            }
            .font(.system(size: 14))
            .foregroundStyle(.white.opacity(0.75))
            Button("End break early") { focus.endBreakEarly() }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))

        case .breakOver:
            Text("☀️").font(.system(size: 54))
            Text("Break's over").font(.system(size: 30, weight: .bold))
            if let target = focus.target {
                VStack(spacing: 6) {
                    Text(target.name).font(.system(size: 17, weight: .semibold)).multilineTextAlignment(.center)
                    if !target.firstStep.isEmpty {
                        Text("Next: \(target.firstStep)").font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                    }
                }
            }
            Button { focus.backToWork() } label: {
                Text(focus.target == nil ? "Start a \(focus.suggestedMinutes)-minute block" : "Back to it · \(focus.suggestedMinutes) min")
                    .frame(width: 280)
            }
            .buttonStyle(OverlayButtonStyle(prominent: true))
            .keyboardShortcut(.defaultAction)
            HStack(spacing: 12) {
                Button { switchTask() } label: { Text("Switch task").frame(width: 134) }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
                Button { focus.doneForNow() } label: { Text("Done for now").frame(width: 134) }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
            }

        case .warmup, .focus:
            EmptyView()
        }
    }

    private var skipLink: some View {
        Button("Skip break (emergency)") { focus.skipBreak() }
            .buttonStyle(.plain)
            .font(.system(size: 11))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.top, 4)
    }

    private var taskSuffix: String {
        guard let name = focus.target?.name else { return "" }
        return " on “\(name)”"
    }

    private func switchTask() {
        focus.doneForNow()
        ui.tab = .focus
        ui.expand(route: .tasks)
    }

    private func minutesSeconds(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct OverlayButtonStyle: ButtonStyle {
    let prominent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(prominent ? Theme.navy : .white)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12).fill(prominent ? .white : .white.opacity(0.14)))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(Rectangle())
    }
}

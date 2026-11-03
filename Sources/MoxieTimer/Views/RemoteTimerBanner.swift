import SwiftUI

/// A timer found running in Moxie while nothing is running here. Offered, not auto-adopted:
/// "Keep here" adopts it, "Discard" deletes it from Moxie (permanent, confirmed), "Ignore" leaves it be.
struct RemoteTimerBanner: View {
    @Environment(MoxieLiveTimer.self) private var live
    @State private var confirmDiscard = false

    var body: some View {
        if let remote = live.pendingRemote {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "timer")
                        .foregroundStyle(Theme.navy)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Moxie has a timer running")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        Text("\(Self.workLabel(remote))\(startLabel(remote))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 6) {
                    Button("Keep here") { live.acceptPendingRemote() }
                        .buttonStyle(ChipButtonStyle())
                    Button("Discard") { confirmDiscard = true }
                        .buttonStyle(ChipButtonStyle())
                    Button("Ignore") { live.ignorePendingRemote() }
                        .buttonStyle(ChipButtonStyle())
                    Spacer(minLength: 0)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.07)))
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .confirmationDialog(
                "Discard Moxie's running timer?",
                isPresented: $confirmDiscard,
                titleVisibility: .visible
            ) {
                Button("Discard — this time is lost", role: .destructive) { live.discardPendingRemote() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This permanently deletes the \(elapsedLabel(remote)) running on \(Self.workLabel(remote)) in Moxie. It can't be recovered.")
            }
        }
    }

    private static func workLabel(_ remote: MoxieTimeEntry) -> String {
        remote.taskName ?? remote.ticketName ?? remote.projectName ?? remote.clientName ?? "something"
    }

    private func startLabel(_ remote: MoxieTimeEntry) -> String {
        guard let start = remote.start else { return "" }
        return " · started \(start.formatted(date: .omitted, time: .shortened))"
    }

    private func elapsedLabel(_ remote: MoxieTimeEntry) -> String {
        guard let start = remote.start else { return "time" }
        return DurationFormat.clock(Date.now.timeIntervalSince(start))
    }
}

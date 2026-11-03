import SwiftUI

/// Appears under the pill once a call ends: one click back to the task it interrupted, or to log the
/// call's own time if nothing was tracking it. Auto-dismisses after a few minutes.
struct CallEndedBanner: View {
    @Environment(CallFollowUp.self) private var followUp

    var body: some View {
        if let offer = followUp.offer {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "phone.down.fill")
                        .foregroundStyle(Theme.navy)
                    Text("Call ended")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: 0)
                    Button { followUp.dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    if offer.canResume, let name = offer.taskName {
                        Button("Back to \(name)") { followUp.resume() }
                            .buttonStyle(PrimaryButtonStyle())
                    }
                    if offer.canLogCall {
                        Button("Log the call (\(minutesLabel(offer)))") { followUp.logCall() }
                            .buttonStyle(ChipButtonStyle())
                    }
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.navy.opacity(0.25)))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }

    private func minutesLabel(_ offer: CallFollowUp.Offer) -> String {
        let minutes = max(1, Int((offer.callEnd.timeIntervalSince(offer.callStart) / 60).rounded()))
        return "\(minutes)m"
    }
}

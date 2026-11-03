import SwiftUI

/// "What I did" — an editable, private note offered after finishing work on a ticket. Nothing is sent
/// until "Post private note" is tapped; "Skip" just dismisses it. Always posts as an internal comment,
/// never a public (client-visible) one.
struct TicketNoteSheet: View {
    let draft: TicketNoteDraft
    @Environment(FocusStore.self) private var focus
    @Environment(MoxieLiveTimer.self) private var live

    @State private var text: String
    @State private var isPosting = false
    @State private var error: String?

    init(draft: TicketNoteDraft) {
        self.draft = draft
        _text = State(initialValue: draft.text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What I did").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text("Private note on “\(draft.ticketName)” — only your team sees it, never the client.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .frame(height: 100)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cream))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))

            if let error {
                ErrorBanner(message: error) { self.error = nil }
            }

            HStack {
                Button("Skip") { focus.skipTicketNote() }
                    .buttonStyle(ChipButtonStyle())
                Spacer()
                Button {
                    post()
                } label: {
                    HStack(spacing: 6) {
                        if isPosting { ProgressView().controlSize(.small).tint(.white) }
                        Text("Post private note")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isPosting || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 340)
    }

    private func post() {
        isPosting = true
        error = nil
        focus.pendingTicketNote?.text = text
        Task {
            await focus.postTicketNote(mcp: live.mcp)
            isPosting = false
            if let lastError = focus.lastError { error = lastError }
        }
    }
}

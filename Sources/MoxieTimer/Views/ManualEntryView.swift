import SwiftUI

/// "Add entry" form — logs a block of time without running the timer.
struct ManualEntryView: View {
    @Environment(TimerStore.self) private var timer
    @Environment(WidgetUI.self) private var ui

    @State private var draft = EntryDraft()
    @State private var start = Date.now.addingTimeInterval(-3600)
    @State private var end = Date.now
    @State private var durationText = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var didPrefill = false
    @FocusState private var durationFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { close() } label: {
                    Label("Add time entry", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
            }

            VStack(alignment: .leading, spacing: 12) {
                dateRow("Start", selection: $start)
                dateRow("End", selection: $end)
                VStack(alignment: .leading, spacing: 6) {
                    CapsLabel("Duration")
                    FieldBox {
                        TextField("1:00", text: $durationText)
                            .textFieldStyle(.plain)
                            .font(.system(size: 14).monospacedDigit())
                            .focused($durationFocused)
                            .onSubmit(applyDuration)
                            .onChange(of: durationFocused) { _, focused in if !focused { applyDuration() } }
                    }
                    .frame(width: 140)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))

            EntryFields(draft: $draft, labelled: true)

            if let error {
                ErrorBanner(message: error) { self.error = nil }
            }

            HStack {
                Button("Cancel") { close() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button(action: save) {
                    HStack(spacing: 8) {
                        if isSaving { ProgressView().controlSize(.small).tint(.white) } else { Image(systemName: "checkmark") }
                        Text(isSaving ? "Saving…" : "Save entry")
                    }
                    .frame(width: 160)
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(isSaving)
            }
        }
        .padding(16)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            draft = timer.draft.reusable
            let now = Date.now
            end = Calendar.current.date(bySetting: .second, value: 0, of: now) ?? now
            if end > now { end = end.addingTimeInterval(-60) }
            start = end.addingTimeInterval(-3600)
            syncDuration()
        }
        .onChange(of: start) { syncDuration() }
        .onChange(of: end) { syncDuration() }
    }

    private func dateRow(_ label: String, selection: Binding<Date>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(label)
            FieldBox {
                DatePicker(label, selection: selection, displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .datePickerStyle(.field)
            }
        }
    }

    private func syncDuration() {
        guard !durationFocused else { return }
        durationText = DurationFormat.clock(end.timeIntervalSince(start))
    }

    private func applyDuration() {
        if let value = DurationFormat.parse(durationText), value > 0 {
            end = start.addingTimeInterval(value)
        }
        durationText = DurationFormat.clock(end.timeIntervalSince(start))
    }

    private func save() {
        error = nil
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                _ = try await timer.log(start: start, end: end, draft: draft)
                ui.tab = .recent
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close() {
        ui.route = nil
    }
}

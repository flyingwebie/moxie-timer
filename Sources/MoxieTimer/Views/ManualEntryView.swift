import SwiftUI

/// "Add entry" form — logs a block of time without running the timer.
struct ManualEntryView: View {
    @Environment(TimerStore.self) private var timer
    @Environment(HistoryStore.self) private var history
    @Environment(WidgetUI.self) private var ui

    @State private var editing: LoggedEntry?
    @State private var returnTo: WidgetUI.Route?

    @State private var draft = EntryDraft()
    @State private var start = Date.now.addingTimeInterval(-3600)
    @State private var end = Date.now
    @State private var durationText = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var didPrefill = false
    @State private var confirmingDelete = false
    @FocusState private var durationFocused: Bool

    /// True once `editing` is a sent entry (local copy or one found only in Moxie) that can be edited or
    /// deleted directly in Moxie through MCP.
    private var editingIsRemote: Bool { editing?.moxieId != nil && AppModel.shared.live.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { close() } label: {
                    Label(editing == nil ? "Add time entry" : "Edit held entry", systemImage: "chevron.left")
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

            if editingIsRemote {
                Text("This entry is sent to Moxie. Changes save there too; an already-invoiced entry can't be changed.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.muted)
            }

            HStack {
                if let editing {
                    Button(role: .destructive) {
                        if editing.moxieId != nil { confirmingDelete = true } else {
                            history.remove(editing)
                            close()
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.danger)
                } else {
                    Button("Cancel") { close() }
                        .buttonStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
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
            let seed = ui.editorSeed
            ui.editorSeed = nil
            returnTo = seed?.returnTo
            if let id = seed?.editId, let entry = resolveEntry(id) {
                editing = entry
                draft = entry.draft
                start = entry.start
                end = entry.end
            } else {
                draft = timer.draft.reusable
                let now = Date.now
                end = seed?.end ?? (Calendar.current.date(bySetting: .second, value: 0, of: now) ?? now)
                if seed?.end == nil, end > now { end = end.addingTimeInterval(-60) }
                start = seed?.start ?? end.addingTimeInterval(-3600)
            }
            syncDuration()
        }
        .onChange(of: start) { syncDuration() }
        .onChange(of: end) { syncDuration() }
        .confirmationDialog("Delete this entry in Moxie?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Task { await deleteRemote() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes it from Moxie. This can't be undone.")
        }
    }

    /// `id` is either a local history id, or a "moxie-…" id for an entry Recent found only in Moxie
    /// (via `MoxieEntriesCache`) and hasn't been logged here before.
    private func resolveEntry(_ id: String) -> LoggedEntry? {
        if let entry = history.entries.first(where: { $0.id == id }) { return entry }
        guard let moxieId = id.hasPrefix("moxie-") ? String(id.dropFirst("moxie-".count)) : nil,
              let remote = MoxieEntriesCache.shared.entry(moxieId: moxieId) else { return nil }
        let start = remote.start ?? .now
        let end = remote.end ?? start.addingTimeInterval(remote.duration)
        return LoggedEntry(id: id, moxieId: remote.id, start: start, end: end, draft: remote.draft, moxieBillable: remote.billable, pending: nil)
    }

    private func deleteRemote() async {
        guard let editing else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await MoxieEntryEditing.delete(editing, history: history)
            close()
        } catch {
            self.error = error.localizedDescription
        }
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
                guard end > start else { throw LogError.invalidRange }
                if let editing {
                    if editing.moxieId != nil {
                        try await MoxieEntryEditing.edit(editing, start: start, end: end, draft: draft, history: history)
                    } else {
                        var entry = editing
                        entry.start = start
                        entry.end = end
                        entry.draft = draft
                        entry.sendError = nil
                        history.update(entry)
                    }
                } else {
                    _ = try await timer.log(start: start, end: end, draft: draft)
                    if returnTo == nil { ui.tab = .recent }
                }
                close()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func close() {
        ui.route = returnTo
    }
}

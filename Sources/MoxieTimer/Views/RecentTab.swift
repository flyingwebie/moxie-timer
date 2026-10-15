import SwiftUI

struct RecentTab: View {
    @Environment(HistoryStore.self) private var history
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui
    /// The entry opened to show its details.
    @State private var openEntry: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                stat("Today", DurationFormat.short(history.total(today: clock.now)))
                stat("This week", DurationFormat.short(history.total(week: clock.now)))
                Button { ui.route = .addEntry } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "plus").font(.system(size: 14, weight: .medium))
                        Text("Add").font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.muted)
                    .frame(width: 58, height: 62)
                    .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Add a time entry manually")
            }

            WeekChart()

            if history.entries.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark").font(.system(size: 26)).foregroundStyle(Theme.faint)
                    Text("Entries you log from this widget show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(history.groupedByDay) { group in
                            Section {
                                ForEach(group.entries) { entry in
                                    EntryRow(entry: entry, canStart: timer.session == nil, isOpen: openEntry == entry.id, onToggle: {
                                        withAnimation(.easeOut(duration: 0.15)) { openEntry = openEntry == entry.id ? nil : entry.id }
                                    }, onReview: { ui.route = .review }) {
                                        timer.startAgain(from: entry)
                                        ui.tab = .timer
                                    } onRemove: {
                                        history.remove(entry)
                                    } onEdit: {
                                        ui.editorSeed = .init(editId: entry.id)
                                        ui.route = .addEntry
                                    }
                                }
                            } header: {
                                HStack {
                                    Text(group.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()).uppercased())
                                    Spacer()
                                    Text(DurationFormat.short(group.total).uppercased())
                                }
                                .font(.system(size: 11, weight: .bold))
                                .tracking(0.6)
                                .foregroundStyle(Theme.ink.opacity(0.75))
                                .padding(.vertical, 8)
                                .background(.white)
                            }
                        }
                    }
                }
                .frame(height: 340)
            }

            Text("Click an entry for its details. Shows entries logged from this Mac. Held entries can be edited in Review; the Moxie API can't edit entries once sent.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            CapsLabel(title)
            Text(value).font(.system(size: 20, weight: .bold)).foregroundStyle(Theme.ink)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }
}

private struct EntryRow: View {
    let entry: LoggedEntry
    let canStart: Bool
    let isOpen: Bool
    let onToggle: () -> Void
    let onReview: () -> Void
    let onStart: () -> Void
    let onRemove: () -> Void
    var onEdit: (() -> Void)? = nil

    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            summary
            if isOpen { details }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(isOpen ? Theme.cream : .clear).padding(.horizontal, -6))
        .contextMenu {
            Button("Start timer for this", action: onStart).disabled(!canStart)
            if entry.isPending, let onEdit {
                Button("Edit held entry…", action: onEdit)
            }
            Divider()
            Button("Remove from this list", role: .destructive, action: onRemove)
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            ClientAvatar(name: entry.draft.client?.name ?? "?", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.draft.client?.name ?? "No client yet")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .lineLimit(isOpen ? nil : 2)
            }
            Spacer(minLength: 6)
            if hovering && canStart && !isOpen {
                Button(action: onStart) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Theme.navy))
                }
                .buttonStyle(.plain)
                .help("Start a new timer for this")
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(DurationFormat.clock(entry.duration))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    if entry.isPending {
                        Text("NOT SENT")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(Theme.onBreak)
                    } else if !entry.isBillable {
                        Text("NON-BILLABLE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: onToggle)
        .help(isOpen ? "Click to close" : "Click for details")
    }

    /// Everything stored about the entry, with its actions.
    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            field("When", "\(entry.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · \(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end.formatted(date: .omitted, time: .shortened)) (\(DurationFormat.short(entry.duration)))")
            field("Client", entry.draft.client?.name ?? "None yet")
            if let project = entry.draft.project { field("Project", project.name) }
            if let task = entry.draft.task { field("Task", task.name) }
            if let ticket = entry.draft.ticket { field("Ticket", ticket.name) }
            let notes = entry.draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            field("Notes", notes.isEmpty ? "—" : notes)
            field("Billable", billableText)
            field("Status", statusText, color: entry.isPending || entry.sendError != nil ? Theme.onBreak : Theme.running)
            if let moxieId = entry.moxieId { field("Moxie ID", moxieId) }

            HStack(spacing: 6) {
                Button("Start timer", action: onStart).buttonStyle(ChipButtonStyle()).disabled(!canStart)
                if entry.isPending {
                    if let onEdit { Button("Edit", action: onEdit).buttonStyle(ChipButtonStyle()) }
                    Button("Review", action: onReview).buttonStyle(ChipButtonStyle())
                }
                if !notes.isEmpty {
                    Button("Copy notes") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes, forType: .string)
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                Spacer()
                Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.danger)
                    .help("Remove from this list (doesn't delete it in Moxie)")
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(.leading, 40)
        .padding(.bottom, 10)
    }

    private func field(_ label: String, _ value: String, color: Color = Theme.ink) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.4)
                .foregroundStyle(Theme.muted)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.system(size: 12))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var billableText: String {
        if let stored = entry.moxieBillable, stored != entry.draft.isBillable {
            return stored ? "Yes (Moxie made it billable)" : "No (asked for billable, Moxie stored non-billable)"
        }
        return entry.isBillable ? "Yes" : "No"
    }

    private var statusText: String {
        if let error = entry.sendError { return "Not sent: \(error)" }
        if entry.isPending { return "Held on this Mac for review" }
        return "Sent to Moxie"
    }

    private var detail: String {
        let primary = entry.draft.task?.name ?? entry.draft.project?.name ?? ""
        let notes = entry.draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? primary : (primary.isEmpty ? notes : "\(primary) · \(notes)")
    }
}

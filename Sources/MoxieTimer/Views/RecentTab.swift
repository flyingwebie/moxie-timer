import SwiftUI

struct RecentTab: View {
    @Environment(HistoryStore.self) private var history
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui
    /// The entry opened to show its details.
    @State private var openEntry: String?
    /// 0 = this week, -1 = last week, …
    @State private var weekOffset = 0
    /// Narrow the list to one day of the shown week (click a bar).
    @State private var selectedDay: Date?
    /// A sent entry (local or Moxie-only) the user asked to permanently delete in Moxie.
    @State private var deleteConfirmEntry: LoggedEntry?
    @State private var remoteActionError: String?

    private var live: MoxieLiveTimer { AppModel.shared.live }

    /// Entries Moxie knows about for this week that aren't logged locally, marked "from Moxie" below.
    private var remoteOnly: [LoggedEntry] {
        guard live.isActive else { return [] }
        let known = Set(history.entries.compactMap(\.moxieId))
        return MoxieEntriesCache.shared.reconciled(in: weekInterval, knownMoxieIds: known)
    }

    private struct DisplayRow: Identifiable {
        let entry: LoggedEntry
        let fromMoxie: Bool
        var id: String { entry.id }
    }

    private struct DisplayDay: Identifiable {
        let day: Date
        let rows: [DisplayRow]
        let total: TimeInterval
        var id: Date { day }
    }

    /// Local entries plus Moxie-only ones, grouped and sorted together, newest day first.
    private func displayGroups(in interval: DateInterval) -> [DisplayDay] {
        let calendar = Calendar.current
        var byDay: [Date: [DisplayRow]] = [:]
        for entry in history.entries(in: interval) {
            byDay[calendar.startOfDay(for: entry.start), default: []].append(DisplayRow(entry: entry, fromMoxie: false))
        }
        for entry in remoteOnly {
            byDay[calendar.startOfDay(for: entry.start), default: []].append(DisplayRow(entry: entry, fromMoxie: true))
        }
        return byDay.keys.sorted(by: >).map { day in
            let rows = byDay[day]!.sorted { $0.entry.start > $1.entry.start }
            return DisplayDay(day: day, rows: rows, total: rows.reduce(0) { $0 + $1.entry.duration })
        }
    }

    private var weekInterval: DateInterval {
        let calendar = Calendar.current
        let anchor = calendar.date(byAdding: .weekOfYear, value: weekOffset, to: clock.now) ?? clock.now
        return calendar.dateInterval(of: .weekOfYear, for: anchor) ?? DateInterval(start: anchor, duration: 7 * 86_400)
    }

    private var weekTitle: String {
        switch weekOffset {
        case 0: return "This week"
        case -1: return "Last week"
        default: return "\(-weekOffset) weeks ago"
        }
    }

    private var weekRange: String {
        let end = weekInterval.end.addingTimeInterval(-1)
        let start = weekInterval.start
        let sameMonth = Calendar.current.isDate(start, equalTo: end, toGranularity: .month)
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = sameMonth ? end.formatted(.dateTime.day()) : end.formatted(.dateTime.month(.abbreviated).day())
        return "\(startText) – \(endText)"
    }

    var body: some View {
        let interval = weekInterval
        let weekTotal = history.total(in: interval)
        let groups = displayGroups(in: interval).filter { group in
            selectedDay.map { Calendar.current.isDate(group.day, inSameDayAs: $0) } ?? true
        }
        let daysWithTime = Set(history.entries(in: interval).map { Calendar.current.startOfDay(for: $0.start) }).count

        VStack(alignment: .leading, spacing: 12) {
            weekNavigator

            HStack(spacing: 8) {
                if let day = selectedDay {
                    stat(day.formatted(.dateTime.weekday(.wide)), DurationFormat.short(groups.first?.total ?? 0))
                } else if weekOffset == 0 {
                    stat("Today", DurationFormat.short(history.total(today: clock.now)))
                } else {
                    stat("Daily average", DurationFormat.short(daysWithTime == 0 ? 0 : weekTotal / Double(daysWithTime)))
                }
                stat(weekTitle, DurationFormat.short(weekTotal))
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

            WeekChart(week: interval.start, title: weekTitle, selectedDay: $selectedDay)

            if groups.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "clock.badge.checkmark").font(.system(size: 26)).foregroundStyle(Theme.faint)
                    Text(history.entries.isEmpty
                         ? "Entries you log from this widget show up here."
                         : (selectedDay != nil ? "Nothing logged on this day." : "Nothing logged this week."))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 140)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    let entry = row.entry
                                    EntryRow(entry: entry, canStart: timer.session == nil, fromMoxie: row.fromMoxie,
                                             canEditRemote: live.isActive && entry.moxieId != nil,
                                             isOpen: openEntry == entry.id, onToggle: {
                                        withAnimation(.easeOut(duration: 0.15)) { openEntry = openEntry == entry.id ? nil : entry.id }
                                    }, onReview: { ui.route = .review }) {
                                        timer.startAgain(from: entry)
                                        ui.tab = .timer
                                    } onRemove: {
                                        history.remove(entry)
                                    } onEdit: {
                                        ui.editorSeed = .init(editId: entry.id)
                                        ui.route = .addEntry
                                    } onDeleteInMoxie: {
                                        deleteConfirmEntry = entry
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
                .frame(height: 300)
            }

            if let remoteActionError {
                ErrorBanner(message: remoteActionError) { self.remoteActionError = nil }
            }

            Text(live.isActive
                 ? "Click an entry for its details, or a day in the chart to show only that day. Entries marked “from Moxie” were logged elsewhere. Held entries can be edited in Review; a sent entry can be edited or deleted here while Moxie's live timer is on."
                 : "Click an entry for its details, or a day in the chart to show only that day. Shows entries logged from this Mac. Held entries can be edited in Review; the Moxie API can't edit entries once sent.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .task(id: interval) { await MoxieEntriesCache.shared.refresh(interval) }
        .confirmationDialog("Delete this entry in Moxie?", isPresented: .init(get: { deleteConfirmEntry != nil }, set: { if !$0 { deleteConfirmEntry = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let entry = deleteConfirmEntry else { return }
                deleteConfirmEntry = nil
                Task { await deleteInMoxie(entry) }
            }
            Button("Cancel", role: .cancel) { deleteConfirmEntry = nil }
        } message: {
            Text("This permanently removes it from Moxie. This can't be undone.")
        }
    }

    private func deleteInMoxie(_ entry: LoggedEntry) async {
        do {
            try await MoxieEntryEditing.delete(entry, history: history)
        } catch {
            remoteActionError = error.localizedDescription
        }
    }

    private var weekNavigator: some View {
        HStack(spacing: 6) {
            navButton("chevron.left", help: "Previous week") { shiftWeek(-1) }
            VStack(alignment: .leading, spacing: 0) {
                Text(weekTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(weekRange)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            .frame(minWidth: 110, alignment: .leading)
            navButton("chevron.right", help: "Next week") { shiftWeek(1) }
                .disabled(weekOffset >= 0)
                .opacity(weekOffset >= 0 ? 0.35 : 1)
            Spacer()
            if let day = selectedDay {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selectedDay = nil }
                } label: {
                    HStack(spacing: 4) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated).day()))
                        Image(systemName: "xmark").font(.system(size: 8, weight: .heavy))
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .help("Show the whole week")
            }
            if weekOffset != 0 {
                Button("This week") { shiftWeek(-weekOffset) }
                    .buttonStyle(ChipButtonStyle())
            }
        }
    }

    private func navButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.cream))
                .overlay(Circle().strokeBorder(Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func shiftWeek(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            weekOffset = min(0, weekOffset + delta)
            selectedDay = nil
            openEntry = nil
        }
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
    /// Logged elsewhere (web app, another Mac, an AI assistant) — not in this Mac's local history.
    var fromMoxie: Bool = false
    /// Moxie's live timer is on and this entry has a `moxieId`, so it can be edited/deleted in Moxie.
    var canEditRemote: Bool = false
    let isOpen: Bool
    let onToggle: () -> Void
    let onReview: () -> Void
    let onStart: () -> Void
    let onRemove: () -> Void
    var onEdit: (() -> Void)? = nil
    var onDeleteInMoxie: (() -> Void)? = nil

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
            } else if canEditRemote, let onEdit {
                Button("Edit in Moxie…", action: onEdit)
            }
            if canEditRemote, let onDeleteInMoxie {
                Button("Delete in Moxie…", role: .destructive, action: onDeleteInMoxie)
            }
            if !fromMoxie {
                Divider()
                Button("Remove from this list", role: .destructive, action: onRemove)
            }
        }
    }

    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            ClientAvatar(name: entry.draft.client?.name ?? "?", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(entry.draft.client?.name ?? "No client yet")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    if fromMoxie {
                        Text("FROM MOXIE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.3)
                            .foregroundStyle(Theme.navy)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(Capsule().fill(Theme.navy.opacity(0.1)))
                    }
                }
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
                } else if canEditRemote, let onEdit {
                    Button("Edit", action: onEdit).buttonStyle(ChipButtonStyle())
                        .help("Edit this entry in Moxie. Already-invoiced entries can't be changed.")
                }
                if !notes.isEmpty {
                    Button("Copy notes") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(notes, forType: .string)
                    }
                    .buttonStyle(ChipButtonStyle())
                }
                Spacer()
                if canEditRemote, let onDeleteInMoxie {
                    Button(role: .destructive, action: onDeleteInMoxie) { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.danger)
                        .help("Permanently delete this entry in Moxie. Can't be undone.")
                } else if !fromMoxie {
                    Button(role: .destructive, action: onRemove) { Image(systemName: "trash") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.danger)
                        .help("Remove from this list (doesn't delete it in Moxie)")
                }
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

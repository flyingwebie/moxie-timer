import SwiftUI

struct RecentTab: View {
    @Environment(HistoryStore.self) private var history
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui

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
                                    EntryRow(entry: entry, canStart: timer.session == nil) {
                                        timer.startAgain(from: entry)
                                        ui.tab = .timer
                                    } onRemove: {
                                        history.remove(entry)
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
                .frame(height: 380)
            }

            Text("Shows entries logged from this Mac. The Moxie API can't list or edit existing time entries.")
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
    let onStart: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ClientAvatar(name: entry.draft.client?.name ?? "?", size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.draft.client?.name ?? "Unknown client")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink.opacity(0.7))
                    .lineLimit(2)
            }
            Spacer(minLength: 6)
            if hovering && canStart {
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
                Text(DurationFormat.clock(entry.duration))
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .padding(.top, 6)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help("\(entry.start.formatted(date: .omitted, time: .shortened)) – \(entry.end.formatted(date: .omitted, time: .shortened))")
        .contextMenu {
            Button("Start timer for this", action: onStart).disabled(!canStart)
            Divider()
            Button("Remove from this list", role: .destructive, action: onRemove)
        }
    }

    private var detail: String {
        let primary = entry.draft.task?.name ?? entry.draft.project?.name ?? ""
        let notes = entry.draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? primary : (primary.isEmpty ? notes : "\(primary) · \(notes)")
    }
}

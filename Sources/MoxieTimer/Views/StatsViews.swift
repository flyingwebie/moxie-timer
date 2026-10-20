import SwiftUI

/// "Today: 2 blocks · 1h 10m focus · 3 done · 🔥 4 days" — small, visible wins.
struct TodayStrip: View {
    @Environment(StatsStore.self) private var stats
    @Environment(HistoryStore.self) private var history
    @Environment(Clock.self) private var clock

    var body: some View {
        let today = stats.day(clock.now)
        let streak = stats.streak(now: clock.now)
        let tracked = history.total(today: clock.now)
        HStack(spacing: 6) {
            chip("\(today.blocksCompleted)", today.blocksCompleted == 1 ? "block" : "blocks", icon: "scope")
            chip(DurationFormat.short(today.focusSeconds), "focus", icon: "timer")
            chip("\(today.tasksDone)", "done", icon: "checkmark.circle")
            if streak > 0 {
                chip("\(streak)", streak == 1 ? "day" : "days", icon: "flame.fill", tint: Theme.onBreak)
            }
            Spacer(minLength: 0)
        }
        .help("Today: \(DurationFormat.short(tracked)) tracked · \(today.drifts) drifts caught · came back \(today.cameBack)×")
    }

    private func chip(_ value: String, _ label: String, icon: String, tint: Color = Theme.navy) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
            Text(value).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
            Text(label).font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(tint.opacity(0.07)))
    }
}

/// Tracked time per day for one week, with the focus part highlighted. Click a day to select it.
struct WeekChart: View {
    @Environment(StatsStore.self) private var stats
    @Environment(HistoryStore.self) private var history
    @Environment(Clock.self) private var clock
    /// Any date inside the week to show.
    var week: Date? = nil
    var title = "This week"
    var selectedDay: Binding<Date?>? = nil
    @State private var hovered: Date?

    private struct Bar: Identifiable {
        let date: Date
        let tracked: TimeInterval
        let focus: TimeInterval
        var id: Date { date }
    }

    var body: some View {
        let bars = weekBars()
        let maxValue = max(bars.map { max($0.tracked, $0.focus) }.max() ?? 0, 3600)
        let selected = selectedDay?.wrappedValue
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CapsLabel(title)
                Spacer()
                HStack(spacing: 8) {
                    legend(Theme.navy.opacity(0.25), "tracked")
                    legend(Theme.running, "focus")
                }
            }
            // Details for the hovered (or selected) day, or the week's total.
            Group {
                if let day = hovered ?? selected, let bar = bars.first(where: { $0.date == day }) {
                    Text("\(bar.date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))): ")
                        .foregroundStyle(Theme.ink)
                    + Text("\(DurationFormat.short(bar.tracked)) tracked").foregroundStyle(Theme.navy).bold()
                    + Text(" · ").foregroundStyle(Theme.muted)
                    + Text("\(DurationFormat.short(bar.focus)) focus").foregroundStyle(Theme.running).bold()
                } else {
                    Text("Week: \(DurationFormat.short(bars.reduce(0) { $0 + $1.tracked })) tracked · \(DurationFormat.short(bars.reduce(0) { $0 + $1.focus })) focus\(selectedDay == nil ? " — hover a day" : " — click a day to filter")")
                        .foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(bars) { bar in
                    let isToday = Calendar.current.isDate(bar.date, inSameDayAs: clock.now)
                    let isHovered = hovered == bar.date
                    let isSelected = selected == bar.date
                    let dimmed = selected != nil && !isSelected
                    VStack(spacing: 4) {
                        Text(bar.tracked > 0 ? DurationFormat.short(bar.tracked) : "")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.ink)
                            .opacity(isHovered || isSelected ? 1 : 0)
                            .frame(height: 11)
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.navy.opacity(isHovered || isSelected ? 0.5 : (isToday ? 0.35 : 0.2)))
                                .frame(height: max(2, 60 * bar.tracked / maxValue))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.running)
                                .frame(height: bar.focus > 0 ? max(2, 60 * min(bar.focus, maxValue) / maxValue) : 0)
                                .padding(.horizontal, 6)
                        }
                        .frame(height: 60, alignment: .bottom)
                        .opacity(dimmed ? 0.45 : 1)
                        Text(bar.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 10, weight: isToday || isSelected ? .bold : .regular))
                            .foregroundStyle(isSelected ? .white : (isToday ? Theme.ink : Theme.muted))
                            .frame(width: 18, height: 16)
                            .background(Circle().fill(isSelected ? Theme.navy : .clear))
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = bar.date } else if hovered == bar.date { hovered = nil }
                    }
                    .onTapGesture {
                        guard let selectedDay else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedDay.wrappedValue = isSelected ? nil : bar.date
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 9)).foregroundStyle(Theme.muted)
        }
    }

    private func weekBars() -> [Bar] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: week ?? clock.now) else { return [] }
        let entries = history.entries(in: interval)
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
            let tracked = entries.filter { calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.duration }
            return Bar(date: day, tracked: tracked, focus: stats.day(day).focusSeconds)
        }
    }
}

/// One-line recap for the end-of-day review.
struct DayRecap: View {
    @Environment(StatsStore.self) private var stats
    @Environment(HistoryStore.self) private var history
    @Environment(Clock.self) private var clock

    var body: some View {
        let today = stats.day(clock.now)
        let tracked = history.total(today: clock.now)
        let streak = stats.streak(now: clock.now)
        var parts = ["\(DurationFormat.short(tracked)) tracked"]
        if today.blocksCompleted > 0 { parts.append("\(today.blocksCompleted) focus block\(today.blocksCompleted == 1 ? "" : "s")") }
        if today.tasksDone > 0 { parts.append("\(today.tasksDone) done") }
        if today.cameBack > 0 { parts.append("came back from \(today.cameBack) drift\(today.cameBack == 1 ? "" : "s")") }
        return HStack(alignment: .top, spacing: 8) {
            Text(streak >= 2 ? "🔥" : "✨")
            VStack(alignment: .leading, spacing: 2) {
                Text("Today: " + parts.joined(separator: " · "))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if streak >= 2 {
                    Text("\(streak)-day focus streak — keep it going tomorrow.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.running.opacity(0.1)))
    }
}

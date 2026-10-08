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

/// Tracked time per day this week, with the focus part highlighted.
struct WeekChart: View {
    @Environment(StatsStore.self) private var stats
    @Environment(HistoryStore.self) private var history
    @Environment(Clock.self) private var clock

    private struct Bar: Identifiable {
        let date: Date
        let tracked: TimeInterval
        let focus: TimeInterval
        var id: Date { date }
    }

    var body: some View {
        let bars = weekBars()
        let maxValue = max(bars.map { max($0.tracked, $0.focus) }.max() ?? 0, 3600)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CapsLabel("This week")
                Spacer()
                HStack(spacing: 8) {
                    legend(Theme.navy.opacity(0.25), "tracked")
                    legend(Theme.running, "focus")
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(bars) { bar in
                    let isToday = Calendar.current.isDate(bar.date, inSameDayAs: clock.now)
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.navy.opacity(isToday ? 0.35 : 0.2))
                                .frame(height: max(2, 60 * bar.tracked / maxValue))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.running)
                                .frame(height: bar.focus > 0 ? max(2, 60 * min(bar.focus, maxValue) / maxValue) : 0)
                                .padding(.horizontal, 6)
                        }
                        .frame(height: 60, alignment: .bottom)
                        Text(bar.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 10, weight: isToday ? .bold : .regular))
                            .foregroundStyle(isToday ? Theme.ink : Theme.muted)
                    }
                    .frame(maxWidth: .infinity)
                    .help("\(bar.date.formatted(.dateTime.weekday(.wide))): \(DurationFormat.short(bar.tracked)) tracked, \(DurationFormat.short(bar.focus)) focus")
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
        guard let week = calendar.dateInterval(of: .weekOfYear, for: clock.now) else { return [] }
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: week.start) else { return nil }
            let tracked = history.entries.filter { calendar.isDate($0.start, inSameDayAs: day) }.reduce(0) { $0 + $1.duration }
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

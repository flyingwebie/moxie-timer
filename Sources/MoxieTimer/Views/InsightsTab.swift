import SwiftUI

/// Wins, hours and where the time went, for a week, month or year — all from what this Mac logged.
struct InsightsTab: View {
    @Environment(HistoryStore.self) private var history
    @Environment(StatsStore.self) private var stats
    @Environment(Clock.self) private var clock

    enum Period: String, CaseIterable, Identifiable {
        case week = "Week", month = "Month", year = "Year"
        var id: String { rawValue }
        var component: Calendar.Component {
            switch self {
            case .week: return .weekOfYear
            case .month: return .month
            case .year: return .year
            }
        }
    }

    @State private var period: Period = .week
    @State private var offset = 0
    @State private var hoveredBucket: Date?
    @State private var openClient: String?

    var body: some View {
        let current = InsightsData(interval: interval(offset), period: period, history: history, stats: stats, now: clock.now)
        let previous = InsightsData(interval: comparisonInterval, period: period, history: history, stats: stats, now: clock.now)

        VStack(alignment: .leading, spacing: 12) {
            controls
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    kpis(current, previous)
                    if current.tracked == 0 && current.focus == 0 {
                        emptyState
                    } else {
                        rhythmChart(current)
                        wins(current)
                        clients(current)
                        hours(current)
                    }
                    Text("Built from entries logged from this Mac and your focus blocks. Time logged elsewhere in Moxie isn't included.")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 4)
            }
            .frame(height: 470)
        }
        .padding(16)
    }

    // MARK: Period

    private func interval(_ offset: Int) -> DateInterval {
        let calendar = Calendar.current
        let anchor = calendar.date(byAdding: period.component, value: offset, to: clock.now) ?? clock.now
        return calendar.dateInterval(of: period.component, for: anchor) ?? DateInterval(start: anchor, duration: 86_400)
    }

    /// The previous period; while the current one is still running, only up to the same point
    /// (Tuesday afternoon vs last Tuesday afternoon), so the comparison is fair.
    private var comparisonInterval: DateInterval {
        let previous = interval(offset - 1)
        guard offset == 0 else { return previous }
        let elapsed = clock.now.timeIntervalSince(interval(0).start)
        return DateInterval(start: previous.start, duration: min(max(elapsed, 1), previous.duration))
    }

    private var periodTitle: String {
        let range = interval(offset)
        switch period {
        case .week:
            if offset == 0 { return "This week" }
            if offset == -1 { return "Last week" }
            let end = range.end.addingTimeInterval(-1)
            return "\(range.start.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day()))"
        case .month:
            return offset == 0 ? "This month" : range.start.formatted(.dateTime.month(.wide).year())
        case .year:
            return offset == 0 ? "This year" : range.start.formatted(.dateTime.year())
        }
    }

    private var previousLabel: String {
        let unit = period.rawValue.lowercased()
        return offset == 0 ? "this time last \(unit)" : "the \(unit) before"
    }

    private var controls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(Period.allCases) { item in
                    let selected = item == period
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            period = item
                            offset = 0
                            openClient = nil
                        }
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Theme.ink : Theme.muted)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? .white : .clear)
                                .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 2, y: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Theme.cream))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))

            Spacer()

            navButton("chevron.left", help: "Previous") { shift(-1) }
            Text(periodTitle)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .frame(minWidth: 96)
            navButton("chevron.right", help: "Next") { shift(1) }
                .disabled(offset >= 0)
                .opacity(offset >= 0 ? 0.35 : 1)
        }
    }

    private func shift(_ delta: Int) {
        withAnimation(.easeOut(duration: 0.15)) {
            offset = min(0, offset + delta)
            openClient = nil
        }
    }

    private func navButton(_ systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.ink.opacity(0.75))
                .frame(width: 24, height: 24)
                .background(Circle().fill(Theme.cream))
                .overlay(Circle().strokeBorder(Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: KPIs

    private func kpis(_ now: InsightsData, _ before: InsightsData) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        return LazyVGrid(columns: columns, spacing: 8) {
            kpi("Tracked", DurationFormat.short(now.tracked), icon: "clock.fill",
                detail: delta(now.tracked, before.tracked))
            kpi("Focus", DurationFormat.short(now.focus), icon: "scope",
                detail: now.tracked > 0 ? Text("\(percent(now.focus, of: now.tracked)) of tracked time") : Text("\(now.blocks) blocks finished"))
            kpi("Billable", now.tracked > 0 ? percent(now.billable, of: now.tracked) : "—", icon: "dollarsign.circle.fill",
                detail: Text("\(DurationFormat.short(now.billable)) billable"))
            kpi("Done", "\(now.tasksDone)", icon: "checkmark.circle.fill",
                detail: Text("tasks · \(now.blocks) focus block\(now.blocks == 1 ? "" : "s")"))
        }
    }

    private func delta(_ now: TimeInterval, _ before: TimeInterval) -> Text {
        guard before > 0 || now > 0 else { return Text("Nothing logged yet") }
        guard before > 0 else { return Text("Nothing \(previousLabel)") }
        let diff = now - before
        if abs(diff) < 60 { return Text("Same as \(previousLabel)") }
        let arrow = diff > 0 ? "▲" : "▼"
        return Text("\(arrow) \(DurationFormat.short(abs(diff)))").foregroundStyle(diff > 0 ? Theme.running : Theme.onBreak).bold()
            + Text(" vs \(previousLabel)")
    }

    private func percent(_ part: TimeInterval, of whole: TimeInterval) -> String {
        guard whole > 0 else { return "0%" }
        return "\(Int((part / whole * 100).rounded()))%"
    }

    private func kpi(_ title: String, _ value: String, icon: String, detail: Text) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.navy.opacity(0.7))
                CapsLabel(title)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.ink)
            detail
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.cream))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    // MARK: Hours per day / month

    private func rhythmChart(_ data: InsightsData) -> some View {
        let buckets = data.buckets
        let maxValue = max(buckets.map { max($0.tracked, $0.focus) }.max() ?? 0, period == .year ? 36_000 : 3_600)
        let height: CGFloat = 78
        let hovered = buckets.first { $0.date == hoveredBucket }
        let average = data.activeBuckets == 0 ? 0 : data.tracked / Double(data.activeBuckets)
        return card {
            HStack {
                CapsLabel(period == .year ? "Hours per month" : "Hours per day")
                Spacer()
                legend(Theme.navy.opacity(0.25), "tracked")
                legend(Theme.running, "focus")
            }
            Group {
                if let bar = hovered {
                    Text("\(bar.label): ").foregroundStyle(Theme.ink)
                    + Text("\(DurationFormat.short(bar.tracked)) tracked").foregroundStyle(Theme.ink).bold()
                    + Text(" · ").foregroundStyle(Theme.muted)
                    + Text("\(DurationFormat.short(bar.focus)) focus").foregroundStyle(Theme.ink).bold()
                } else {
                    Text("Average \(DurationFormat.short(average)) per active \(period == .year ? "month" : "day") — hover a bar")
                        .foregroundStyle(Theme.muted)
                }
            }
            .font(.system(size: 11))
            .lineLimit(1)
            .frame(height: 14)

            HStack(alignment: .bottom, spacing: period == .month ? 2 : 6) {
                ForEach(buckets) { bar in
                    let isHovered = hoveredBucket == bar.date
                    VStack(spacing: 4) {
                        ZStack(alignment: .bottom) {
                            RoundedRectangle(cornerRadius: 0)
                                .fill(Color.clear)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(Theme.navy.opacity(isHovered ? 0.5 : (bar.isCurrent ? 0.35 : 0.2)))
                                .frame(height: bar.tracked > 0 ? max(2, height * bar.tracked / maxValue) : 0)
                            UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                                .fill(Theme.running)
                                .frame(height: bar.focus > 0 ? max(2, height * min(bar.focus, maxValue) / maxValue) : 0)
                                .padding(.horizontal, period == .month ? 2 : 5)
                        }
                        .frame(height: height, alignment: .bottom)
                        Text(bar.axisLabel)
                            .font(.system(size: 9, weight: bar.isCurrent ? .bold : .regular))
                            .foregroundStyle(bar.isCurrent ? Theme.ink : Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                            .frame(height: 11)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hoveredBucket = bar.date } else if hoveredBucket == bar.date { hoveredBucket = nil }
                    }
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(Theme.border).frame(height: 1).padding(.bottom, 15)
            }
        }
    }

    // MARK: Wins

    private func wins(_ data: InsightsData) -> some View {
        let streak = stats.streak(now: clock.now)
        var items: [(icon: String, tint: Color, title: String, detail: String)] = []
        if offset == 0, streak > 0 {
            items.append(("flame.fill", Theme.onBreak, "\(streak)-day focus streak", streak >= 3 ? "Keep the chain going." : "One more day builds the habit."))
        }
        if let best = data.bestDay {
            items.append(("trophy.fill", Theme.warmup, "Best day: \(best.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))",
                          "\(DurationFormat.short(best.tracked)) tracked"))
        }
        if let longest = data.longestEntry {
            items.append(("bolt.fill", Theme.navy, "Longest stretch: \(DurationFormat.short(longest.duration))",
                          longest.draft.task?.name ?? longest.draft.project?.name ?? longest.draft.client?.name ?? "Untitled"))
        }
        if data.blocks > 0 {
            items.append(("scope", Theme.running, "\(data.blocks) focus block\(data.blocks == 1 ? "" : "s") finished",
                          "\(DurationFormat.short(data.focus)) of deep work"))
        }
        if data.cameBack > 0 {
            items.append(("arrow.uturn.backward.circle.fill", Theme.running, "Came back from \(data.cameBack) drift\(data.cameBack == 1 ? "" : "s")",
                          "Noticing is the skill — nicely done."))
        }
        if data.tasksDone > 0 {
            items.append(("checkmark.seal.fill", Theme.running, "\(data.tasksDone) task\(data.tasksDone == 1 ? "" : "s") finished", "Off your plate."))
        }

        return Group {
            if !items.isEmpty {
                card {
                    CapsLabel("Wins")
                    VStack(alignment: .leading, spacing: 9) {
                        ForEach(items.prefix(5), id: \.title) { item in
                            HStack(spacing: 10) {
                                Image(systemName: item.icon)
                                    .font(.system(size: 12))
                                    .foregroundStyle(item.tint)
                                    .frame(width: 28, height: 28)
                                    .background(Circle().fill(item.tint.opacity(0.12)))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
                                    Text(item.detail).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Clients

    private func clients(_ data: InsightsData) -> some View {
        let rows = data.clients
        let top = rows.first?.total ?? 1
        return card {
            HStack {
                CapsLabel("Where the time went")
                Spacer()
                Text("\(rows.count) client\(rows.count == 1 ? "" : "s")").font(.system(size: 10.5)).foregroundStyle(Theme.muted)
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.prefix(8)) { row in
                    let open = openClient == row.name
                    VStack(alignment: .leading, spacing: 6) {
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) { openClient = open ? nil : row.name }
                        } label: {
                            HStack(spacing: 10) {
                                ClientAvatar(name: row.name, size: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 6) {
                                        Text(row.name)
                                            .font(.system(size: 12.5, weight: .semibold))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(DurationFormat.short(row.total))
                                            .font(.system(size: 12, weight: .semibold).monospacedDigit())
                                            .foregroundStyle(Theme.ink)
                                        Text(percent(row.total, of: data.tracked))
                                            .font(.system(size: 10.5).monospacedDigit())
                                            .foregroundStyle(Theme.muted)
                                            .frame(width: 32, alignment: .trailing)
                                    }
                                    GeometryReader { proxy in
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Theme.navy.opacity(0.07))
                                            // Whole bar in the light tone (non-billable), billable part on top in the dark tone.
                                            Capsule().fill(Theme.navy.opacity(0.28))
                                                .frame(width: max(4, proxy.size.width * row.total / top))
                                            if row.billable > 0 {
                                                Capsule().fill(Theme.navy.opacity(0.8))
                                                    .frame(width: max(4, proxy.size.width * row.billable / top))
                                            }
                                        }
                                    }
                                    .frame(height: 5)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(Theme.faint)
                                    .rotationEffect(.degrees(open ? 90 : 0))
                            }
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("\(row.name): \(DurationFormat.short(row.billable)) billable of \(DurationFormat.short(row.total)) · \(row.entries) entr\(row.entries == 1 ? "y" : "ies")")

                        if open {
                            VStack(alignment: .leading, spacing: 4) {
                                ForEach(row.projects, id: \.name) { project in
                                    HStack(spacing: 6) {
                                        Circle().fill(Theme.navy.opacity(0.35)).frame(width: 5, height: 5)
                                        Text(project.name).font(.system(size: 11.5)).foregroundStyle(Theme.ink.opacity(0.8)).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(DurationFormat.short(project.total))
                                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                                            .foregroundStyle(Theme.ink.opacity(0.8))
                                    }
                                }
                            }
                            .padding(.leading, 34)
                            .padding(.trailing, 18)
                            .padding(.bottom, 4)
                        }
                    }
                }
                if rows.count > 8 {
                    Text("+ \(rows.count - 8) more · \(DurationFormat.short(rows.dropFirst(8).reduce(0) { $0 + $1.total }))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .padding(.leading, 34)
                }
            }
            HStack(spacing: 10) {
                legend(Theme.navy.opacity(0.8), "billable")
                legend(Theme.navy.opacity(0.28), "non-billable")
                Spacer()
                Text("Click a client for its projects").font(.system(size: 9.5)).foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: When you work

    private func hours(_ data: InsightsData) -> some View {
        let range = data.hourRange
        let maxValue = max(data.byHour.max() ?? 0, 1)
        let peak = data.byHour.indices.max { data.byHour[$0] < data.byHour[$1] }
        return card {
            HStack {
                CapsLabel("When you work")
                Spacer()
                if let peak, data.byHour[peak] > 0 {
                    Text("Peak hour: \(hourLabel(peak))–\(hourLabel(peak + 1))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.muted)
                }
            }
            HStack(spacing: 2) {
                ForEach(Array(range), id: \.self) { hour in
                    let value = data.byHour[hour]
                    VStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(value > 0 ? Theme.navy.opacity(0.12 + 0.78 * value / maxValue) : Theme.navy.opacity(0.04))
                            .frame(height: 22)
                            .help("\(hourLabel(hour))–\(hourLabel(hour + 1)): \(DurationFormat.short(value))")
                        Text(hour % 3 == 0 ? hourLabel(hour) : "")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Theme.muted)
                            .fixedSize()
                            .frame(height: 10)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        var components = DateComponents()
        components.hour = hour % 24
        let date = Calendar.current.date(from: components) ?? .now
        return date.formatted(.dateTime.hour(.defaultDigits(amPM: .narrow)))
    }

    // MARK: Pieces

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.bar.xaxis").font(.system(size: 28)).foregroundStyle(Theme.faint)
            Text("No time logged in this \(period.rawValue.lowercased()) yet.")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
            Text("Start a focus block or a timer — your wins will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.faint)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border))
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text).font(.system(size: 9)).foregroundStyle(Theme.muted)
        }
    }
}

/// Everything the Insights screen shows for one period, computed once per render.
@MainActor
struct InsightsData {
    struct Bucket: Identifiable {
        let date: Date
        let label: String
        let axisLabel: String
        let isCurrent: Bool
        var tracked: TimeInterval = 0
        var focus: TimeInterval = 0
        var id: Date { date }
    }

    struct ClientRow: Identifiable {
        let name: String
        var total: TimeInterval = 0
        var billable: TimeInterval = 0
        var entries = 0
        var projects: [(name: String, total: TimeInterval)] = []
        var id: String { name }
    }

    var tracked: TimeInterval = 0
    var billable: TimeInterval = 0
    var focus: TimeInterval = 0
    var blocks = 0
    var tasksDone = 0
    var cameBack = 0
    var buckets: [Bucket] = []
    var clients: [ClientRow] = []
    var byHour = [TimeInterval](repeating: 0, count: 24)
    var bestDay: (date: Date, tracked: TimeInterval)?
    var longestEntry: LoggedEntry?

    var activeBuckets: Int { buckets.filter { $0.tracked > 0 }.count }

    /// Working hours to draw: 7am–8pm, widened to cover any time actually logged.
    var hourRange: ClosedRange<Int> {
        let used = byHour.indices.filter { byHour[$0] > 0 }
        return min(7, used.min() ?? 7)...max(19, used.max() ?? 19)
    }

    init(interval: DateInterval, period: InsightsTab.Period, history: HistoryStore, stats: StatsStore, now: Date) {
        let calendar = Calendar.current
        let entries = history.entries(in: interval)
        tracked = entries.reduce(0) { $0 + $1.duration }
        billable = entries.filter(\.isBillable).reduce(0) { $0 + $1.duration }
        longestEntry = entries.max { $0.duration < $1.duration }

        // Per-day focus stats.
        var day = interval.start
        var trackedByDay: [Date: TimeInterval] = [:]
        for entry in entries { trackedByDay[calendar.startOfDay(for: entry.start), default: 0] += entry.duration }
        var focusByDay: [Date: TimeInterval] = [:]
        while day < interval.end, day <= now {
            let record = stats.day(day)
            focus += record.focusSeconds
            blocks += record.blocksCompleted
            tasksDone += record.tasksDone
            cameBack += record.cameBack
            focusByDay[day] = record.focusSeconds
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        if let best = trackedByDay.max(by: { $0.value < $1.value }), best.value > 0 { bestDay = (best.key, best.value) }

        // Bars: days for a week/month, months for a year.
        if period == .year {
            for index in 0..<12 {
                guard let start = calendar.date(byAdding: .month, value: index, to: interval.start) else { continue }
                var bucket = Bucket(date: start, label: start.formatted(.dateTime.month(.wide)),
                                    axisLabel: start.formatted(.dateTime.month(.narrow)),
                                    isCurrent: calendar.isDate(start, equalTo: now, toGranularity: .month))
                bucket.tracked = trackedByDay.filter { calendar.isDate($0.key, equalTo: start, toGranularity: .month) }.values.reduce(0, +)
                bucket.focus = focusByDay.filter { calendar.isDate($0.key, equalTo: start, toGranularity: .month) }.values.reduce(0, +)
                buckets.append(bucket)
            }
        } else {
            var cursor = interval.start
            var index = 0
            while cursor < interval.end {
                let axis: String
                if period == .week {
                    axis = cursor.formatted(.dateTime.weekday(.abbreviated))
                } else {
                    let dayNumber = calendar.component(.day, from: cursor)
                    axis = (dayNumber == 1 || dayNumber % 5 == 0) ? "\(dayNumber)" : ""
                }
                var bucket = Bucket(date: cursor, label: cursor.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
                                    axisLabel: axis, isCurrent: calendar.isDate(cursor, inSameDayAs: now))
                bucket.tracked = trackedByDay[cursor] ?? 0
                bucket.focus = focusByDay[cursor] ?? 0
                buckets.append(bucket)
                index += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }

        // Clients and their projects.
        var rows: [String: ClientRow] = [:]
        var projects: [String: [String: TimeInterval]] = [:]
        for entry in entries {
            let name = entry.draft.client?.name ?? "No client yet"
            var row = rows[name] ?? ClientRow(name: name)
            row.total += entry.duration
            if entry.isBillable { row.billable += entry.duration }
            row.entries += 1
            rows[name] = row
            projects[name, default: [:]][entry.draft.project?.name ?? "No project", default: 0] += entry.duration
        }
        clients = rows.values.map { row in
            var row = row
            row.projects = (projects[row.name] ?? [:]).map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
            return row
        }
        .sorted { $0.total > $1.total }

        // Time by hour of day, split across hour boundaries.
        for entry in entries {
            var cursor = entry.start
            while cursor < entry.end {
                let hour = calendar.component(.hour, from: cursor)
                let nextHour = calendar.dateInterval(of: .hour, for: cursor)?.end ?? entry.end
                let end = min(nextHour, entry.end)
                byHour[hour] += end.timeIntervalSince(cursor)
                cursor = end
            }
        }
    }
}

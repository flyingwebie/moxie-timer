import Foundation

/// What's going on right now, for situation rules and the AI prompt.
struct PetContext {
    var now: Date = .now
    var blocksToday = 0
    var tasksToday = 0
    var focusMinutesToday = 0
    var driftsToday = 0
    var driftsLastHour = 0
    var streak = 0
    /// Minutes of work since the last break (0 when the timer isn't running).
    var minutesSinceBreak = 0
    /// When the current task is due.
    var due: Date?
    /// How long the user was away, if they came back in the last 15 minutes.
    var awayMinutes: Int?

    private var calendar: Calendar { .current }
    var hour: Int { calendar.component(.hour, from: now) }
    /// 1 = Sunday … 7 = Saturday.
    var weekday: Int { calendar.component(.weekday, from: now) }

    var isDueTodayOrLate: Bool {
        guard let due else { return false }
        return calendar.startOfDay(for: due) <= calendar.startOfDay(for: now)
    }

    func matches(_ condition: PetCondition) -> Bool {
        switch condition {
        case .morningStart: return (5..<11).contains(hour) && blocksToday == 0
        case .lateNight: return hour >= 21 || hour < 4
        case .weekEdge: return (weekday == 2 && hour < 12) || (weekday == 6 && hour >= 14)
        case .dueToday: return isDueTodayOrLate
        case .hyperfocus: return minutesSinceBreak >= 90
        case .roughPatch: return driftsLastHour >= 3
        case .onFire: return blocksToday >= 3 || streak >= 5
        case .longAway: return (awayMinutes ?? 0) >= 30
        }
    }

    /// A few plain sentences for the AI, so lines can fit the moment instead of sounding generic.
    /// `includeCounts: false` leaves out today's counts (for lines written before the moment happens).
    func summary(includeCounts: Bool = true) -> String {
        var parts: [String] = []
        let time = now.formatted(.dateTime.weekday(.wide).hour().minute())
        parts.append("It's \(time) (\(partOfDay)).")
        if includeCounts { parts.append(todaySummary) }
        if minutesSinceBreak > 0 { parts.append("Working for \(Self.duration(minutesSinceBreak)) since the last break.") }
        parts += extras
        return parts.joined(separator: " ")
    }

    private var todaySummary: String {
        var today = "Today so far: \(Self.duration(focusMinutesToday)) focused, \(blocksToday) focus block\(blocksToday == 1 ? "" : "s"), "
        today += "\(tasksToday) task\(tasksToday == 1 ? "" : "s") finished, \(driftsToday) drift\(driftsToday == 1 ? "" : "s")"
        if driftsLastHour > 0 { today += " (\(driftsLastHour) in the last hour)" }
        return today + "."
    }

    private var extras: [String] {
        var parts: [String] = []
        if let due {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: due)).day ?? 0
            switch days {
            case ..<0: parts.append("The current task is \(-days) day\(days == -1 ? "" : "s") overdue.")
            case 0: parts.append("The current task is due today.")
            case 1: parts.append("The current task is due tomorrow.")
            case 2...7: parts.append("The current task is due in \(days) days.")
            default: break
            }
        }
        if let awayMinutes, awayMinutes > 0 { parts.append("They were away for \(Self.duration(awayMinutes)).") }
        if streak > 1 { parts.append("Focus streak: \(streak) days.") }
        return parts
    }

    private var partOfDay: String {
        switch hour {
        case 5..<12: return "morning"
        case 12..<17: return "afternoon"
        case 17..<21: return "evening"
        default: return "late night"
        }
    }

    private static func duration(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h\(minutes % 60 == 0 ? "" : " \(minutes % 60) min")"
    }
}

/// Lines said recently, so the pet doesn't repeat itself. Kept for the day across restarts.
struct PetLineMemory: Codable {
    struct Entry: Codable {
        /// The line as shown, before placeholders are filled (so "{task}" lines match across tasks).
        var key: String
        /// The line as it was said, for the AI's "don't repeat" list.
        var said: String
        var at: Date
    }

    private(set) var entries: [Entry] = []
    static let limit = 40

    static func key(_ template: String) -> String {
        PetSpeech.display(template).lowercased().filter { $0.isLetter || $0.isNumber || $0 == "{" || $0 == "}" }
    }

    mutating func remember(template: String, said: String, at date: Date = .now) {
        entries.append(Entry(key: Self.key(template), said: PetSpeech.display(said), at: date))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    /// Said today, or among the last 20 lines.
    func isRecent(_ template: String, now: Date = .now) -> Bool {
        let key = Self.key(template)
        let start = Calendar.current.startOfDay(for: now)
        return entries.suffix(20).contains { $0.key == key } || entries.contains { $0.key == key && $0.at >= start }
    }

    /// A random line from the pool that wasn't said recently, if any.
    func unused(_ pool: [String], now: Date = .now) -> String? {
        pool.filter { !isRecent($0, now: now) }.randomElement()
    }

    /// The template from the pool that's freshest: never said recently, else the one said longest ago.
    func freshest(_ pool: [String], now: Date = .now) -> String? {
        let unique = Array(Set(pool))
        let fresh = unique.filter { !isRecent($0, now: now) }
        if let pick = fresh.randomElement() { return pick }
        return unique.min { lastSaid($0) < lastSaid($1) }
    }

    private func lastSaid(_ template: String) -> Date {
        let key = Self.key(template)
        return entries.last { $0.key == key }?.at ?? .distantPast
    }

    /// The last few lines, for the AI prompt.
    func recentSaid(_ count: Int = 12) -> [String] { entries.suffix(count).map(\.said) }
}

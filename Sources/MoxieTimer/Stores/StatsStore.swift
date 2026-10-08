import Foundation
import Observation

/// Per-day focus statistics, kept locally, for the daily summary, weekly chart and streak.
@MainActor @Observable
final class StatsStore {
    struct Day: Codable, Equatable {
        var focusSeconds: TimeInterval = 0
        var blocksCompleted = 0
        var tasksDone = 0
        var drifts = 0
        var cameBack = 0
        var checkInsOnTask = 0
    }

    private(set) var days: [String: Day] = [:]

    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "stats.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode([String: Day].self, from: data) {
            days = saved
        }
    }

    static func key(_ date: Date) -> String { MoxieTask.dayFormatter.string(from: date) }

    func day(_ date: Date) -> Day { days[Self.key(date)] ?? Day() }

    func record(_ change: (inout Day) -> Void, on date: Date = .now) {
        var day = self.day(date)
        change(&day)
        days[Self.key(date)] = day
        persist()
    }

    /// Consecutive days, ending today (or yesterday if today has none yet), with at least one finished focus block.
    func streak(now: Date = .now) -> Int {
        let calendar = Calendar.current
        var cursor = calendar.startOfDay(for: now)
        if day(cursor).blocksCompleted == 0 {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var count = 0
        while day(cursor).blocksCompleted > 0 {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }

    private func persist() {
        // Keep roughly a year.
        if days.count > 400 {
            for key in days.keys.sorted().prefix(days.count - 400) { days.removeValue(forKey: key) }
        }
        guard let data = try? JSONEncoder().encode(days) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

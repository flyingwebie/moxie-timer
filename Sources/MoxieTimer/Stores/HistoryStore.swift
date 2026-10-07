import Foundation
import Observation

/// Entries this widget has logged. The Moxie Public API cannot list time entries,
/// so "Recent" is a local record of what was pushed from here.
@MainActor @Observable
final class HistoryStore {
    struct DayGroup: Identifiable {
        let day: Date
        let entries: [LoggedEntry]
        var id: Date { day }
        var total: TimeInterval { entries.reduce(0) { $0 + $1.duration } }
    }

    private(set) var entries: [LoggedEntry] = []

    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([LoggedEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(_ entry: LoggedEntry) {
        entries.insert(entry, at: 0)
        entries.sort { $0.start > $1.start }
        if entries.count > 1000 { entries.removeLast(entries.count - 1000) }
        persist()
    }

    func update(_ entry: LoggedEntry) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        entries.sort { $0.start > $1.start }
        persist()
    }

    /// Entries held for review, oldest first.
    var pending: [LoggedEntry] {
        entries.filter(\.isPending).sorted { $0.start < $1.start }
    }

    func remove(_ entry: LoggedEntry) {
        entries.removeAll { $0.id == entry.id }
        persist()
    }

    func total(today now: Date) -> TimeInterval {
        entries.filter { Calendar.current.isDate($0.start, inSameDayAs: now) }.reduce(0) { $0 + $1.duration }
    }

    func total(week now: Date) -> TimeInterval {
        guard let week = Calendar.current.dateInterval(of: .weekOfYear, for: now) else { return 0 }
        return entries.filter { week.contains($0.start) }.reduce(0) { $0 + $1.duration }
    }

    var groupedByDay: [DayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { DayGroup(day: $0, entries: grouped[$0]!.sorted { $0.start > $1.start }) }
    }

    private func persist() {
        do {
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MoxieTimer: failed to save history: \(error)")
        }
    }
}

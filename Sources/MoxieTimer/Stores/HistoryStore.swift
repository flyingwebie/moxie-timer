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

    // MARK: Backups

    /// One copy per day of history.json (taken before the first change of the day), newest first.
    struct Backup: Identifiable, Hashable {
        let url: URL
        let day: Date
        let count: Int
        var id: URL { url }
    }

    private static let keptBackups = 14

    var backupFolder: URL {
        fileURL.deletingLastPathComponent().appending(path: "Backups", directoryHint: .isDirectory)
    }

    var backups: [Backup] {
        let files = (try? FileManager.default.contentsOfDirectory(at: backupFolder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.lastPathComponent.hasPrefix("history-") && $0.pathExtension == "json" }
            .compactMap { url in
                let stamp = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "history-", with: "")
                guard let day = MoxieTask.dayFormatter.date(from: stamp) else { return nil }
                let count = (try? JSONDecoder().decode([LoggedEntry].self, from: Data(contentsOf: url)))?.count ?? 0
                return Backup(url: url, day: day, count: count)
            }
            .sorted { $0.day > $1.day }
    }

    /// Merges a backup back in: entries missing now are restored, existing ones are kept as they are.
    @discardableResult
    func restore(_ backup: Backup) -> Int {
        guard let saved = try? JSONDecoder().decode([LoggedEntry].self, from: Data(contentsOf: backup.url)) else { return 0 }
        let known = Set(entries.map(\.id))
        let missing = saved.filter { !known.contains($0.id) }
        guard !missing.isEmpty else { return 0 }
        entries.append(contentsOf: missing)
        entries.sort { $0.start > $1.start }
        persist()
        return missing.count
    }

    private func backUpIfNeeded() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL), data.count > 2 else { return }
        try? fileManager.createDirectory(at: backupFolder, withIntermediateDirectories: true)
        let today = backupFolder.appending(path: "history-\(MoxieTask.dayFormatter.string(from: .now)).json")
        guard !fileManager.fileExists(atPath: today.path) else { return }
        try? data.write(to: today, options: .atomic)
        for old in backups.dropFirst(Self.keptBackups) {
            try? fileManager.removeItem(at: old.url)
        }
    }

    private func persist() {
        backUpIfNeeded()
        do {
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MoxieTimer: failed to save history: \(error)")
        }
    }
}

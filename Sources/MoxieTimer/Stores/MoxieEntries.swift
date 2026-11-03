import Foundation
import Observation

/// Short-lived cache of what Moxie's `time_entries_list` reports for a date range — used to reconcile
/// Recent/Review against entries logged elsewhere (the web app, another Mac, an AI assistant) and to total
/// unbilled hours for Insights. Not persisted and never written into `history.json`: this is a read-only
/// view of Moxie, refreshed per-interval and cached briefly so switching tabs doesn't refetch every time.
///
/// A singleton (not an environment object) because the owning views can't change how stores are injected;
/// reachable anywhere as `MoxieEntriesCache.shared`.
@MainActor @Observable
final class MoxieEntriesCache {
    static let shared = MoxieEntriesCache()

    private(set) var lastError: String?

    private struct Fetch {
        let entries: [MoxieRemoteEntry]
        let at: Date
    }

    /// Several intervals at once (Recent's week, Insights' week/month/year) each get their own slot.
    private var cache: [DateInterval: Fetch] = [:]
    private var inFlight: Set<DateInterval> = []
    private static let keptIntervals = 6

    private init() {}

    func isLoading(_ interval: DateInterval) -> Bool { inFlight.contains(interval) }

    /// Refetches for `interval` through Moxie's MCP if that interval's cache is stale (or missing). Does
    /// nothing when MCP isn't connected; callers fall back to local-only data in that case.
    func refresh(_ interval: DateInterval, force: Bool = false) async {
        let live = AppModel.shared.live
        guard live.isActive else { return }
        if !force, let cached = cache[interval], Date.now.timeIntervalSince(cached.at) < 60 { return }
        guard !inFlight.contains(interval) else { return }
        inFlight.insert(interval)
        defer { inFlight.remove(interval) }
        do {
            let entries = try await live.mcp.listEntries(earliest: interval.start, latest: interval.end)
            cache[interval] = Fetch(entries: entries, at: .now)
            if cache.count > Self.keptIntervals, let oldest = cache.min(by: { $0.value.at < $1.value.at })?.key {
                cache.removeValue(forKey: oldest)
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// The raw entries cached for `interval`, or empty if nothing's been fetched for it yet.
    func entries(for interval: DateInterval) -> [MoxieRemoteEntry] { cache[interval]?.entries ?? [] }

    /// Looks up one entry by Moxie id across every cached interval (the editor doesn't know which one
    /// a "moxie-…" row came from).
    func entry(moxieId: String) -> MoxieRemoteEntry? {
        cache.values.lazy.flatMap(\.entries).first { $0.id == moxieId }
    }

    /// Remote entries in `interval` not already represented locally (matched by `moxieId`), shaped as
    /// read-only `LoggedEntry` rows the UI can show inline, marked "from Moxie". `pending` is left `nil`
    /// (sent) since these are, by definition, already in Moxie.
    func reconciled(in interval: DateInterval, knownMoxieIds: Set<String>) -> [LoggedEntry] {
        entries(for: interval).compactMap { entry -> LoggedEntry? in
            guard !knownMoxieIds.contains(entry.id), let start = entry.start, interval.contains(start) else { return nil }
            let end = entry.end ?? start.addingTimeInterval(entry.duration)
            return LoggedEntry(id: "moxie-\(entry.id)", moxieId: entry.id, start: start, end: end, draft: entry.draft,
                               moxieBillable: entry.billable, pending: nil)
        }
    }
}

/// Edits or deletes a sent entry directly in Moxie (Recent tab, or the entry editor opened on a sent
/// entry), then keeps the local `HistoryStore` copy in sync — or creates one, for an entry that only
/// existed in Moxie until now (e.g. logged in the web app). Shared so Recent and the editor update the
/// same way. Throws with Moxie's message without changing local state (e.g. an already-invoiced entry).
@MainActor
enum MoxieEntryEditing {
    static func edit(_ entry: LoggedEntry, start: Date, end: Date, draft: EntryDraft, history: HistoryStore) async throws {
        guard let moxieId = entry.moxieId else { return }
        let updated = try await AppModel.shared.live.mcp.editEntry(id: moxieId, start: start, end: end, draft: draft, billable: draft.isBillable)
        var saved = entry
        saved.start = start
        saved.end = end
        saved.draft = draft
        saved.moxieBillable = updated?.billable ?? draft.isBillable
        saved.sendError = nil
        if history.entries.contains(where: { $0.id == entry.id }) {
            history.update(saved)
        } else {
            saved.id = UUID().uuidString  // was shown only because Moxie knew about it; now worth keeping locally too
            history.add(saved)
        }
    }

    /// Permanent in Moxie; callers must confirm with the user first.
    static func delete(_ entry: LoggedEntry, history: HistoryStore) async throws {
        guard let moxieId = entry.moxieId else { return }
        try await AppModel.shared.live.mcp.deleteEntry(id: moxieId)
        if history.entries.contains(where: { $0.id == entry.id }) { history.remove(entry) }
    }
}

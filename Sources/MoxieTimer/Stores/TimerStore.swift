import Foundation
import Observation

enum LogError: LocalizedError {
    case notConfigured
    case missingClientOrProject
    case invalidRange

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Add your Moxie API key and email in Settings."
        case .missingClientOrProject: return "Pick a client first (project and ticket are optional)."
        case .invalidRange: return "The end time must be after the start time."
        }
    }
}

@MainActor @Observable
final class TimerStore {
    private struct Persisted: Codable {
        var draft: EntryDraft
        var session: TimerSession?
    }

    var draft = EntryDraft() { didSet { persist(); onChange?() } }
    private(set) var session: TimerSession? { didSet { persist(); onChange?() } }
    private(set) var isSaving = false
    var lastError: String?
    /// Non-fatal information about the last save (e.g. Moxie ignored the billable setting).
    var notice: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let storageKey = "timerState"
    /// Mirrors this timer to Moxie's live timer when connected through MCP.
    @ObservationIgnored var live: MoxieLiveTimer?
    /// Called after the draft or session changes, so Focus can follow what the timer is tracking.
    @ObservationIgnored var onChange: (() -> Void)?

    init(settings: AppSettings, history: HistoryStore) {
        self.settings = settings
        self.history = history
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let state = try? JSONDecoder().decode(Persisted.self, from: data) {
            draft = state.draft
            session = state.session
        }
    }

    // MARK: Timer controls

    func start() {
        lastError = nil
        live?.clearPendingOffer()
        session = TimerSession(runningSince: .now)
        live?.started(draft)
    }

    func toggle() {
        guard let current = session else { return start() }
        if current.isRunning { pause() } else { resume() }
    }

    /// `mirror: false` when the change came from Moxie itself.
    func pause(mirror: Bool = true) {
        guard var current = session, current.isRunning else { return }
        current.pause(at: .now)
        session = current
        if mirror { live?.paused() }
    }

    func resume(mirror: Bool = true) {
        guard var current = session, !current.isRunning else { return }
        current.resume(at: .now)
        session = current
        if mirror { live?.resumed() }
    }

    /// Shows a timer that was started in Moxie (web app, phone, AI assistant).
    func adopt(_ remote: MoxieTimeEntry) {
        guard session == nil, let start = remote.start else { return }
        let now = Date.now
        let paused = remote.pausedSeconds ?? 0
        var adopted = TimerSession()
        if let pausedAt = remote.pausedAt.flatMap(MoxieMCP.parseDate) {
            adopted.accumulated = max(0, pausedAt.timeIntervalSince(start) - paused)
            adopted.pausedAt = pausedAt
        } else {
            adopted.accumulated = max(0, now.timeIntervalSince(start) - paused)
            adopted.runningSince = now
        }
        draft = remote.draft
        session = adopted
        notice = "Picked up the timer running in Moxie."
    }

    /// Ends the local session without saving (it was already saved or discarded in Moxie).
    func dropSession(notice: String) {
        guard session != nil else { return }
        session = nil
        draft.notes = ""
        draft.ticket = nil
        self.notice = notice
    }

    func adjust(by delta: TimeInterval) {
        guard var current = session else { return }
        let now = Date.now
        current.setElapsed(current.elapsed(at: now) + delta, at: now)
        session = current
    }

    func setDuration(_ duration: TimeInterval) {
        guard var current = session else { return }
        current.setElapsed(duration, at: .now)
        session = current
    }

    func setStart(_ start: Date) {
        guard var current = session else { return }
        let now = Date.now
        current.setElapsed(current.end(at: now).timeIntervalSince(start), at: now)
        session = current
    }

    func discard() {
        live?.discarded()
        session = nil
        lastError = nil
        draft.notes = ""
        draft.ticket = nil
    }

    /// Starts a new timer for the same client/project/task as a past entry.
    func startAgain(from entry: LoggedEntry) {
        guard session == nil else { return }
        draft = entry.draft.reusable
        start()
    }

    /// Freezes the timer and pushes it to Moxie. On failure the session stays (paused) so nothing is lost.
    func stopAndSave() async {
        guard var current = session, !isSaving else { return }
        let now = Date.now
        current.pause(at: now)
        session = current

        isSaving = true
        defer { isSaving = false }
        do {
            if try await saveThroughLiveTimer(start: current.start(at: now), end: current.end(at: now)) == false {
                _ = try await log(start: current.start(at: now), end: current.end(at: now), draft: draft)
            }
            session = nil
            draft.notes = ""
            draft.ticket = nil
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Moves the current time into Review as a held entry (not sent) and clears the timer, so it can't
    /// leak onto the next task. Used when switching work before a client is picked. Returns the held time.
    @discardableResult
    func holdCurrent() -> TimeInterval {
        guard var current = session else { return 0 }
        let now = Date.now
        current.pause(at: now)
        let start = Date(timeIntervalSince1970: current.start(at: now).timeIntervalSince1970.rounded(.down))
        let end = Date(timeIntervalSince1970: current.end(at: now).timeIntervalSince1970.rounded(.down))
        let held = end.timeIntervalSince(start)
        // Under a minute is noise, not worth a Review row.
        if held >= 60 {
            history.add(LoggedEntry(id: UUID().uuidString, moxieId: nil, start: start, end: end, draft: draft, pending: true))
        }
        session = nil
        live?.discarded()
        draft.notes = ""
        draft.ticket = nil
        lastError = nil
        return held >= 60 ? held : 0
    }

    /// With Moxie's live timer running: stop it there (Moxie saves the entry) and correct its times/links.
    /// In review mode the time is held here instead, so Moxie's copy is dropped. Returns false when the
    /// usual save path should run.
    private func saveThroughLiveTimer(start: Date, end: Date) async throws -> Bool {
        guard let live, live.isActive, live.remoteActive else { return false }
        if settings.holdForReview {
            live.discarded()
            return false
        }
        let start = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
        let end = Date(timeIntervalSince1970: end.timeIntervalSince1970.rounded(.down))
        guard end > start else { throw LogError.invalidRange }
        guard let saved = await live.stop(start: start, end: end, draft: draft) else { return false }
        history.add(LoggedEntry(id: UUID().uuidString, moxieId: saved.entry.id, start: start, end: end, draft: draft,
                                moxieBillable: saved.entry.billable, pending: nil))
        notice = saved.warning
        return true
    }

    // MARK: Logging

    /// Whether the running time can be stopped now. In review mode the client/project can be chosen later.
    var canSaveCurrent: Bool {
        settings.holdForReview || draft.client != nil
    }

    private(set) var isSending = false

    var holdsForReview: Bool { settings.holdForReview }

    /// The project most recently logged for a client, to prefill work that has no project (tickets).
    func lastProject(forClient clientId: String) -> Ref? {
        history.entries.first { $0.draft.client?.id == clientId && $0.draft.project != nil }?.draft.project
    }

    /// Records a block of time: held locally in review mode, otherwise sent to Moxie straight away.
    func log(start: Date, end: Date, draft: EntryDraft) async throws -> LoggedEntry {
        // Moxie stores whole seconds; drop sub-second noise so start/end match what we display.
        let start = Date(timeIntervalSince1970: start.timeIntervalSince1970.rounded(.down))
        let end = Date(timeIntervalSince1970: end.timeIntervalSince1970.rounded(.down))
        guard end > start else { throw LogError.invalidRange }
        let entry = LoggedEntry(id: UUID().uuidString, moxieId: nil, start: start, end: end, draft: draft, pending: true)
        if settings.holdForReview {
            history.add(entry)
            return entry
        }
        return try await send(entry, isNew: true)
    }

    /// Pushes one entry to Moxie and marks it sent.
    @discardableResult
    func send(_ entry: LoggedEntry, isNew: Bool = false) async throws -> LoggedEntry {
        guard let api = settings.makeAPI(), settings.isConfigured else { throw LogError.notConfigured }
        guard let client = entry.draft.client else { throw LogError.missingClientOrProject }
        guard entry.end > entry.start else { throw LogError.invalidRange }

        func request(billable: Bool?) -> TimeEntryRequest {
            TimeEntryRequest(
                timerStart: entry.start.formatted(.iso8601),
                timerEnd: entry.end.formatted(.iso8601),
                clientName: client.name,
                projectName: entry.draft.project?.name,
                deliverableName: entry.draft.task?.name,
                notes: entry.draft.composedNotes,
                userEmail: settings.userEmail.trimmingCharacters(in: .whitespaces),
                billable: billable
            )
        }

        notice = nil
        let wanted = entry.draft.isBillable
        let event: TimerEvent?
        do {
            event = try await api.createTimeEntry(request(billable: wanted))
        } catch MoxieAPI.APIError.http(400, _) {
            // `billable` isn't in the documented schema; if Moxie rejects it, save the time without it.
            event = try await api.createTimeEntry(request(billable: nil))
            notice = "Moxie didn't accept the billable setting, so the entry was saved with Moxie's default."
        }
        if notice == nil, let stored = event?.billable, stored != wanted {
            notice = "Moxie saved this entry as \(stored ? "billable" : "non-billable") — the API ignored the toggle."
        }

        var sent = entry
        sent.moxieId = event?.id
        sent.moxieBillable = event?.billable
        sent.pending = nil
        sent.sendError = nil
        if isNew { history.add(sent) } else { history.update(sent) }
        return sent
    }

    /// Sends every held entry that has a client and project. Failures stay held with their error.
    func sendPending() async -> (sent: Int, failed: Int, skipped: Int) {
        guard !isSending else { return (0, 0, 0) }
        isSending = true
        defer { isSending = false }
        var sent = 0, failed = 0, skipped = 0
        for entry in history.pending {
            guard entry.hasCategory else {
                skipped += 1
                continue
            }
            do {
                try await send(entry)
                sent += 1
            } catch {
                var held = entry
                held.sendError = error.localizedDescription
                history.update(held)
                failed += 1
            }
        }
        return (sent, failed, skipped)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(Persisted(draft: draft, session: session)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }
}

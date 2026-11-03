import AppKit
import Observation

/// Keeps the widget's timer and Moxie's own live timer in step through the MCP server, so the widget,
/// the Moxie web app and AI assistants all show the same clock.
///
/// The widget's timer stays the source of exact numbers (backdating, duration edits). Moxie's timer
/// mirrors start / pause / resume / discard; on stop Moxie saves the entry and we then correct its
/// times and links with `time_entries_update`. A timer started elsewhere is adopted; one stopped
/// elsewhere (already saved in Moxie) is dropped here without saving twice.
@MainActor @Observable
final class MoxieLiveTimer {
    private(set) var isConnected: Bool
    private(set) var isConnecting = false
    var lastError: String?
    /// Short status for Settings ("Live timer in sync · 13:05").
    private(set) var lastSync: Date?

    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "mcpLiveTimer") }
    }

    /// Whether Moxie's timer is currently running for our session (as far as we know).
    private(set) var remoteActive: Bool {
        didSet { UserDefaults.standard.set(remoteActive, forKey: "mcpRemoteActive") }
    }

    /// A timer found running in Moxie while nothing is running here: offered, not auto-adopted.
    private(set) var pendingRemote: MoxieTimeEntry?

    var isActive: Bool { isConnected && enabled }

    @ObservationIgnored private let auth: MCPAuth
    /// Shared MCP client; other features (tickets, entries, dashboard) call Moxie through it.
    @ObservationIgnored private(set) lazy var mcp = MoxieMCP(auth: auth)
    @ObservationIgnored weak var timer: TimerStore?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var isStopping = false
    /// Bumped by every local start / discard / stop, so a poll answered before it can't undo it.
    @ObservationIgnored private var generation = 0
    /// Key of a remote timer the user chose to ignore, so the same one isn't offered again.
    @ObservationIgnored private var ignoredRemoteKey: String?

    /// `skipKeychainForTesting` forwards to `MCPAuth`'s own Keychain seam, so tests never trigger a
    /// one-time system access prompt for the "mcpTokens" item.
    init(skipKeychainForTesting: Bool = false) {
        auth = MCPAuth(skipKeychainForTesting: skipKeychainForTesting)
        isConnected = auth.isSignedIn
        enabled = UserDefaults.standard.object(forKey: "mcpLiveTimer") as? Bool ?? true
        remoteActive = UserDefaults.standard.bool(forKey: "mcpRemoteActive")
        let poller = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    // MARK: Connection

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        defer { isConnecting = false }
        lastError = nil
        do {
            try await auth.signIn()
            isConnected = true
            _ = try await mcp.timerGet()  // proves the token works end to end
            lastSync = .now
            poll()
        } catch {
            isConnected = auth.isSignedIn
            lastError = error.localizedDescription
        }
    }

    func disconnect() {
        auth.signOut()
        isConnected = false
        remoteActive = false
        lastSync = nil
    }

    // MARK: Mirroring local actions (fire and forget, in order)

    func started(_ draft: EntryDraft) {
        guard isActive else { return }
        pendingRemote = nil
        generation += 1
        enqueue {
            guard let result = try await self.mcp.timerStart(draft) else {
                self.remoteActive = true
                return
            }
            if Self.isOurs(result, draft) {
                self.remoteActive = true
            } else {
                // Moxie ignores timer_start while one is already running, and returns that one unchanged:
                // ours isn't mirrored there until the existing timer is stopped or discarded in Moxie.
                self.remoteActive = false
                self.timer?.lastError =
                    "Moxie already has a timer running on \(Self.workLabel(result.draft)) — this timer isn't mirrored there until you stop or discard that one in Moxie."
            }
        }
    }

    func paused() {
        guard isActive, remoteActive else { return }
        enqueue { try await self.mcp.timerPause() }
    }

    func resumed() {
        guard isActive, remoteActive else { return }
        enqueue { try await self.mcp.timerResume() }
    }

    /// The local time is being thrown away or kept locally (held for review): drop Moxie's copy.
    func discarded() {
        guard isActive, remoteActive else { return }
        remoteActive = false
        generation += 1
        enqueue { try await self.mcp.timerDiscard() }
    }

    /// Stops Moxie's timer (which saves the entry) and sets the exact times and links.
    /// Returns nil when Moxie's timer isn't ours to stop, so the caller saves the usual way.
    func stop(start: Date, end: Date, draft: EntryDraft) async -> (entry: MoxieTimeEntry, warning: String?)? {
        guard isActive, remoteActive else { return nil }
        isStopping = true
        generation += 1
        defer { isStopping = false }
        await queue?.value
        do {
            guard let stopped = try await mcp.timerStop(), let id = stopped.id else {
                remoteActive = false
                return nil
            }
            remoteActive = false
            lastSync = .now
            do {
                let updated = try await mcp.updateEntry(id: id, start: start, end: end, draft: draft)
                return (updated ?? stopped, nil)
            } catch {
                return (stopped, "Saved in Moxie, but its times or links couldn't be corrected: \(error.localizedDescription)")
            }
        } catch {
            // Moxie's timer state is unknown; fall back to a normal save rather than lose the time.
            remoteActive = false
            lastError = error.localizedDescription
            return nil
        }
    }

    // MARK: Picking up changes made elsewhere

    func poll() {
        guard isActive, !isStopping, let timer else { return }
        enqueue {
            let asked = self.generation
            let remote = try await self.mcp.timerGet()
            self.lastSync = .now
            // The timer changed here while Moxie answered: its reply is already out of date.
            guard !self.isStopping, asked == self.generation else { return }
            switch (timer.session, remote) {
            case (nil, let remote?):
                // Started in Moxie (web app, phone, an AI assistant): offer it, don't take it silently.
                if Self.key(remote) == self.ignoredRemoteKey {
                    self.pendingRemote = nil
                } else {
                    self.pendingRemote = remote
                }
            case (nil, nil):
                self.pendingRemote = nil
                self.ignoredRemoteKey = nil
            case (_?, nil) where self.remoteActive:
                // Stopped or discarded in Moxie, where it's already saved: don't save it a second time.
                self.remoteActive = false
                timer.dropSession(notice: "The timer was stopped in Moxie, so it's saved there.")
            case let (session?, remote?) where self.remoteActive:
                // Paused / resumed in Moxie.
                self.pendingRemote = nil
                if remote.isPaused, session.isRunning { timer.pause(mirror: false) }
                if !remote.isPaused, !session.isRunning { timer.resume(mirror: false) }
            default:
                break
            }
        }
    }

    /// Adopts the offered remote timer — same as `TimerStore.adopt`, picked by the user.
    func acceptPendingRemote() {
        guard let remote = pendingRemote, let timer else { return }
        pendingRemote = nil
        ignoredRemoteKey = nil
        timer.adopt(remote)
        remoteActive = true
    }

    /// Leaves the remote timer running in Moxie untouched, and stops re-offering this same one.
    func ignorePendingRemote() {
        guard let remote = pendingRemote else { return }
        ignoredRemoteKey = Self.key(remote)
        pendingRemote = nil
    }

    /// Permanently deletes the offered timer in Moxie without saving it. The caller must confirm first.
    func discardPendingRemote() {
        guard pendingRemote != nil else { return }
        pendingRemote = nil
        ignoredRemoteKey = nil
        generation += 1
        enqueue { try await self.mcp.timerDiscard() }
    }

    /// Clears any pending offer without touching Moxie (e.g. the user started a local timer instead).
    func clearPendingOffer() {
        pendingRemote = nil
    }

    /// Whether the timer Moxie returned from `timer_start` is the one we just started. It isn't when it started
    /// minutes ago (Moxie kept an older timer) or its links conflict with ours. Links missing from the reply
    /// count as matching, so a terse reply doesn't break mirroring.
    static func isOurs(_ remote: MoxieTimeEntry, _ draft: EntryDraft, now: Date = .now) -> Bool {
        if let start = remote.start, now.timeIntervalSince(start) > 120 { return false }
        func agrees(_ id: String?, _ ref: Ref?) -> Bool {
            guard let id, !id.isEmpty else { return true }
            return id == ref?.id
        }
        return agrees(remote.clientId, draft.client) && agrees(remote.projectId, draft.project)
            && agrees(remote.taskId, draft.task) && agrees(remote.ticketId, draft.ticket)
    }

    private static func workLabel(_ draft: EntryDraft) -> String {
        draft.task?.name ?? draft.ticket?.name ?? draft.project?.name ?? draft.client?.name ?? "something else"
    }

    /// Identifies a remote timer across polls, so a dismissed one isn't re-offered.
    private static func key(_ entry: MoxieTimeEntry) -> String {
        entry.id ?? entry.timerStart ?? ""
    }

    private func enqueue(_ work: @escaping @MainActor () async throws -> Void) {
        let previous = queue
        queue = Task {
            await previous?.value
            do {
                try await work()
                self.lastError = nil
            } catch {
                self.lastError = error.localizedDescription
                if case MCPAuth.AuthError.notSignedIn = error { self.isConnected = false }
            }
        }
    }
}

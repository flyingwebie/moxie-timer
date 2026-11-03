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

    var isActive: Bool { isConnected && enabled }

    @ObservationIgnored private let auth = MCPAuth()
    @ObservationIgnored private lazy var mcp = MoxieMCP(auth: auth)
    @ObservationIgnored weak var timer: TimerStore?
    @ObservationIgnored private var queue: Task<Void, Never>?
    @ObservationIgnored private var poller: Timer?
    @ObservationIgnored private var isStopping = false

    init() {
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
        enqueue {
            _ = try await self.mcp.timerStart(draft)
            self.remoteActive = true
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
        enqueue { try await self.mcp.timerDiscard() }
    }

    /// Stops Moxie's timer (which saves the entry) and sets the exact times and links.
    /// Returns nil when Moxie's timer isn't ours to stop, so the caller saves the usual way.
    func stop(start: Date, end: Date, draft: EntryDraft) async -> (entry: MoxieTimeEntry, warning: String?)? {
        guard isActive, remoteActive else { return nil }
        isStopping = true
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
            let remote = try await self.mcp.timerGet()
            self.lastSync = .now
            guard !self.isStopping else { return }
            switch (timer.session, remote) {
            case (nil, let remote?):
                // Started in Moxie (web app, phone, an AI assistant): show it here.
                timer.adopt(remote)
                self.remoteActive = true
            case (_?, nil) where self.remoteActive:
                // Stopped or discarded in Moxie, where it's already saved: don't save it a second time.
                self.remoteActive = false
                timer.dropSession(notice: "The timer was stopped in Moxie, so it's saved there.")
            case let (session?, remote?) where self.remoteActive:
                // Paused / resumed in Moxie.
                if remote.isPaused, session.isRunning { timer.pause(mirror: false) }
                if !remote.isPaused, !session.isRunning { timer.resume(mirror: false) }
            default:
                break
            }
        }
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

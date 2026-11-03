import Foundation
import XCTest
@testable import MoxieTimer

/// Base class for every test in this target.
///
/// Safety net: the stores under test persist to `UserDefaults.standard` and `HistoryStore` /
/// `StatsStore` write files under `~/Library/Application Support/MoxieTimer`, which is the SAME
/// folder the installed app uses. xctest's own defaults domain is already separate from the app's
/// bundle id, but *files* are not sandboxed by that — only `CFFIXED_USER_HOME`/`HOME` pointed at a
/// scratch directory (done by `scripts/test.sh`) keeps a test run from touching the user's real
/// history. `setUp` asserts that redirection actually happened before any test body runs, and fails
/// fast (rather than silently running against real data) if it didn't.
@MainActor
class MoxieTestCase: XCTestCase {
    /// Keys the stores under test read/write in `UserDefaults.standard`. Cleared before and after
    /// every test so no test observes another's leftovers, and so this run never leaves anything
    /// behind in the (temporary, but still real) defaults domain.
    static let defaultsKeysUnderTest = [
        "timerState", "focusState", "focusWarmup",
        "mcpLiveTimer", "mcpRemoteActive",
        "inboxOnlyMine", "inboxIncludeTickets", "inboxFilterClient", "inboxFilterProject",
        "holdForReview", "userEmail", "apiBaseURL",
    ]

    /// The account's real home from the user database — not affected by HOME / CFFIXED_USER_HOME.
    static let realHome: String = {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "/Users" }
        return URL(fileURLWithPath: String(cString: dir)).standardizedFileURL.path
    }()

    /// True when `path` is the real home or anything inside it.
    static func isInRealHome(_ path: String) -> Bool {
        let path = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        return path == realHome || path.hasPrefix(realHome + "/")
    }

    override class func setUp() {
        super.setUp()
        let homes = [NSHomeDirectory(), FileManager.default.homeDirectoryForCurrentUser.path]
        precondition(!homes.contains(where: isInRealHome),
                     "Refusing to run tests against the real home directory (\(homes)). " +
                     "Run via scripts/test.sh, which sets CFFIXED_USER_HOME to a temp directory.")
    }

    override func setUp() {
        super.setUp()
        clearDefaults()
        clearSupportFiles()
    }

    override func tearDown() {
        clearDefaults()
        clearSupportFiles()
        super.tearDown()
    }

    private func clearDefaults() {
        let defaults = UserDefaults.standard
        for key in Self.defaultsKeysUnderTest { defaults.removeObject(forKey: key) }
    }

    /// `HistoryStore`/`StatsStore` persist to `~/Library/Application Support/MoxieTimer` (under the
    /// redirected, temporary home set by `scripts/test.sh`). Each `HistoryStore()`/`StatsStore()` loads
    /// whatever is there at init, so without wiping it here, one test's entries would leak into the next.
    private func clearSupportFiles() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        // Second check right before deleting: never remove anything inside the real home.
        guard !Self.isInRealHome(base.path) else {
            preconditionFailure("Refusing to delete \(base.path): it's inside the real home directory.")
        }
        try? FileManager.default.removeItem(at: base)
    }

    /// `AppSettings` configured for tests: review mode on (no network path), a harmless base URL/email,
    /// and the Keychain seam enabled so it never touches the real Keychain item.
    func makeSettings(holdForReview: Bool = true, configured: Bool = false) -> AppSettings {
        let settings = AppSettings(skipKeychainForTesting: true)
        settings.holdForReview = holdForReview
        if configured {
            settings.apiKey = "test-key"
            settings.userEmail = "test@example.com"
            settings.baseURL = "https://example.invalid/api/public"
        } else {
            settings.apiKey = ""
            settings.userEmail = ""
            settings.baseURL = ""
        }
        return settings
    }
}

// MARK: - Fixtures

func makeRef(_ name: String, id: String? = nil) -> Ref {
    Ref(id: id ?? name, name: name)
}

func makeTask(id: String, name: String, client: Ref? = nil, project: Ref? = nil, sourceTicketId: String? = nil) -> MoxieTask {
    MoxieTask(
        id: id, name: name, projectId: project?.id, status: nil, parentTaskId: nil,
        clientId: client?.id,
        client: client.map { MoxieTask.Micro(id: $0.id, name: $0.name) },
        project: project.map { MoxieTask.Micro(id: $0.id, name: $0.name) },
        sourceTicketId: sourceTicketId
    )
}

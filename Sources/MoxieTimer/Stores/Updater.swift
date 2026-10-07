import AppKit
import CryptoKit
import Observation

/// Self-updater backed by GitHub Releases. Checks `releases/latest`, and if the tag is newer than the
/// running version, downloads the `.zip` asset, verifies it against the `.zip.sha256` asset,
/// swaps the app bundle in place and relaunches.
@MainActor @Observable
final class Updater {
    static let repository = "flyingwebie/moxie-timer"
    private static let checkInterval: TimeInterval = 6 * 3600

    struct Release: Equatable {
        let version: String
        let notes: String
        let pageURL: URL
        let zipURL: URL
        let checksumURL: URL?
    }

    enum State: Equatable {
        case idle, checking, upToDate, downloading, installing
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var latest: Release?
    private(set) var lastChecked: Date?

    var automaticallyChecks: Bool {
        didSet {
            UserDefaults.standard.set(automaticallyChecks, forKey: "autoUpdateCheck")
            schedule()
        }
    }

    @ObservationIgnored private var timer: Timer?

    init() {
        automaticallyChecks = UserDefaults.standard.object(forKey: "autoUpdateCheck") as? Bool ?? true
        schedule()
        // Skip the launch check for `swift run` builds, which have no bundle version to compare.
        if automaticallyChecks, Bundle.main.bundleURL.pathExtension == "app" {
            Task { await check(userInitiated: false) }
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var isBusy: Bool {
        state == .checking || state == .downloading || state == .installing
    }

    // MARK: Checking

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        state = .checking
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!, timeoutInterval: 30)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("MoxieTimer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw UpdateError("No response from GitHub.") }
            guard http.statusCode == 200 else { throw UpdateError("GitHub returned HTTP \(http.statusCode).") }

            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(GitHubRelease.self, from: data)
            lastChecked = .now

            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.isVersion(version, newerThan: currentVersion),
                  let zip = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                latest = nil
                state = .upToDate
                return
            }
            latest = Release(
                version: version,
                notes: release.body ?? "",
                pageURL: release.htmlUrl,
                zipURL: zip.browserDownloadUrl,
                checksumURL: release.assets.first { $0.name == zip.name + ".sha256" }?.browserDownloadUrl
            )
            state = .idle
        } catch {
            // Background checks fail quietly (offline, rate-limited…); only report ones the user asked for.
            state = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    private func schedule() {
        timer?.invalidate()
        timer = nil
        guard automaticallyChecks else { return }
        let timer = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.check(userInitiated: false) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Installing

    func installUpdate() async {
        guard let release = latest, !isBusy else { return }
        let appURL = Bundle.main.bundleURL
        let fileManager = FileManager.default

        guard appURL.pathExtension == "app" else {
            state = .failed("Updates only work from MoxieTimer.app, not a development build.")
            return
        }
        guard !appURL.path.contains("/AppTranslocation/") else {
            state = .failed("Move MoxieTimer.app into Applications, reopen it, then update.")
            return
        }
        guard fileManager.isWritableFile(atPath: appURL.deletingLastPathComponent().path) else {
            state = .failed("No permission to replace the app in \(appURL.deletingLastPathComponent().path).")
            return
        }

        state = .downloading
        do {
            // A scratch folder on the same volume as the app, so the final swap is an atomic rename.
            let work = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
            defer { try? fileManager.removeItem(at: work) }

            let (downloaded, response) = try await URLSession.shared.download(from: release.zipURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }
            let zip = work.appending(path: "update.zip")
            try fileManager.moveItem(at: downloaded, to: zip)

            if let checksumURL = release.checksumURL {
                let (checksumData, _) = try await URLSession.shared.data(from: checksumURL)
                let expected = String(decoding: checksumData, as: UTF8.self)
                    .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() }
                let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
                guard expected == actual else { throw UpdateError("The download didn't match its checksum.") }
            }

            state = .installing
            let extracted = work.appending(path: "extracted")
            try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path])
            let newApp = extracted.appending(path: "MoxieTimer.app")
            guard let bundle = Bundle(url: newApp),
                  bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError("The download doesn't contain Moxie Timer.")
            }
            try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

            _ = try fileManager.replaceItemAt(appURL, withItemAt: newApp)
            relaunch(appURL)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Waits for this process to exit, then reopens the (replaced) bundle.
    private func relaunch(_ appURL: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"", appURL.path]
        do {
            try process.run()
            NSApp.terminate(nil)
        } catch {
            state = .failed("Updated — please reopen Moxie Timer.")
        }
    }

    // MARK: Helpers

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private nonisolated static func run(_ path: String, _ arguments: [String]) async throws {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdateError("\(URL(fileURLWithPath: path).lastPathComponent) failed (\(process.terminationStatus)).")
            }
        }.value
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadUrl: URL
    }

    let tagName: String
    let body: String?
    let htmlUrl: URL
    let assets: [Asset]
}

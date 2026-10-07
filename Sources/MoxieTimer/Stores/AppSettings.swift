import Foundation
import Observation
import ServiceManagement

@MainActor @Observable
final class AppSettings {
    @ObservationIgnored private let defaults = UserDefaults.standard
    /// Called when a window-related preference changes so the panel can re-apply them.
    @ObservationIgnored var onWindowPreferencesChange: (() -> Void)?

    var apiKey: String {
        didSet { Keychain.set(apiKey.trimmingCharacters(in: .whitespacesAndNewlines), for: "apiKey") }
    }

    var userEmail: String {
        didSet { defaults.set(userEmail, forKey: "userEmail") }
    }

    var baseURL: String {
        didSet { defaults.set(baseURL, forKey: "apiBaseURL") }
    }

    var keepOnTop: Bool {
        didSet { defaults.set(keepOnTop, forKey: "keepOnTop"); onWindowPreferencesChange?() }
    }

    var showOnAllSpaces: Bool {
        didSet { defaults.set(showOnAllSpaces, forKey: "showOnAllSpaces"); onWindowPreferencesChange?() }
    }

    var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MoxieTimer: launch at login failed: \(error)")
            }
        }
    }

    init() {
        apiKey = Keychain.get("apiKey") ?? ""
        userEmail = defaults.string(forKey: "userEmail") ?? ""
        baseURL = defaults.string(forKey: "apiBaseURL") ?? ""
        keepOnTop = defaults.object(forKey: "keepOnTop") as? Bool ?? true
        showOnAllSpaces = defaults.object(forKey: "showOnAllSpaces") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var isConfigured: Bool {
        makeAPI() != nil && !userEmail.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func makeAPI() -> MoxieAPI? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let url = Self.normalizedBaseURL(baseURL) else { return nil }
        return MoxieAPI(baseURL: url, apiKey: key)
    }

    /// Moxie shows a workspace-specific base URL (e.g. `https://pod00.withmoxie.dev/api/public`).
    /// Endpoint paths start with `public/action/…`, so trim anything from `/public` onward.
    static func normalizedBaseURL(_ raw: String) -> URL? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        if let range = text.range(of: "/public", options: .backwards) { text = String(text[..<range.lowerBound]) }
        while text.hasSuffix("/") { text.removeLast() }
        guard let url = URL(string: text), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }
}

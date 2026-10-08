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

    /// Collapse the open card when clicking anywhere outside the widget.
    var closeOnOutsideClick: Bool {
        didSet { defaults.set(closeOnOutsideClick, forKey: "closeOnOutsideClick") }
    }

    /// Keep entries on this Mac until the end-of-day review instead of sending each one immediately.
    var holdForReview: Bool {
        didSet { defaults.set(holdForReview, forKey: "holdForReview") }
    }

    /// Minutes after midnight for the end-of-day review prompt.
    var reviewMinutes: Int {
        didSet { defaults.set(reviewMinutes, forKey: "reviewMinutes") }
    }

    var trackingReminders: Bool {
        didSet { defaults.set(trackingReminders, forKey: "trackingReminders") }
    }

    var workStartMinutes: Int {
        didSet { defaults.set(workStartMinutes, forKey: "workStartMinutes") }
    }

    var workEndMinutes: Int {
        didSet { defaults.set(workEndMinutes, forKey: "workEndMinutes") }
    }

    /// Calendar weekdays (1 = Sunday … 7 = Saturday).
    var workDays: Set<Int> {
        didSet { defaults.set(Array(workDays), forKey: "workDays") }
    }

    /// Watch for distracting apps/sites while a timer runs.
    var watchDistractions: Bool {
        didSet { defaults.set(watchDistractions, forKey: "watchDistractions") }
    }

    /// Distracting apps: bundle identifier → display name.
    var distractionApps: [String: String] {
        didSet { defaults.set(distractionApps, forKey: "distractionApps") }
    }

    /// Words matched against browser/window titles (needs window titles enabled).
    var distractionKeywords: [String] {
        didSet { defaults.set(distractionKeywords, forKey: "distractionKeywords") }
    }

    // MARK: Pet
    var petEnabled: Bool { didSet { defaults.set(petEnabled, forKey: "petEnabled") } }
    var petName: String { didSet { defaults.set(petName, forKey: "petName") } }
    /// PetSpecies raw value.
    var petSpecies: String { didSet { defaults.set(petSpecies, forKey: "petSpecies") } }
    /// PetTone raw value.
    var petTone: String { didSet { defaults.set(petTone, forKey: "petTone") } }
    /// Free-text description of how the pet should talk (used by AI lines).
    var petStyle: String { didSet { defaults.set(petStyle, forKey: "petStyle") } }
    /// One per line; mixed into praise and drift lines.
    var petPraiseLines: String { didSet { defaults.set(petPraiseLines, forKey: "petPraiseLines") } }
    var petDriftLines: String { didSet { defaults.set(petDriftLines, forKey: "petDriftLines") } }
    var petUseAI: Bool { didSet { defaults.set(petUseAI, forKey: "petUseAI") } }
    /// PetAccessory raw value or "auto".
    var petAccessory: String { didSet { defaults.set(petAccessory, forKey: "petAccessory") } }

    /// Ticket type label used when creating tickets from the widget (empty = Moxie's default).
    var ticketDefaultType: String { didSet { defaults.set(ticketDefaultType, forKey: "ticketDefaultType") } }

    /// Status set on a ticket when you finish it from the Focus tab.
    var ticketDoneStatus: String {
        didSet { defaults.set(ticketDoneStatus, forKey: "ticketDoneStatus") }
    }

    /// "Still on it?" check-in interval while a timer runs; 0 = off.
    var checkInMinutes: Int {
        didSet { defaults.set(checkInMinutes, forKey: "checkInMinutes") }
    }

    /// Read window titles (Accessibility permission) to improve project suggestions.
    var useWindowTitles: Bool {
        didSet { defaults.set(useWindowTitles, forKey: "useWindowTitles") }
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
        closeOnOutsideClick = defaults.object(forKey: "closeOnOutsideClick") as? Bool ?? true
        holdForReview = defaults.object(forKey: "holdForReview") as? Bool ?? true
        reviewMinutes = defaults.object(forKey: "reviewMinutes") as? Int ?? 17 * 60 + 30
        trackingReminders = defaults.object(forKey: "trackingReminders") as? Bool ?? true
        workStartMinutes = defaults.object(forKey: "workStartMinutes") as? Int ?? 9 * 60
        workEndMinutes = defaults.object(forKey: "workEndMinutes") as? Int ?? 18 * 60
        workDays = Set(defaults.array(forKey: "workDays") as? [Int] ?? [2, 3, 4, 5, 6])
        useWindowTitles = defaults.object(forKey: "useWindowTitles") as? Bool ?? false
        watchDistractions = defaults.object(forKey: "watchDistractions") as? Bool ?? true
        distractionApps = defaults.dictionary(forKey: "distractionApps") as? [String: String] ?? [:]
        distractionKeywords = defaults.stringArray(forKey: "distractionKeywords")
            ?? ["youtube", "reddit", "facebook", "instagram", "netflix", "tiktok", "twitch"]
        checkInMinutes = defaults.object(forKey: "checkInMinutes") as? Int ?? 20
        ticketDoneStatus = defaults.string(forKey: "ticketDoneStatus") ?? "Closed"
        ticketDefaultType = defaults.string(forKey: "ticketDefaultType") ?? ""
        petEnabled = defaults.object(forKey: "petEnabled") as? Bool ?? true
        petName = defaults.string(forKey: "petName") ?? "Blip"
        petSpecies = defaults.string(forKey: "petSpecies") ?? "blob"
        petTone = defaults.string(forKey: "petTone") ?? "warm"
        petStyle = defaults.string(forKey: "petStyle") ?? ""
        petPraiseLines = defaults.string(forKey: "petPraiseLines") ?? ""
        petDriftLines = defaults.string(forKey: "petDriftLines") ?? ""
        petUseAI = defaults.object(forKey: "petUseAI") as? Bool ?? false
        petAccessory = defaults.string(forKey: "petAccessory") ?? "auto"
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func isWorkTime(_ date: Date) -> Bool {
        let calendar = Calendar.current
        guard workDays.contains(calendar.component(.weekday, from: date)) else { return false }
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        return minutes >= workStartMinutes && minutes < workEndMinutes
    }

    /// Today's work-hours window, if today is a work day.
    func workWindow(on day: Date) -> DateInterval? {
        let calendar = Calendar.current
        guard workDays.contains(calendar.component(.weekday, from: day)) else { return nil }
        let start = calendar.startOfDay(for: day)
        let from = start.addingTimeInterval(TimeInterval(workStartMinutes * 60))
        let to = start.addingTimeInterval(TimeInterval(workEndMinutes * 60))
        return to > from ? DateInterval(start: from, end: to) : nil
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

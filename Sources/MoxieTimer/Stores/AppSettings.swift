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

    // MARK: Pet voice
    /// PetVoice.Engine raw value.
    var petVoiceEngine: String { didSet { defaults.set(petVoiceEngine, forKey: "petVoiceEngine") } }
    /// Speak only the important moments (task done, level up, firm drift nudges…), not every line.
    var petVoiceImportantOnly: Bool { didSet { defaults.set(petVoiceImportantOnly, forKey: "petVoiceImportantOnly") } }
    var petVoiceVolume: Double { didSet { defaults.set(petVoiceVolume, forKey: "petVoiceVolume") } }
    /// 0.5…2, 1 = normal.
    var petVoiceSpeed: Double { didSet { defaults.set(petVoiceSpeed, forKey: "petVoiceSpeed") } }
    /// Semitones, -8…+8.
    var petVoicePitch: Double { didSet { defaults.set(petVoicePitch, forKey: "petVoicePitch") } }
    /// AVSpeechSynthesisVoice identifier; empty = system default.
    var petSystemVoice: String { didSet { defaults.set(petSystemVoice, forKey: "petSystemVoice") } }
    /// Hugging Face repo of the KittenTTS model.
    var petKittenModel: String { didSet { defaults.set(petKittenModel, forKey: "petKittenModel") } }
    /// KittenTTS 2 weights: "emb4" (smaller) or "packed" (lossless).
    var petKittenWeights: String { didSet { defaults.set(petKittenWeights, forKey: "petKittenWeights") } }
    var petKittenVoice: String { didSet { defaults.set(petKittenVoice, forKey: "petKittenVoice") } }
    /// KittenTTS 2 decoding preset: "stable" or "expressive".
    var petKittenPreset: String { didSet { defaults.set(petKittenPreset, forKey: "petKittenPreset") } }
    /// Send [emotion], <event> and (((emphasis))) markup to the voice.
    var petVoiceExpressions: Bool { didSet { defaults.set(petVoiceExpressions, forKey: "petVoiceExpressions") } }
    /// Minutes without speaking before the KittenTTS model is unloaded; 0 = keep it loaded.
    var petKittenKeepLoadedMinutes: Int { didSet { defaults.set(petKittenKeepLoadedMinutes, forKey: "petKittenKeepLoadedMinutes") } }
    /// Python with `kittenml` installed; empty = the app's own environment.
    var petKittenPython: String { didSet { defaults.set(petKittenPython, forKey: "petKittenPython") } }

    /// Detect calls (microphone in use) and pause breaks/nudges while one is on.
    var detectCalls: Bool { didSet { defaults.set(detectCalls, forKey: "detectCalls") } }
    /// Apps whose microphone use isn't a call (always-on recorders, dictation). Comma-separated, matched loosely.
    var callIgnoreList: String { didSet { defaults.set(callIgnoreList, forKey: "callIgnoreList") } }

    /// When finishing in the Focus tab, also complete the task / close the ticket in Moxie. Off: Moxie is left alone.
    var completeInMoxie: Bool { didSet { defaults.set(completeInMoxie, forKey: "completeInMoxie") } }

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
        completeInMoxie = defaults.object(forKey: "completeInMoxie") as? Bool ?? false
        detectCalls = defaults.object(forKey: "detectCalls") as? Bool ?? true
        callIgnoreList = defaults.string(forKey: "callIgnoreList")
            ?? "screenpipe, krisp, whisper, dictation, siri, corespeech, voice memos, voicememos"
        petEnabled = defaults.object(forKey: "petEnabled") as? Bool ?? true
        petName = defaults.string(forKey: "petName") ?? "Blip"
        petSpecies = defaults.string(forKey: "petSpecies") ?? "blob"
        petTone = defaults.string(forKey: "petTone") ?? "warm"
        petStyle = defaults.string(forKey: "petStyle") ?? ""
        petPraiseLines = defaults.string(forKey: "petPraiseLines") ?? ""
        petDriftLines = defaults.string(forKey: "petDriftLines") ?? ""
        petUseAI = defaults.object(forKey: "petUseAI") as? Bool ?? false
        petAccessory = defaults.string(forKey: "petAccessory") ?? "auto"
        petVoiceEngine = defaults.string(forKey: "petVoiceEngine") ?? "off"
        petVoiceImportantOnly = defaults.object(forKey: "petVoiceImportantOnly") as? Bool ?? false
        petVoiceVolume = defaults.object(forKey: "petVoiceVolume") as? Double ?? 0.8
        petVoiceSpeed = defaults.object(forKey: "petVoiceSpeed") as? Double ?? 1
        petVoicePitch = defaults.object(forKey: "petVoicePitch") as? Double ?? 0
        petSystemVoice = defaults.string(forKey: "petSystemVoice") ?? ""
        petKittenModel = defaults.string(forKey: "petKittenModel") ?? "KittenML/kitten-tts-2"
        petKittenWeights = defaults.string(forKey: "petKittenWeights") ?? "emb4"
        petKittenVoice = defaults.string(forKey: "petKittenVoice") ?? "Kiki"
        petKittenPreset = defaults.string(forKey: "petKittenPreset") ?? "expressive"
        petVoiceExpressions = defaults.object(forKey: "petVoiceExpressions") as? Bool ?? true
        petKittenPython = defaults.string(forKey: "petKittenPython") ?? ""
        petKittenKeepLoadedMinutes = defaults.object(forKey: "petKittenKeepLoadedMinutes") as? Int ?? 60
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

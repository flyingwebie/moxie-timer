import AppKit
import CoreAudio
import Observation

/// Knows when you're on a call, so breaks and nudges can wait while the timer keeps tracking.
/// Detection: another app is using the microphone (Zoom, Meet in a browser, Teams, Slack huddles, FaceTime…).
/// No permission is needed — macOS reports *that* the mic is in use (and, on 14.2+, by which app), never the audio.
@MainActor @Observable
final class CallDetector {
    /// In a call right now (detected or switched on by hand).
    private(set) var inCall = false
    /// Apps currently using the microphone (after the ignore list), for display.
    private(set) var micApps: [String] = []

    /// "I'm in a call" from the menu bar, for calls the detection can't see.
    var manualCall = false {
        didSet { update(now: .now) }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var detected = false
    @ObservationIgnored private var activeSince: Date?
    @ObservationIgnored private var quietSince: Date?
    @ObservationIgnored private var poller: Timer?

    /// The mic must be busy this long before it counts as a call (skips quick dictation)…
    private static let startAfter: TimeInterval = 15
    /// …and quiet this long before the call is considered over (skips short mutes/reconnects).
    private static let endAfter: TimeInterval = 20

    init(settings: AppSettings) {
        self.settings = settings
        let poller = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(now: .now) }
        }
        RunLoop.main.add(poller, forMode: .common)
        self.poller = poller
    }

    private func update(now: Date) {
        let apps = settings.detectCalls ? Self.microphoneUsers(ignoring: ignoreList) : []
        if apps != micApps { micApps = apps }

        if !apps.isEmpty {
            quietSince = nil
            let since = activeSince ?? now
            activeSince = since
            if now.timeIntervalSince(since) >= Self.startAfter { detected = true }
        } else {
            activeSince = nil
            let since = quietSince ?? now
            quietSince = since
            if now.timeIntervalSince(since) >= Self.endAfter { detected = false }
        }

        let newValue = manualCall || (settings.detectCalls && detected)
        if newValue != inCall {
            inCall = newValue
            if !newValue { manualCall = false }
            onChange?()
        }
    }

    private var ignoreList: [String] {
        settings.callIgnoreList
            .split(whereSeparator: { $0 == "," || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }

    // MARK: Microphone

    /// Names of apps (other than this one) currently capturing audio input, minus ignored ones.
    static func microphoneUsers(ignoring ignored: [String]) -> [String] {
        if #available(macOS 14.2, *) {
            return processesUsingInput().filter { app in
                !ignored.contains { isMatch($0, name: app.name, bundleId: app.bundleId) }
            }
            .map(\.name)
            .reduce(into: [String]()) { names, name in if !names.contains(name) { names.append(name) } }
        }
        // Older macOS: only "the default mic is in use by someone".
        return defaultInputIsRunning() ? ["Microphone"] : []
    }

    /// Exact app name, or (for entries of 4+ letters) part of the name or bundle id — so "cap" ignores Cap but not CapCut.
    static func isMatch(_ entry: String, name: String, bundleId: String) -> Bool {
        let name = name.lowercased(), bundleId = bundleId.lowercased()
        if name == entry || bundleId == entry || bundleId.split(separator: ".").contains(Substring(entry)) { return true }
        return entry.count >= 4 && (name.contains(entry) || bundleId.contains(entry))
    }

    /// Adds an app to the ignore list (from Settings).
    func ignore(_ name: String) {
        let entry = name.lowercased()
        guard !ignoreList.contains(entry) else { return }
        settings.callIgnoreList += (settings.callIgnoreList.isEmpty ? "" : ", ") + entry
        update(now: .now)
    }

    /// Everything using the mic, ignored or not, for the Settings list.
    var allMicApps: [String] { Self.microphoneUsers(ignoring: []) }

    func isIgnored(_ name: String) -> Bool {
        ignoreList.contains { Self.isMatch($0, name: name, bundleId: "") }
    }

    @available(macOS 14.2, *)
    private static func processesUsingInput() -> [(name: String, bundleId: String)] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        let me = ProcessInfo.processInfo.processIdentifier
        return objects.compactMap { object -> (String, String)? in
            guard uint32(object, kAudioProcessPropertyIsRunningInput) == 1 else { return nil }
            let pid = pid_t(bitPattern: uint32(object, kAudioProcessPropertyPID) ?? 0)
            guard pid != me else { return nil }
            let bundleId = string(object, kAudioProcessPropertyBundleID) ?? ""
            // Browser/helper processes: show the parent app's name.
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? NSWorkspace.shared.runningApplications
                .first { !bundleId.isEmpty && bundleId.hasPrefix($0.bundleIdentifier ?? "\u{0}") }?.localizedName ?? bundleId
            return (name.isEmpty ? "An app" : name, bundleId)
        }
    }

    private static func defaultInputIsRunning() -> Bool {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        return uint32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}

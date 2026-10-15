import AVFoundation
import Observation

/// Speaks the pet's lines, with a built-in Mac voice or a local AI model (KittenTTS, Kokoro, VoxCPM2 or VibeVoice).
/// Local models run in a small Python worker that keeps the model loaded and is shut down when idle.
/// Each local engine has its own Python environment under ~/.moxie-timer/voice.
@MainActor @Observable
final class PetVoice {
    enum Engine: String, CaseIterable, Identifiable {
        case off, system, kitten, kokoro, voxcpm, vibevoice
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .system: return "Mac voices"
            case .kitten: return "KittenTTS (local AI)"
            case .kokoro: return "Kokoro (local AI, fast)"
            case .voxcpm: return "VoxCPM2 (local AI)"
            case .vibevoice: return "VibeVoice (local AI)"
            }
        }

        var isLocal: Bool { self != .off && self != .system }

        /// The name used in "Install …" and status messages.
        var modelName: String {
            switch self {
            case .off, .system, .kitten: return "KittenTTS"
            case .kokoro: return "Kokoro"
            case .voxcpm: return "VoxCPM2"
            case .vibevoice: return "VibeVoice"
            }
        }

        /// Folder of the engine's Python environment in voiceDirectory. KittenTTS keeps the original "venv".
        var environmentName: String {
            switch self {
            case .off, .system, .kitten: return "venv"
            default: return rawValue
            }
        }

        /// What `pip install` gets. Kokoro's English model (spaCy) is listed so it isn't downloaded at runtime.
        var packages: [String] {
            switch self {
            case .off, .system, .kitten: return ["kittenml", "soundfile"]
            case .kokoro:
                return ["kokoro>=0.9.4", "inno-kokoro", "soundfile",
                        "en-core-web-sm @ https://github.com/explosion/spacy-models/releases/download/en_core_web_sm-3.8.0/en_core_web_sm-3.8.0-py3-none-any.whl"]
            case .voxcpm: return ["voxcpm", "soundfile"]
            case .vibevoice: return ["torch", "transformers>=5.19", "diffusers", "accelerate", "soundfile", "librosa"]
            }
        }

        /// The engine renders a line in several seconds, so the pet prepares lines ahead.
        var isSlow: Bool { self == .kitten || self == .voxcpm || self == .vibevoice }
    }

    struct KittenModel: Identifiable {
        let id: String
        let title: String
        let detail: String
        var isExpressive: Bool { id.contains("kitten-tts-2") }
    }

    static let kittenModels = [
        KittenModel(id: "KittenML/kitten-tts-2", title: "KittenTTS 2",
                    detail: "47 voices with emotions and laughs. Needs about 6 GB of memory while loaded and takes 6–10 seconds per line, so the pet prepares its next lines in the background."),
        KittenModel(id: "KittenML/kitten-tts-mini-0.8", title: "Mini (80 MB)",
                    detail: "Fast and light: speaks almost instantly, 8 voices, no expressions."),
        KittenModel(id: "KittenML/kitten-tts-micro-0.8", title: "Micro (41 MB)", detail: "Lighter still, 8 voices, no expressions."),
        KittenModel(id: "KittenML/kitten-tts-nano-0.8-int8", title: "Nano (25 MB)", detail: "Smallest and fastest, 8 voices, no expressions."),
    ]

    /// KittenTTS 2's built-in voices with their character, as documented by KittenML.
    static let kittenVoices: [(name: String, detail: String)] = [
        ("Bella", "female"), ("Jasper", "male"), ("Luna", "female"), ("Bruno", "male"), ("Rosie", "female"),
        ("Hugo", "male"), ("Kiki", "female"), ("Leo", "male"),
        ("Matthew", "exhausted mechanic"), ("Elliot", "grieving young man"), ("Willow", "hushed young woman"),
        ("Dolores", "Southern elderly woman"), ("Victor", "controlled fury, older man"), ("Dante", "playful, smooth young man"),
        ("Alfred", "tender older man"), ("Saoirse", "joyful Irish woman"), ("Claire", "playful professional woman"),
        ("Raven", "controlled fury, young woman"), ("Marcus", "smooth radio DJ"), ("Herbert", "wise elderly professor"),
        ("Diana", "stern military officer"), ("Laurence", "dramatic stage actor"), ("Maeve", "cozy storyteller"),
        ("Walter", "warm grandfather"), ("Edith", "soft grandmother"), ("Miles", "gentle librarian"),
        ("Grace", "soothing nurse"), ("Reginald", "elderly diplomat"), ("Iris", "hushed museum guide"),
        ("Frank", "gravelly war veteran"), ("Serena", "gentle yoga instructor"), ("Julian", "dreamy poet"),
        ("Eleanor", "somber historian"), ("Otis", "blues musician"), ("Vincent", "hushed museum guide"),
        ("Martha", "radio journalist"), ("Sable", "hushed conspirator"), ("Victoria", "regal narrator"),
        ("Italian", "Italiano"), ("Spanish", "Español"), ("French", "Français"), ("German", "Deutsch"),
        ("Portuguese", "Português"), ("Russian", "Русский"), ("Chinese", "中文"), ("Arabic", "العربية"), ("Hindi", "हिन्दी"),
    ]
    static let languageVoices: Set<String> = ["Italian", "Spanish", "French", "German", "Portuguese", "Russian", "Chinese", "Arabic", "Hindi"]
    static let legacyVoices = ["Bella", "Jasper", "Luna", "Bruno", "Rosie", "Hugo", "Kiki", "Leo"]

    /// Kokoro's English voices. The id's first letter is the accent (a = American, b = British), the second the gender.
    static let kokoroVoices = [
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore", "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael", "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily", "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
    ]

    static func kokoroTitle(_ id: String) -> String {
        let parts = id.split(separator: "_")
        guard parts.count == 2, let code = parts.first, code.count == 2 else { return id }
        let accent = code.first == "b" ? "British" : "American"
        let gender = code.last == "m" ? "male" : "female"
        return "\(parts[1].capitalized) — \(accent), \(gender)"
    }

    /// VibeVoice has no built-in voices: it copies a short recording. These are Microsoft's demo recordings.
    static let vibeVoices: [(name: String, file: String, detail: String)] = [
        ("Alice", "en-Alice_woman", "woman"), ("Maya", "en-Maya_woman", "woman"),
        ("Carter", "en-Carter_man", "man"), ("Frank", "en-Frank_man", "man"), ("Samuel", "in-Samuel_man", "man, Indian English"),
    ]

    enum LocalState: Equatable {
        case unknown, notInstalled, installing, installed, loading, ready, failed(String)
    }

    /// The state of the current local engine: its environment, and whether its model is loaded.
    private(set) var localState: LocalState = .unknown
    /// Recent output of the installer, for Settings.
    private(set) var installLog = ""
    private(set) var isSpeaking = false
    private(set) var isGenerating = false
    private(set) var lastError: String?

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let ai: AIService
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private var synthDelegate: SynthDelegate?
    /// Mac-voice utterances still to finish. The synthesizer reports idle between them, so count them instead.
    @ObservationIgnored private var pendingUtterances: [ObjectIdentifier: AVSpeechUtterance] = [:]
    /// Stopped utterances stay alive until their late callbacks arrive, so their ids can't be reused meanwhile.
    @ObservationIgnored private var retiredUtterances: [AVSpeechUtterance] = []
    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private var player: AVAudioPlayerNode?
    @ObservationIgnored private var timePitch: AVAudioUnitTimePitch?
    @ObservationIgnored private var worker: Worker?
    @ObservationIgnored private var workerID: UUID?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued: String?
    @ObservationIgnored private var lastUse = Date.distantPast
    @ObservationIgnored private var idleTimer: Timer?
    /// The engine whose environment is being installed (the user may switch engines meanwhile).
    @ObservationIgnored private var installingEngine: Engine?


    init(settings: AppSettings, ai: AIService) {
        self.settings = settings
        self.ai = ai
        let delegate = SynthDelegate(onEnd: { [weak self] utterance in
            guard let self, self.pendingUtterances.removeValue(forKey: utterance) != nil, self.pendingUtterances.isEmpty else { return }
            self.isSpeaking = false
        })
        synthDelegate = delegate
        synthesizer.delegate = delegate
        refreshLocalState()

        let idleTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIfIdle() }
        }
        RunLoop.main.add(idleTimer, forMode: .common)
        self.idleTimer = idleTimer

        if engine.isLocal, settings.petKittenKeepLoadedMinutes == 0, localState == .installed {
            Task { await warmUp() }
        }
    }

    var engine: Engine { Engine(rawValue: settings.petVoiceEngine) ?? .off }
    var kittenModel: KittenModel { Self.kittenModels.first { $0.id == settings.petKittenModel } ?? Self.kittenModels[0] }

    /// Whether the current voice understands [emotion] / <event> markup natively.
    var understandsExpressions: Bool { engine == .kitten && kittenModel.isExpressive && settings.petVoiceExpressions }

    /// Whether lines should be voiced ahead of time: the local model is loaded and slow enough to need it.
    var preparesAhead: Bool { engine.isSlow && localState == .ready }

    /// The engine picker changed: the running worker belongs to the old engine's Python.
    func engineChanged() {
        stop()
        unload()
        clearCache()
        lastError = nil
    }

    // MARK: Speaking

    /// Says a pet line (markup included). A newer line replaces one that hasn't started yet.
    func speak(_ text: String) {
        guard engine != .off, PetSpeech.hasWords(text) else { return }
        lastUse = .now
        lastError = nil
        switch engine {
        case .off: return
        case .system: speakWithSystem(text)
        case .kitten, .kokoro, .voxcpm, .vibevoice: speakWithModel(text)
        }
    }

    func stop() {
        generation += 1
        queued = nil
        playWhenPrepared = nil
        retireUtterances()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        isSpeaking = false
    }

    // MARK: Mac voices

    /// Installed voices for the picker, best quality first within each language.
    static func systemVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { ($0.language, -$0.quality.rawValue, $0.name) < ($1.language, -$1.quality.rawValue, $1.name) }
    }

    private func speakWithSystem(_ text: String) {
        stop()
        let voice = AVSpeechSynthesisVoice(identifier: settings.petSystemVoice)
            ?? AVSpeechSynthesisVoice(language: Locale.preferredLanguages.first)
        let tone = Self.systemTone(for: PetSpeech.emotion(of: text))
        let segments = PetSpeech.plainSegments(PetSpeech.spoken(text))
        for (index, segment) in segments.enumerated() {
            let utterance = AVSpeechUtterance(string: segment)
            utterance.voice = voice
            let rate = AVSpeechUtteranceDefaultSpeechRate * Float(settings.petVoiceSpeed * tone.rate)
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, max(AVSpeechUtteranceMinimumSpeechRate, rate))
            utterance.pitchMultiplier = Float(min(2, max(0.5, pow(2, settings.petVoicePitch / 12) * tone.pitch)))
            utterance.volume = Float(settings.petVoiceVolume)
            if index < segments.count - 1 { utterance.postUtteranceDelay = 0.45 }
            pendingUtterances[ObjectIdentifier(utterance)] = utterance
            synthesizer.speak(utterance)
        }
        isSpeaking = !segments.isEmpty
    }

    private func retireUtterances() {
        retiredUtterances = Array(pendingUtterances.values)
        pendingUtterances.removeAll()
    }

    /// Mac voices have no emotions, so nudge pitch and pace instead.
    private static func systemTone(for emotion: String?) -> (pitch: Double, rate: Double) {
        switch emotion {
        case "excited", "joyful", "surprised": return (1.12, 1.08)
        case "nervous": return (1.06, 1.12)
        case "sad", "tender", "contemplative": return (0.94, 0.9)
        case "stern", "angry": return (0.9, 1)
        default: return (1, 1)
        }
    }

    /// VoxCPM2 takes style directions in parentheses before the line, so emotions become words.
    private static func voxStyle(for emotion: String?) -> String? {
        switch emotion {
        case "excited": return "excited and energetic"
        case "joyful": return "cheerful and happy"
        case "tender": return "soft and tender"
        case "sad": return "sad and quiet"
        case "stern": return "firm and serious"
        case "angry": return "annoyed and sharp"
        case "nervous": return "nervous and hesitant"
        case "surprised": return "surprised"
        case "contemplative": return "calm and thoughtful"
        default: return nil
        }
    }

    // MARK: Local models

    private var managedEnvironment: URL { Self.environment(for: engine) }

    private static func environment(for engine: Engine) -> URL {
        voiceDirectory.appending(path: engine.environmentName, directoryHint: .isDirectory)
    }

    /// Not under Application Support: espeak-ng (used by KittenTTS and Kokoro) can't load data from a path with a space.
    static var voiceDirectory: URL {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".moxie-timer/voice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The Python that runs the worker: the user's own (KittenTTS only), or the environment the app installed.
    var pythonPath: String {
        let custom = (settings.petKittenPython as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        return engine == .kitten && !custom.isEmpty ? custom : managedEnvironment.appending(path: "bin/python").path
    }

    var usesCustomPython: Bool { engine == .kitten && !settings.petKittenPython.trimmingCharacters(in: .whitespaces).isEmpty }

    func refreshLocalState() {
        if let installingEngine {
            if installingEngine == engine { localState = .installing; return }
        } else if localState == .installing {
            return
        }
        if worker != nil { return }
        localState = FileManager.default.isExecutableFile(atPath: pythonPath) ? .installed : .notInstalled
    }

    private func speakWithModel(_ text: String) {
        retireUtterances()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        guard localState != .installing, localState != .notInstalled else {
            lastError = "\(engine.modelName) isn't installed yet (Pet & Voice tab)."
            return
        }
        generation += 1
        let mine = generation
        let line = modelText(text)
        let key = cacheKey(line)
        // Prepared ahead of time: plays at once.
        if let file = audioCache[key] {
            touchCache(key)
            do { try play(file) } catch { lastError = error.localizedDescription }
            return
        }
        if preparingKey == key {
            playWhenPrepared = mine
            return
        }
        if isGenerating {
            queued = text
            return
        }
        isGenerating = true
        Task {
            defer {
                isGenerating = false
                if let next = queued {
                    queued = nil
                    speakWithModel(next)
                }
            }
            do {
                let file = try await render(line)
                storeInCache(key, file)
                // A newer line arrived meanwhile: skip this one.
                guard mine == generation, queued == nil else { return }
                try play(file)
            } catch {
                lastError = error.localizedDescription
                if localState == .loading { localState = .failed(error.localizedDescription) }
            }
        }
    }

    /// Generates a line's audio ahead of time, so it plays at once when the pet says it.
    /// Only while the model is already loaded, and it waits for any line being spoken.
    func prepare(_ text: String) async {
        guard engine.isLocal, PetSpeech.hasWords(text) else { return }
        let line = modelText(text)
        let key = cacheKey(line)
        guard audioCache[key] == nil, preparingKey == nil else { return }
        while isGenerating { try? await Task.sleep(for: .milliseconds(500)) }
        guard localState == .ready, let worker, worker.isRunning, audioCache[key] == nil, preparingKey == nil else { return }
        preparingKey = key
        defer { preparingKey = nil }
        do {
            let file = try await render(line)
            storeInCache(key, file)
            // The pet asked for this line while it was being prepared.
            if playWhenPrepared == generation {
                playWhenPrepared = nil
                try play(file)
            }
        } catch {
            playWhenPrepared = nil
        }
    }

    /// The text the model gets: no emoji, and markup only in a form the model performs.
    private func modelText(_ text: String) -> String {
        let spoken = PetSpeech.spoken(text)
        switch engine {
        case .kitten:
            return kittenModel.isExpressive && settings.petVoiceExpressions ? spoken : PetSpeech.display(spoken)
        case .voxcpm:
            // Voice design and mood go in one direction in parentheses, e.g. "(A warm voice, cheerful and happy)Hi!".
            let plain = PetSpeech.plainSegments(spoken).joined(separator: " … ")
            var directions: [String] = []
            if !settings.petVoxUseSample {
                let description = settings.petVoxDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                if !description.isEmpty { directions.append(description.trimmingCharacters(in: CharacterSet(charactersIn: "()."))) }
            }
            if settings.petVoiceExpressions, let style = Self.voxStyle(for: PetSpeech.emotion(of: spoken)) { directions.append(style) }
            return directions.isEmpty ? plain : "(\(directions.joined(separator: ", ")))\(plain)"
        default:
            return PetSpeech.plainSegments(spoken).joined(separator: " … ")
        }
    }

    /// Engines that change pace natively; the others are time-stretched at playback.
    private var hasNativeSpeed: Bool { engine == .kokoro || (engine == .kitten && !kittenModel.isExpressive) }
    private var playbackRate: Double { hasNativeSpeed ? 1 : settings.petVoiceSpeed }

    /// The recording the current engine copies, if it uses one.
    private var sampleForEngine: String? {
        let usesSample: Bool
        switch engine {
        case .kokoro: usesSample = settings.petKokoroVoice == "sample"
        case .voxcpm: usesSample = settings.petVoxUseSample
        case .vibevoice: usesSample = settings.petVibeVoice == "sample"
        default: usesSample = false
        }
        return usesSample ? settings.petVoiceSample : nil
    }

    private func cacheKey(_ line: String) -> String {
        var parts = [engine.rawValue, line]
        switch engine {
        case .kitten:
            let model = kittenModel
            parts += [model.id, validKittenVoice(for: model)]
            if model.isExpressive { parts += [settings.petKittenWeights, settings.petKittenPreset] } else { parts.append("\(settings.petVoiceSpeed)") }
        case .kokoro: parts += [settings.petKokoroVoice, "\(settings.petVoiceSpeed)"]
        case .vibevoice: parts.append(settings.petVibeVoice)
        default: break
        }
        if let sample = sampleForEngine { parts.append(sample) }
        return parts.joined(separator: "|")
    }

    /// The model-specific part of a worker request.
    private func modelRequest() throws -> [String: Any] {
        if let sample = sampleForEngine, sample.isEmpty || !FileManager.default.fileExists(atPath: sample) {
            throw UpdateError("Choose a voice sample first (Pet & Voice tab), or pick one of the built-in voices.")
        }
        var request: [String: Any] = ["engine": engine.rawValue]
        switch engine {
        case .kitten:
            let model = kittenModel
            request["model"] = model.id
            request["weights"] = settings.petKittenWeights
            request["voice"] = validKittenVoice(for: model)
            request["preset"] = settings.petKittenPreset
            request["normalize"] = !Self.languageVoices.contains(settings.petKittenVoice)
            if !model.isExpressive { request["speed"] = settings.petVoiceSpeed }
        case .kokoro:
            request["voice"] = Self.kokoroVoices.contains(settings.petKokoroVoice) ? settings.petKokoroVoice : "af_heart"
            request["speed"] = settings.petVoiceSpeed
        case .vibevoice:
            request["voice"] = (Self.vibeVoices.first { $0.name == settings.petVibeVoice } ?? Self.vibeVoices[0]).file
        default: break
        }
        if let sample = sampleForEngine { request["sample"] = sample }
        return request
    }

    /// Generates a line's audio. KittenTTS 2 stays whole: split into short sentences it rambles and gets slower.
    private func render(_ line: String) async throws -> URL {
        var request = try modelRequest()
        let worker = try await startWorker()
        if localState != .ready { localState = .loading }
        let out = Self.cacheDirectory.appending(path: "\(UUID().uuidString).wav")
        request["cmd"] = "speak"
        request["text"] = line
        request["out"] = out.path
        _ = try await worker.send(request, timeout: 300)
        localState = .ready
        return out
    }

    /// Generated audio, by line and voice settings. Volume, speed and pitch apply at playback, so they don't count.
    @ObservationIgnored private var audioCache: [String: URL] = [:]
    @ObservationIgnored private var cacheOrder: [String] = []
    @ObservationIgnored private var preparingKey: String?
    @ObservationIgnored private var playWhenPrepared: Int?
    private static let cacheLimit = 60

    private static let cacheDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appending(path: "moxie-pet-voice", directoryHint: .isDirectory)
        // Audio from an earlier run isn't indexed any more.
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func storeInCache(_ key: String, _ file: URL) {
        audioCache[key] = file
        touchCache(key)
        while cacheOrder.count > Self.cacheLimit {
            let old = cacheOrder.removeFirst()
            audioCache.removeValue(forKey: old).map { try? FileManager.default.removeItem(at: $0) }
        }
    }

    private func touchCache(_ key: String) {
        cacheOrder.removeAll { $0 == key }
        cacheOrder.append(key)
    }

    private func clearCache() {
        audioCache.values.forEach { try? FileManager.default.removeItem(at: $0) }
        audioCache.removeAll()
        cacheOrder.removeAll()
    }

    private func validKittenVoice(for model: KittenModel) -> String {
        let voice = settings.petKittenVoice
        if model.isExpressive { return voice }
        return Self.legacyVoices.contains(voice) ? voice : "Kiki"
    }

    private func play(_ url: URL) throws {
        let file = try AVAudioFile(forReading: url)
        let engine = audioEngine ?? AVAudioEngine()
        let player = self.player ?? AVAudioPlayerNode()
        let timePitch = self.timePitch ?? AVAudioUnitTimePitch()
        if audioEngine == nil {
            engine.attach(player)
            engine.attach(timePitch)
            audioEngine = engine
            self.player = player
            self.timePitch = timePitch
        }
        player.stop()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        timePitch.rate = Float(min(2, max(0.5, playbackRate)))
        timePitch.pitch = Float(settings.petVoicePitch * 100)
        player.volume = Float(settings.petVoiceVolume)
        if !engine.isRunning { try engine.start() }
        isSpeaking = true
        let mine = generation
        player.scheduleFile(file, at: nil) { [weak self] in
            Task { @MainActor in
                guard let self, mine == self.generation else { return }
                self.isSpeaking = false
                self.audioEngine?.pause()
            }
        }
        player.play()
    }

    private func startWorker() async throws -> Worker {
        if let worker, worker.isRunning { return worker }
        let python = pythonPath
        guard FileManager.default.isExecutableFile(atPath: python) else {
            localState = .notInstalled
            throw UpdateError("Python not found at \(python).")
        }
        let script = Self.voiceDirectory.appending(path: "voice_worker.py")
        // Replaced by voice_worker.py, which runs every engine.
        try? FileManager.default.removeItem(at: Self.voiceDirectory.appending(path: "kitten_worker.py"))
        if (try? String(contentsOf: script, encoding: .utf8)) != Self.workerScript {
            try Self.workerScript.write(to: script, atomically: true, encoding: .utf8)
        }
        localState = .loading
        let id = UUID()
        let worker = try Worker(python: python, script: script) { [weak self] in
            Task { @MainActor in
                // An old worker that was shut down must not drop the new one (it kept running, unused, with ~6 GB).
                guard let self, self.workerID == id else { return }
                self.worker = nil
                if self.localState == .loading || self.localState == .ready { self.refreshLocalState() }
            }
        }
        self.worker = worker
        workerID = id
        return worker
    }

    /// Loads the model ahead of time (and downloads it the first time).
    @discardableResult
    func warmUp() async -> Bool {
        lastUse = .now
        lastError = nil
        do {
            var request = try modelRequest()
            let worker = try await startWorker()
            localState = .loading
            request["cmd"] = "load"
            _ = try await worker.send(request, timeout: 1800)
            localState = .ready
            return true
        } catch {
            lastError = error.localizedDescription
            localState = .failed(error.localizedDescription)
            return false
        }
    }

    func unload() {
        worker?.terminate()
        worker = nil
        workerID = nil
        refreshLocalState()
    }

    private func unloadIfIdle() {
        // Shut the worker down after a while without speaking, to give the memory back.
        let minutes = settings.petKittenKeepLoadedMinutes
        guard worker != nil, minutes > 0, !isGenerating, Date.now.timeIntervalSince(lastUse) > Double(minutes) * 60 else { return }
        unload()
    }

    /// The model changed: the running worker holds the old one, so start fresh next time.
    func modelSettingsChanged() {
        unload()
        clearCache()
    }

    /// The voice changed in a way the loaded model handles itself (another voice or sample): only old audio goes.
    func voiceSettingsChanged() {
        clearCache()
    }

    // MARK: Voice sample

    /// Turns the recording the user picked into a mono 24 kHz wav (at most 30 seconds) next to the environments,
    /// so any format the Mac reads works (Voice Memos' m4a too) and moving the original doesn't break the voice.
    func importSample(from url: URL) throws {
        let input = try AVAudioFile(forReading: url)
        guard input.length > 0 else { throw UpdateError("That recording is empty.") }
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: input.processingFormat, to: format) else {
            throw UpdateError("Couldn't read that recording.")
        }
        let folder = Self.voiceDirectory.appending(path: "samples", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = url.deletingPathExtension().lastPathComponent
        let out = folder.appending(path: "\(name).wav")
        try? FileManager.default.removeItem(at: out)
        let output = try AVAudioFile(forWriting: out, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 24000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)

        let maxFrames = AVAudioFrameCount(24000 * 30)
        var written: AVAudioFrameCount = 0
        var finished = false
        while !finished, written < maxFrames {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { count, inputStatus in
                let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: count)!
                do { try input.read(into: chunk, frameCount: count) } catch { chunk.frameLength = 0 }
                if chunk.frameLength == 0 {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return chunk
            }
            if let conversionError { throw conversionError }
            if buffer.frameLength > 0 {
                buffer.frameLength = min(buffer.frameLength, maxFrames - written)
                try output.write(from: buffer)
                written += buffer.frameLength
            }
            finished = status == .endOfStream || status == .error
        }
        guard written >= 24000 * 3 else {
            try? FileManager.default.removeItem(at: out)
            throw UpdateError("The recording is too short: use 5–30 seconds of one person speaking.")
        }
        let old = settings.petVoiceSample
        settings.petVoiceSample = out.path
        if !old.isEmpty, old != out.path { try? FileManager.default.removeItem(atPath: old) }
        voiceSettingsChanged()
    }

    func removeSample() {
        if !settings.petVoiceSample.isEmpty { try? FileManager.default.removeItem(atPath: settings.petVoiceSample) }
        settings.petVoiceSample = ""
        voiceSettingsChanged()
    }

    // MARK: Installing

    /// Creates the engine's private Python environment and installs its packages (uv if present, else pip).
    func install() async {
        guard installingEngine == nil else { return }
        let target = engine
        guard target.isLocal else { return }
        unload()
        installingEngine = target
        localState = .installing
        installLog = ""
        defer { installingEngine = nil }
        let path = await ai.resolvedLoginPath()
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        func find(_ name: String) -> String? {
            directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        let environment = Self.environment(for: target)
        let venv = environment.path
        do {
            try? FileManager.default.removeItem(at: environment)
            if let uv = find("uv") {
                log("Using uv at \(uv)")
                try await run(uv, ["venv", "--python", "3.12", venv], path: path)
                try await run(uv, ["pip", "install", "--python", "\(venv)/bin/python"] + target.packages, path: path)
            } else {
                // PyTorch wheels lag behind the newest Python, so prefer a version they support.
                guard let python = ["python3.12", "python3.13", "python3.11", "python3.10", "python3"].lazy.compactMap(find).first else {
                    throw UpdateError("No Python 3.10+ found. Install it with `brew install python@3.12` (or install uv), then try again.")
                }
                log("Using \(python)")
                try await run(python, ["-m", "venv", venv], path: path)
                try await run("\(venv)/bin/python", ["-m", "pip", "install", "--upgrade", "pip"], path: path)
                try await run("\(venv)/bin/python", ["-m", "pip", "install"] + target.packages, path: path)
            }
            if target == .kitten { settings.petKittenPython = "" }
            installingEngine = nil
            // Switched to another engine meanwhile: show that one's state.
            guard engine == target else { refreshLocalState(); return }
            localState = .installed
            log("Installed. Downloading the voice model…")
            if await warmUp() { log("Ready.") }
        } catch {
            installingEngine = nil
            log("Failed: \(error.localizedDescription)")
            if engine == target { localState = .failed(error.localizedDescription) } else { refreshLocalState() }
        }
    }

    /// Deletes the current engine's environment (downloaded models stay in the Hugging Face cache).
    func removeInstall() {
        unload()
        try? FileManager.default.removeItem(at: managedEnvironment)
        installLog = ""
        refreshLocalState()
    }

    private func log(_ line: String) {
        installLog = String((installLog + line + "\n").suffix(4000))
    }

    private func run(_ binary: String, _ arguments: [String], path: String) async throws {
        log("$ \((binary as NSString).lastPathComponent) \(arguments.joined(separator: " "))")
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: binary)
            process.arguments = arguments
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = path
            process.environment = environment
            process.currentDirectoryURL = FileManager.default.temporaryDirectory
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            let partial = LineBuffer()
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let lines = partial.append(handle.availableData)
                guard !lines.isEmpty else { return }
                Task { @MainActor in
                    for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                        self?.log(String(line.suffix(160)))
                    }
                }
            }
            process.terminationHandler = { process in
                pipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: process.terminationStatus)
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
        guard status == 0 else { throw UpdateError("\((binary as NSString).lastPathComponent) exited with status \(status).") }
    }
}

/// Splits a byte stream into complete lines (pip/uv also use \r for progress).
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    func append(_ chunk: Data) -> [String] {
        lock.withLock {
            data.append(chunk)
            var lines: [String] = []
            while let end = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                lines.append(String(decoding: data[data.startIndex..<end], as: UTF8.self))
                data.removeSubrange(data.startIndex...end)
            }
            return lines
        }
    }
}

/// Reports each Mac-voice utterance that ends (stopping one reports it as finished, too).
private final class SynthDelegate: NSObject, AVSpeechSynthesizerDelegate {
    let onEnd: @MainActor (ObjectIdentifier) -> Void
    init(onEnd: @escaping @MainActor (ObjectIdentifier) -> Void) { self.onEnd = onEnd }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in onEnd(id) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor in onEnd(id) }
    }
}

/// The long-running Python process. Requests and replies are JSON lines; replies start with "@@MOXIE ".
private final class Worker: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = ""
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]

    var isRunning: Bool { process.isRunning }

    init(python: String, script: URL, onExit: @escaping @Sendable () -> Void) throws {
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-I", script.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONUNBUFFERED"] = "1"
        environment["TOKENIZERS_PARALLELISM"] = "false"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in self?.received(handle.availableData) }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            guard let self else { return }
            let text = String(decoding: handle.availableData, as: UTF8.self)
            self.lock.withLock { self.errorTail = String((self.errorTail + text).suffix(1500)) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.failAll(UpdateError("The voice worker stopped. \(self?.lastErrorLine ?? "")"))
            onExit()
        }
        try process.run()
    }

    private var lastErrorLine: String {
        lock.withLock {
            errorTail.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map(String.init) ?? ""
        }
    }

    func send(_ request: [String: Any], timeout: TimeInterval) async throws -> [String: Any] {
        let id: Int = lock.withLock { defer { nextId += 1 }; return nextId }
        var request = request
        request["id"] = id
        var data = try JSONSerialization.data(withJSONObject: request)
        data.append(0x0A)
        let reply: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            lock.withLock { pending[id] = continuation }
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
            } catch {
                resolve(id, with: .failure(error))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.resolve(id, with: .failure(UpdateError("The voice took too long to answer.")))
            }
        }
        guard reply["ok"] as? Bool == true else {
            throw UpdateError((reply["error"] as? String) ?? "The voice failed.")
        }
        return reply
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        // Busy in native code, Python can sit on SIGTERM; don't leave gigabytes behind.
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        var lines: [Data] = []
        lock.withLock {
            buffer.append(data)
            while let newline = buffer.firstIndex(of: 0x0A) {
                lines.append(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
        }
        let marker = Data("@@MOXIE ".utf8)
        for line in lines where line.starts(with: marker) {
            guard let object = try? JSONSerialization.jsonObject(with: line.dropFirst(marker.count)) as? [String: Any],
                  let id = object["id"] as? Int else { continue }
            resolve(id, with: .success(object))
        }
    }

    private func resolve(_ id: Int, with result: Result<[String: Any], Error>) {
        let continuation: CheckedContinuation<[String: Any], Error>? = lock.withLock { pending.removeValue(forKey: id) }
        continuation?.resume(with: result)
    }

    private func failAll(_ error: Error) {
        let all: [CheckedContinuation<[String: Any], Error>] = lock.withLock {
            defer { pending.removeAll() }
            return Array(pending.values)
        }
        all.forEach { $0.resume(throwing: error) }
    }
}


extension PetVoice {
    /// The Python side of the voice worker, written next to the environments on first use.
    /// The same script runs in every engine's environment; each request names its engine.
    static let workerScript = #"""
'''Moxie Timer voice worker: keeps one local TTS model loaded and turns lines into wav files.

Engines: KittenTTS, Kokoro (+ inno-kokoro voice cloning), VoxCPM2 and VibeVoice.
One JSON request per line on stdin, one JSON reply per line on stdout (prefixed with @@MOXIE).
Anything the libraries print goes to stderr so it can't break the protocol.
'''
import json
import os
import sys
import time
import traceback

reply_stream = sys.stdout
sys.stdout = sys.stderr

model = None
model_key = None
# Kokoro voices cloned from a recording, by (path, modification time).
cloned = {}
# VibeVoice demo recordings, by name.
demo_voices = {}


def reply(payload):
    reply_stream.write("@@MOXIE " + json.dumps(payload) + "\n")
    reply_stream.flush()


def gpu():
    import torch
    torch.set_num_threads(min(8, os.cpu_count() or 4))
    return "mps" if torch.backends.mps.is_available() else "cpu"


def load(request):
    global model, model_key
    engine = request.get("engine") or "kitten"
    name = request.get("model") or "KittenML/kitten-tts-2"
    key = (engine, name, request.get("weights")) if engine == "kitten" else (engine,)
    if model is None or model_key != key:
        model = None
        model_key = None
        model = LOADERS[engine](request)
        model_key = key
    # Get the voice ready too, so the first line isn't late.
    if request.get("sample") and engine == "kokoro":
        kokoro_clone(request["sample"])
    if engine == "vibevoice" and not request.get("sample"):
        vibevoice_demo(request.get("voice") or "en-Alice_woman")


def load_kitten(request):
    from kittenml import KittenTTS
    name = request.get("model") or "KittenML/kitten-tts-2"
    kwargs = {}
    if "kitten-tts-2" in name:
        # Apple Silicon GPU: roughly twice as fast as the CPU.
        device = gpu()
        if request.get("weights"):
            kwargs["weights"] = request["weights"]
        if device == "mps":
            kwargs["device"] = "mps"
    return KittenTTS(name, **kwargs)


def load_kokoro(request):
    from kokoro import KModel
    # Fast enough on the CPU, and the CPU avoids MPS gaps in its ops.
    return {"model": KModel(repo_id="hexgrad/Kokoro-82M").eval(), "pipelines": {}}


def load_voxcpm(request):
    from voxcpm import VoxCPM
    return VoxCPM.from_pretrained("openbmb/VoxCPM2", load_denoiser=False)


def load_vibevoice(request):
    import torch
    from transformers import AutoProcessor, AutoModelForTextToWaveform
    name = "vibevoice/VibeVoice-1.5B-hf"
    device = gpu()
    processor = AutoProcessor.from_pretrained(name)
    dtype = torch.bfloat16 if device == "mps" else torch.float32
    network = AutoModelForTextToWaveform.from_pretrained(name, dtype=dtype).to(device)
    return {"processor": processor, "model": network}


LOADERS = {"kitten": load_kitten, "kokoro": load_kokoro, "voxcpm": load_voxcpm, "vibevoice": load_vibevoice}


def kokoro_pipeline(lang):
    from kokoro import KPipeline
    pipelines = model["pipelines"]
    if lang not in pipelines:
        pipelines[lang] = KPipeline(lang_code=lang, repo_id="hexgrad/Kokoro-82M", model=model["model"])
    return pipelines[lang]


def kokoro_clone(path):
    key = (path, os.path.getmtime(path))
    if key not in cloned:
        from inno_kokoro.enroll import Tuner, enroll, read
        tuner = cloned.setdefault("tuner", Tuner())
        pack, _ = enroll(*read(path), tuner)
        cloned[key] = pack
    return cloned[key]


def speak_kitten(request, text):
    kwargs = {"voice": request.get("voice") or None}
    if "kitten-tts-2" in model_key[1]:
        kwargs["preset"] = request.get("preset") or "stable"
        if request.get("temperature"):
            kwargs["temperature"] = float(request["temperature"])
        kwargs["normalize"] = bool(request.get("normalize", True))
    else:
        kwargs["speed"] = float(request.get("speed") or 1.0)
    kwargs = {k: v for k, v in kwargs.items() if v is not None}
    return model.generate(text, **kwargs), getattr(model, "sample_rate", 24000)


def speak_kokoro(request, text):
    import numpy as np
    sample = request.get("sample")
    voice = request.get("voice") or "af_heart"
    pipeline = kokoro_pipeline("a" if sample else voice[0])
    pack = kokoro_clone(sample) if sample else voice
    chunks = [result.audio for result in pipeline(text, voice=pack, speed=float(request.get("speed") or 1.0))]
    chunks = [chunk.numpy() if hasattr(chunk, "numpy") else chunk for chunk in chunks if chunk is not None]
    return np.concatenate(chunks), 24000


def speak_voxcpm(request, text):
    kwargs = {"cfg_value": 2.0, "inference_timesteps": 10}
    if request.get("sample"):
        kwargs["reference_wav_path"] = request["sample"]
    return model.generate(text=text, **kwargs), model.tts_model.sample_rate


def vibevoice_demo(name):
    # Downloaded once, then reused without asking the Hub again.
    if name not in demo_voices:
        from huggingface_hub import hf_hub_download
        demo_voices[name] = hf_hub_download("bezzam/vibevoice_samples", f"voices/{name}.wav", repo_type="dataset")
    return demo_voices[name]


def speak_vibevoice(request, text):
    sample = request.get("sample") or vibevoice_demo(request.get("voice") or "en-Alice_woman")
    processor, network = model["processor"], model["model"]
    conversation = [{"role": "0", "content": [{"type": "text", "text": text}, {"type": "audio", "path": sample}]}]
    inputs = processor.apply_chat_template(conversation, return_dict=True, tokenize=True, add_generation_prompt=True)
    audio = network.generate(**inputs.to(network.device, network.dtype))
    audio = audio[0] if isinstance(audio, (list, tuple)) else audio
    return audio.float().cpu().numpy().reshape(-1), processor.feature_extractor.sampling_rate


SPEAKERS = {"kitten": speak_kitten, "kokoro": speak_kokoro, "voxcpm": speak_voxcpm, "vibevoice": speak_vibevoice}


def speak(request):
    load(request)
    started = time.time()
    audio, rate = SPEAKERS[model_key[0]](request, request["text"])
    import soundfile as sf
    sf.write(request["out"], audio, rate)
    return time.time() - started


def main():
    reply({"ok": True, "event": "ready"})
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        request = {}
        try:
            request = json.loads(raw)
            command = request.get("cmd")
            if command == "load":
                load(request)
                reply({"ok": True, "id": request.get("id")})
            elif command == "speak":
                seconds = speak(request)
                reply({"ok": True, "id": request.get("id"), "path": request["out"], "seconds": round(seconds, 2)})
            elif command == "quit":
                reply({"ok": True, "id": request.get("id")})
                return
            else:
                reply({"ok": False, "id": request.get("id"), "error": "Unknown command"})
        except Exception as error:
            traceback.print_exc()
            reply({"ok": False, "id": request.get("id"), "error": f"{type(error).__name__}: {error}"[:300]})


if __name__ == "__main__":
    main()
"""#
}

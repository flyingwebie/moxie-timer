import AVFoundation
import Observation

/// Speaks the pet's lines, with a built-in Mac voice or a local KittenTTS model.
/// KittenTTS runs in a small Python worker that keeps the model loaded and is shut down when idle.
@MainActor @Observable
final class PetVoice {
    enum Engine: String, CaseIterable, Identifiable {
        case off, system, kitten
        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: return "Off"
            case .system: return "Mac voices"
            case .kitten: return "KittenTTS (local AI)"
            }
        }
    }

    struct KittenModel: Identifiable {
        let id: String
        let title: String
        let detail: String
        var isExpressive: Bool { id.contains("kitten-tts-2") }
    }

    static let kittenModels = [
        KittenModel(id: "KittenML/kitten-tts-2", title: "KittenTTS 2",
                    detail: "47 voices with emotions and laughs. Needs about 6 GB of memory while loaded and takes a few seconds per line."),
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

    enum KittenState: Equatable {
        case unknown, notInstalled, installing, installed, loading, ready, failed(String)
    }

    private(set) var kittenState: KittenState = .unknown
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
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var queued: String?
    @ObservationIgnored private var lastUse = Date.distantPast
    @ObservationIgnored private var idleTimer: Timer?


    init(settings: AppSettings, ai: AIService) {
        self.settings = settings
        self.ai = ai
        let delegate = SynthDelegate(onEnd: { [weak self] utterance in
            guard let self, self.pendingUtterances.removeValue(forKey: utterance) != nil, self.pendingUtterances.isEmpty else { return }
            self.isSpeaking = false
        })
        synthDelegate = delegate
        synthesizer.delegate = delegate
        refreshKittenState()

        let idleTimer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.unloadIfIdle() }
        }
        RunLoop.main.add(idleTimer, forMode: .common)
        self.idleTimer = idleTimer

        if engine == .kitten, settings.petKittenKeepLoadedMinutes == 0, kittenState == .installed {
            Task { await warmUp() }
        }
    }

    var engine: Engine { Engine(rawValue: settings.petVoiceEngine) ?? .off }
    var kittenModel: KittenModel { Self.kittenModels.first { $0.id == settings.petKittenModel } ?? Self.kittenModels[0] }

    /// Whether the current voice understands [emotion] / <event> markup natively.
    var understandsExpressions: Bool { engine == .kitten && kittenModel.isExpressive && settings.petVoiceExpressions }

    // MARK: Speaking

    /// Says a pet line (markup included). A newer line replaces one that hasn't started yet.
    func speak(_ text: String) {
        guard engine != .off, PetSpeech.hasWords(text) else { return }
        lastUse = .now
        lastError = nil
        switch engine {
        case .off: return
        case .system: speakWithSystem(text)
        case .kitten: speakWithKitten(text)
        }
    }

    func stop() {
        generation += 1
        queued = nil
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
        let segments = PetSpeech.plainSegments(text)
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

    // MARK: KittenTTS

    private var managedEnvironment: URL { Self.voiceDirectory.appending(path: "venv", directoryHint: .isDirectory) }

    /// Not under Application Support: espeak-ng (used by KittenTTS) can't load data from a path with a space.
    static var voiceDirectory: URL {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".moxie-timer/voice", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The Python that runs the worker: the user's own, or the environment the app installed.
    var pythonPath: String {
        let custom = (settings.petKittenPython as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? managedEnvironment.appending(path: "bin/python").path : custom
    }

    func refreshKittenState() {
        guard kittenState != .installing else { return }
        if worker != nil { return }
        kittenState = FileManager.default.isExecutableFile(atPath: pythonPath) ? .installed : .notInstalled
    }

    private func speakWithKitten(_ text: String) {
        retireUtterances()
        synthesizer.stopSpeaking(at: .immediate)
        player?.stop()
        guard kittenState != .installing, kittenState != .notInstalled else {
            lastError = "KittenTTS isn't installed yet (Settings → Pet voice)."
            return
        }
        if isGenerating {
            queued = text
            return
        }
        generation += 1
        let mine = generation
        let model = kittenModel
        let line = model.isExpressive && settings.petVoiceExpressions ? text : PetSpeech.display(text)
        isGenerating = true
        Task {
            defer {
                isGenerating = false
                if let next = queued {
                    queued = nil
                    speakWithKitten(next)
                }
            }
            do {
                let worker = try await startWorker()
                if kittenState != .ready { kittenState = .loading }
                let out = FileManager.default.temporaryDirectory.appending(path: "moxie-pet-\(UUID().uuidString).wav")
                var request: [String: Any] = [
                    "cmd": "speak", "text": line, "out": out.path, "model": model.id,
                    "weights": settings.petKittenWeights, "voice": validKittenVoice(for: model),
                    "preset": settings.petKittenPreset,
                    "normalize": !Self.languageVoices.contains(settings.petKittenVoice),
                ]
                // The small models change pace natively; KittenTTS 2 is time-stretched at playback.
                if !model.isExpressive { request["speed"] = settings.petVoiceSpeed }
                _ = try await worker.send(request, timeout: 300)
                kittenState = .ready
                defer { try? FileManager.default.removeItem(at: out) }
                // A newer line arrived meanwhile: skip this one.
                guard mine == generation, queued == nil else { return }
                try play(out, rate: model.isExpressive ? settings.petVoiceSpeed : 1)
            } catch {
                lastError = error.localizedDescription
                if kittenState == .loading { kittenState = .failed(error.localizedDescription) }
            }
        }
    }

    private func validKittenVoice(for model: KittenModel) -> String {
        let voice = settings.petKittenVoice
        if model.isExpressive { return voice }
        return Self.legacyVoices.contains(voice) ? voice : "Kiki"
    }

    private func play(_ url: URL, rate: Double) throws {
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
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(timePitch)
        engine.connect(player, to: timePitch, format: file.processingFormat)
        engine.connect(timePitch, to: engine.mainMixerNode, format: file.processingFormat)
        timePitch.rate = Float(min(2, max(0.5, rate)))
        timePitch.pitch = Float(settings.petVoicePitch * 100)
        player.volume = Float(settings.petVoiceVolume)
        if !engine.isRunning { try engine.start() }
        player.stop()
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
            kittenState = .notInstalled
            throw UpdateError("Python not found at \(python).")
        }
        let script = Self.voiceDirectory.appending(path: "kitten_worker.py")
        if (try? String(contentsOf: script, encoding: .utf8)) != Self.workerScript {
            try Self.workerScript.write(to: script, atomically: true, encoding: .utf8)
        }
        kittenState = .loading
        let worker = try Worker(python: python, script: script) { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.worker = nil
                if self.kittenState == .loading || self.kittenState == .ready { self.refreshKittenState() }
            }
        }
        self.worker = worker
        return worker
    }

    /// Loads the model ahead of time (and downloads it the first time). Returns the voices it offers.
    @discardableResult
    func warmUp() async -> Bool {
        lastUse = .now
        lastError = nil
        do {
            let worker = try await startWorker()
            kittenState = .loading
            _ = try await worker.send(["cmd": "load", "model": kittenModel.id, "weights": settings.petKittenWeights], timeout: 1800)
            kittenState = .ready
            return true
        } catch {
            lastError = error.localizedDescription
            kittenState = .failed(error.localizedDescription)
            return false
        }
    }

    func unload() {
        worker?.terminate()
        worker = nil
        refreshKittenState()
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
    }

    // MARK: Installing

    /// Creates a private Python environment and installs KittenTTS into it (uv if present, else pip).
    func install() async {
        guard kittenState != .installing else { return }
        unload()
        kittenState = .installing
        installLog = ""
        let path = await ai.resolvedLoginPath()
        let directories = path.split(separator: ":").map(String.init) + ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.local/bin"]
        func find(_ name: String) -> String? {
            directories.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        }
        let venv = managedEnvironment.path
        do {
            try? FileManager.default.removeItem(at: managedEnvironment)
            if let uv = find("uv") {
                log("Using uv at \(uv)")
                try await run(uv, ["venv", "--python", "3.12", venv], path: path)
                try await run(uv, ["pip", "install", "--python", "\(venv)/bin/python", "kittenml", "soundfile"], path: path)
            } else {
                // PyTorch wheels lag behind the newest Python, so prefer a version they support.
                guard let python = ["python3.12", "python3.13", "python3.11", "python3.10", "python3"].lazy.compactMap(find).first else {
                    throw UpdateError("No Python 3.10+ found. Install it with `brew install python@3.12` (or install uv), then try again.")
                }
                log("Using \(python)")
                try await run(python, ["-m", "venv", venv], path: path)
                try await run("\(venv)/bin/python", ["-m", "pip", "install", "--upgrade", "pip"], path: path)
                try await run("\(venv)/bin/python", ["-m", "pip", "install", "kittenml", "soundfile"], path: path)
            }
            settings.petKittenPython = ""
            kittenState = .installed
            log("Installed. Downloading the voice model…")
            if await warmUp() { log("Ready.") }
        } catch {
            kittenState = .failed(error.localizedDescription)
            log("Failed: \(error.localizedDescription)")
        }
    }

    /// Deletes the app's KittenTTS environment (the downloaded model stays in the Hugging Face cache).
    func removeInstall() {
        unload()
        try? FileManager.default.removeItem(at: managedEnvironment)
        installLog = ""
        refreshKittenState()
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
        if process.isRunning { process.terminate() }
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
    /// The Python side of the KittenTTS worker, written next to its environment on first use.
    static let workerScript = #"""
'''Moxie Timer voice worker: keeps a KittenTTS model loaded and turns lines into wav files.

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


def reply(payload):
    reply_stream.write("@@MOXIE " + json.dumps(payload) + "\n")
    reply_stream.flush()


def load(request):
    global model, model_key
    name = request.get("model") or "KittenML/kitten-tts-2"
    weights = request.get("weights")
    key = (name, weights)
    if model is not None and model_key == key:
        return
    from kittenml import KittenTTS
    kwargs = {}
    if "kitten-tts-2" in name:
        import torch
        torch.set_num_threads(min(8, os.cpu_count() or 4))
        if weights:
            kwargs["weights"] = weights
        # Apple Silicon GPU: roughly twice as fast as the CPU.
        if torch.backends.mps.is_available():
            kwargs["device"] = "mps"
    model = None
    model = KittenTTS(name, **kwargs)
    model_key = key


def is_v2():
    return model_key is not None and "kitten-tts-2" in model_key[0]


def speak(request):
    load(request)
    text = request["text"]
    out = request["out"]
    kwargs = {"voice": request.get("voice") or None}
    if is_v2():
        kwargs["preset"] = request.get("preset") or "stable"
        if request.get("temperature"):
            kwargs["temperature"] = float(request["temperature"])
        kwargs["normalize"] = bool(request.get("normalize", True))
    else:
        kwargs["speed"] = float(request.get("speed") or 1.0)
    kwargs = {k: v for k, v in kwargs.items() if v is not None}
    started = time.time()
    audio = model.generate(text, **kwargs)
    import soundfile as sf
    sf.write(out, audio, getattr(model, "sample_rate", 24000))
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
                reply({"ok": True, "id": request.get("id"), "voices": list(getattr(model, "available_voices", []) or [])})
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

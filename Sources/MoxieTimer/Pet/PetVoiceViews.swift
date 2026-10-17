import AVFoundation
import SwiftUI

/// Pet & Voice tab: engine, voice, pace/pitch/volume, and the local models' installs.
struct PetVoiceSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PetVoice.self) private var voice
    @State private var systemVoices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Pet voice")
            row("Voice engine") {
                Picker("Voice engine", selection: Binding(get: { settings.petVoiceEngine }, set: {
                    settings.petVoiceEngine = $0
                    voice.engineChanged()
                })) {
                    ForEach(PetVoice.Engine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            if voice.engine != .off {
                switch voice.engine {
                case .system: systemOptions
                case .kitten: kittenOptions
                case .kokoro: kokoroOptions
                case .voxcpm: voxOptions
                case .vibevoice: vibeOptions
                case .off: EmptyView()
                }

                slider("Volume", value: $settings.petVoiceVolume, in: 0...1, label: "\(Int(settings.petVoiceVolume * 100))%")
                slider("Speed", value: $settings.petVoiceSpeed, in: 0.5...2, label: String(format: "%.2g×", settings.petVoiceSpeed))
                slider("Pitch", value: $settings.petVoicePitch, in: -8...8, step: 1,
                       label: settings.petVoicePitch == 0 ? "Normal" : String(format: "%+.0f", settings.petVoicePitch))

                toggle("Only speak important moments", isOn: $settings.petVoiceImportantOnly)
                note(settings.petVoiceImportantOnly
                     ? "Speaks when you finish tasks and blocks, level up, come back, or drift for a while. Other lines stay silent."
                     : "Speaks every line the pet shows. It stays quiet during calls.")

                HStack(spacing: 8) {
                    Button("Hear a sample") {
                        voice.speak("[excited] Hi, I'm \(settings.petName)! <giggle> Ready to do (((one))) thing at a time?")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .controlSize(.small)
                    .disabled(voice.engine.isLocal && !localUsable)
                    if voice.isGenerating {
                        ProgressView().controlSize(.small)
                        Text(voice.localState == .ready ? "Thinking of how to say it…" : "Loading the voice…")
                            .font(.system(size: 11)).foregroundStyle(Theme.muted)
                    } else if voice.isSpeaking {
                        Button("Stop") { voice.stop() }.controlSize(.small)
                    }
                }
                PetLineTester()
                if let error = voice.lastError {
                    Text(error).font(.system(size: 10)).foregroundStyle(Theme.onBreak).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear {
            systemVoices = PetVoice.systemVoices()
            voice.refreshLocalState()
        }
    }

    // MARK: Mac voices

    @ViewBuilder private var systemOptions: some View {
        @Bindable var settings = settings
        row("Voice") {
            Picker("Voice", selection: $settings.petSystemVoice) {
                Text("System default").tag("")
                ForEach(systemVoices, id: \.identifier) { voice in
                    Text(systemTitle(voice)).tag(voice.identifier)
                }
            }
            .labelsHidden()
            .frame(width: 210)
        }
        note("Mac voices can't act out emotions, so the pet nudges pitch and pace and says sounds like “ha ha”. For nicer voices, download Premium or Enhanced ones in System Settings → Accessibility → Spoken Content → System voice → Manage Voices.")
    }

    private func systemTitle(_ voice: AVSpeechSynthesisVoice) -> String {
        let quality: String
        switch voice.quality {
        case .premium: quality = " · Premium"
        case .enhanced: quality = " · Enhanced"
        default: quality = ""
        }
        let language = Locale.current.localizedString(forIdentifier: voice.language) ?? voice.language
        return "\(voice.name) (\(language))\(quality)"
    }

    // MARK: Local models

    private var localUsable: Bool {
        switch voice.localState {
        case .installed, .loading, .ready, .failed: return true
        default: return false
        }
    }

    @ViewBuilder private var kittenOptions: some View {
        @Bindable var settings = settings
        let model = voice.kittenModel

        row("Model") {
            Picker("Model", selection: Binding(get: { settings.petKittenModel }, set: {
                settings.petKittenModel = $0
                voice.modelSettingsChanged()
            })) {
                ForEach(PetVoice.kittenModels) { Text($0.title).tag($0.id) }
            }
            .labelsHidden()
            .frame(width: 170)
        }
        note(model.detail)

        if model.isExpressive {
            row("Model size") {
                Picker("Weights", selection: Binding(get: { settings.petKittenWeights }, set: {
                    settings.petKittenWeights = $0
                    voice.modelSettingsChanged()
                })) {
                    Text("Smaller (506 MB)").tag("emb4")
                    Text("Full quality (947 MB)").tag("packed")
                }
                .labelsHidden()
                .frame(width: 170)
            }
        }

        row("Voice") {
            Picker("Voice", selection: $settings.petKittenVoice) {
                if model.isExpressive {
                    ForEach(PetVoice.kittenVoices, id: \.name) { item in
                        Text("\(item.name) — \(item.detail)").tag(item.name)
                    }
                } else {
                    ForEach(PetVoice.legacyVoices, id: \.self) { Text($0).tag($0) }
                }
            }
            .labelsHidden()
            .frame(width: 230)
        }
        if model.isExpressive, PetVoice.languageVoices.contains(settings.petKittenVoice) {
            note("Language voices only speak their own language well. Ask for it in your persona (Manage skills…) and turn on AI lines, since the built-in lines are in English.")
        }

        if model.isExpressive {
            row("Delivery") {
                Picker("Preset", selection: $settings.petKittenPreset) {
                    Text("Stable").tag("stable")
                    Text("Expressive").tag("expressive")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            toggle("Act out expressions", isOn: $settings.petVoiceExpressions)
            note("Lines carry tags like [excited], [laugh] and [stress: word]. The bubble hides them, and KittenTTS 2 performs them. See “Try a line” below for what each one does.")
        }

        localCommon
    }

    @ViewBuilder private var kokoroOptions: some View {
        @Bindable var settings = settings
        note("Small and quick: speaks almost instantly, in English. No emotions. It can also copy a voice from a short recording.")
        row("Voice") {
            Picker("Voice", selection: Binding(get: { settings.petKokoroVoice }, set: {
                settings.petKokoroVoice = $0
                voice.voiceSettingsChanged()
            })) {
                Text("Your voice sample").tag("sample")
                Divider()
                ForEach(PetVoice.kokoroVoices, id: \.self) { Text(PetVoice.kokoroTitle($0)).tag($0) }
            }
            .labelsHidden()
            .frame(width: 230)
        }
        if settings.petKokoroVoice == "sample" { VoiceSampleRow() }
        localCommon
    }

    @ViewBuilder private var voxOptions: some View {
        @Bindable var settings = settings
        note("Natural, expressive voices in 30 languages. Describe the voice you want, or copy one from a recording. Takes 5–10 seconds per line, so the pet prepares its next lines in the background.")
        row("Voice") {
            Picker("Voice", selection: Binding(get: { settings.petVoxUseSample }, set: {
                settings.petVoxUseSample = $0
                voice.voiceSettingsChanged()
            })) {
                Text("Describe it").tag(false)
                Text("Your voice sample").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
        if settings.petVoxUseSample {
            VoiceSampleRow()
        } else {
            FieldBox {
                TextField("A small, cheerful creature with a bright, warm voice", text: $settings.petVoxDescription, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .lineLimit(1...3)
                    .onSubmit { voice.voiceSettingsChanged() }
            }
            note("Who's speaking: age, gender, character, tone. The model invents a voice to match, and it can drift a little between lines. For the same voice every time, use a sample.")
        }
        toggle("Act out emotions", isOn: Binding(get: { settings.petVoiceExpressions }, set: {
            settings.petVoiceExpressions = $0
            voice.voiceSettingsChanged()
        }))
        note("Turns each line's emotion into a direction like “cheerful and happy”. Sounds such as [laugh] are said as words.")
        localCommon
    }

    @ViewBuilder private var vibeOptions: some View {
        @Bindable var settings = settings
        note("Microsoft's long-form voice model, very natural in English (and Chinese). It copies the voice of a short recording: pick one of Microsoft's demo voices or use your own sample. It has no emotion tags: the mood comes from the words of the line and the tone of the recording. Takes 5–10 seconds per line, so the pet prepares its next lines in the background.")
        row("Voice") {
            Picker("Voice", selection: Binding(get: { settings.petVibeVoice }, set: {
                settings.petVibeVoice = $0
                voice.voiceSettingsChanged()
            })) {
                Text("Your voice sample").tag("sample")
                Divider()
                ForEach(PetVoice.vibeVoices, id: \.name) { Text("\($0.name) — \($0.detail)").tag($0.name) }
            }
            .labelsHidden()
            .frame(width: 230)
        }
        if settings.petVibeVoice == "sample" { VoiceSampleRow() }
        localCommon
    }

    /// Shared by every local model: memory, install status and where things live.
    @ViewBuilder private var localCommon: some View {
        @Bindable var settings = settings
        row("Keep the model loaded") {
            Picker("Keep loaded", selection: $settings.petKittenKeepLoadedMinutes) {
                Text("10 min after speaking").tag(10)
                Text("1 hour after speaking").tag(60)
                Text("4 hours after speaking").tag(240)
                Text("Always").tag(0)
            }
            .labelsHidden()
            .frame(width: 170)
        }
        if let memory = memoryNote {
            note(memory)
        }

        localStatus

        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
                if voice.engine == .kitten { kittenPython }
                if !voice.usesCustomPython {
                    note("The environment lives in ~/.moxie-timer/voice/\(voice.engine.environmentName). Models are cached in ~/.cache/huggingface. Remove them in “Voice models on this Mac” below.")
                }
                note(licenseNote)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private var kittenPython: some View {
        @Bindable var settings = settings
                row("Python") {
                    FieldBox {
                        TextField("App's own environment", text: Binding(get: { settings.petKittenPython }, set: {
                            settings.petKittenPython = $0
                            voice.unload()
                        }))
                        .textFieldStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                    }
                    .frame(width: 230)
                }
                note("Leave empty to use the environment the app installs. Or point to any Python with `kittenml` and `soundfile` installed.")
    }

    private var memoryNote: String? {
        switch voice.engine {
        case .kitten where voice.kittenModel.isExpressive:
            return "Loading takes about 30 seconds, so the first line after an unload is late. While loaded it uses about 6 GB of memory."
        case .kokoro:
            return "Loads in a few seconds and uses about 1.5 GB of memory."
        case .voxcpm:
            return "Loading takes about 30 seconds (the first time it downloads about 5 GB). While loaded it uses about 5–6 GB of memory."
        case .vibevoice:
            return "Loading takes about 30 seconds (the first time it downloads about 5 GB). While loaded it uses about 4–5 GB of memory."
        default:
            return nil
        }
    }

    private var licenseNote: String {
        switch voice.engine {
        case .kokoro: return "Kokoro-82M and the inno-kokoro voice tuner: Apache 2.0 (the tuner's speaker encoder is CC BY-SA 3.0)."
        case .voxcpm: return "VoxCPM2 by OpenBMB: Apache 2.0."
        case .vibevoice: return "VibeVoice by Microsoft: MIT, released for research. Microsoft advises against commercial use."
        default: return "KittenTTS 2 model: Stellon Labs Community License, free for personal and small-business use. The library is Apache 2.0."
        }
    }

    private var installNote: String {
        switch voice.engine {
        case .kokoro: return "Installs Python packages (PyTorch and Kokoro, about 1 GB) into the app's own folder, then downloads the voice model (about 330 MB)."
        case .voxcpm: return "Installs Python packages (PyTorch and VoxCPM, about 1 GB) into the app's own folder, then downloads the voice model (about 5 GB)."
        case .vibevoice: return "Installs Python packages (PyTorch and Transformers, about 1 GB) into the app's own folder, then downloads the voice model (about 5 GB)."
        default: return "Installs Python packages (PyTorch and KittenTTS, about 1 GB) into the app's own folder, then downloads the voice model."
        }
    }

    @ViewBuilder private var localStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            switch voice.localState {
            case .notInstalled, .unknown:
                Button("Install \(voice.engine.modelName)") { Task { await voice.install() } }
                    .buttonStyle(PrimaryButtonStyle()).controlSize(.small)
            case .installing:
                ProgressView().controlSize(.small)
            case .installed, .failed:
                Button("Load now") { Task { await voice.warmUp() } }.controlSize(.small)
                Button("Reinstall") { Task { await voice.install() } }.controlSize(.small)
            case .loading:
                ProgressView().controlSize(.small)
            case .ready:
                Button("Unload") { voice.unload() }.controlSize(.small)
                    .help("Free the memory now.")
            }
        }
        if voice.localState == .notInstalled || voice.localState == .unknown {
            note(installNote + " Everything runs on this Mac and nothing is sent anywhere.")
        }
        if !voice.installLog.isEmpty, voice.localState == .installing || voice.localState.isFailure {
            ScrollView {
                Text(voice.installLog)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .frame(height: 90)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cream))
        }
    }

    private var statusText: String {
        switch voice.localState {
        case .unknown, .notInstalled: return "Not installed"
        case .installing: return "Installing…"
        case .installed: return "Installed · loads on first line"
        case .loading: return "Loading model (first time downloads it)…"
        case .ready: return "Ready"
        case let .failed(message): return "Problem: \(message.prefix(80))"
        }
    }

    private var statusColor: Color {
        switch voice.localState {
        case .ready: return Theme.running
        case .failed: return Theme.onBreak
        case .installed: return Theme.navy
        default: return Theme.faint
        }
    }

    // MARK: Building blocks

    private func row<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            content()
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double? = nil, label: String) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer()
            Group {
                if let step { Slider(value: value, in: range, step: step) } else { Slider(value: value, in: range) }
            }
            .controlSize(.small)
            .frame(width: 140)
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 46, alignment: .trailing)
        }
    }

    private func toggle(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch).tint(Theme.navy).controlSize(.small).font(.system(size: 12))
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The recording Kokoro, VoxCPM2 and VibeVoice copy a voice from. The app keeps its own wav copy of it.
private struct VoiceSampleRow: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PetVoice.self) private var voice
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Voice sample").font(.system(size: 12))
                Spacer()
                Text(settings.petVoiceSample.isEmpty ? "None" : (settings.petVoiceSample as NSString).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(settings.petVoiceSample.isEmpty ? Theme.onBreak : Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button("Choose…", action: choose).controlSize(.small)
                if !settings.petVoiceSample.isEmpty {
                    Button("Remove") { voice.removeSample() }.controlSize(.small)
                }
            }
            Text("5–30 seconds of one person speaking clearly, with no music or noise (a Voice Memos recording works). Only use a voice you have permission to copy.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.onBreak)
            }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a short recording of the voice to copy"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try voice.importSample(from: url)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Pet & Voice tab: type a line with voice tags and hear it. Clicking a tag copies it, to paste into your own lines.
private struct PetLineTester: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PetVoice.self) private var voice
    @State private var text = ""
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Try a line").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            HStack(spacing: 6) {
                FieldBox {
                    TextField("[excited] Type a line… [laugh]", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(speak)
                }
                Button("Speak", action: speak)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!PetSpeech.hasWords(text) || (voice.engine.isLocal && voice.localState == .installing))
            }
            let support = voice.tagSupport
            if support.any {
                Text("Tags go in square brackets. These are the ones this voice uses; click one to add it to the line above.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This voice reads plain text: tags in a line are removed before it speaks. KittenTTS 2 performs emotions, sounds and stress; VoxCPM2 performs emotions.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let how = support.emotions {
                tagGroup("Emotions — change the voice",
                         "Sets the mood of the whole line. Use one, at the very start. \(how)",
                         PetSpeech.emotions.map { "[\($0)]" })
            }
            if let how = support.sounds {
                tagGroup("Sounds — a moment, not a mood",
                         "Adds one sound where you put it (a laugh, a sigh, a pause). \(how)",
                         PetSpeech.events.map { "[\($0)]" })
            }
            if let how = support.stress {
                tagGroup("Stress — one word",
                         "Says that word with more weight. Replace “word” with yours. \(how)",
                         ["[stress: word]"])
            }
            if let copied {
                Text("Copied \(copied) — paste it into your lines.")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.onBreak)
            }
        }
        .padding(.top, 4)
        .onAppear { if text.isEmpty { text = example } }
        // A new voice gets an example it understands, unless the user typed their own line.
        .onChange(of: voice.tagSupport.emotions) { if Self.examples.contains(text) { text = example } }
        .onChange(of: voice.tagSupport.sounds) { if Self.examples.contains(text) { text = example } }
    }

    private static let examples = ["[joyful] Well done! [laugh] That's [stress: huge].", "[joyful] Well done! [laugh] That's huge.",
                                   "[joyful] Well done! That's huge.", "Well done! That's huge."]

    private var example: String {
        let support = voice.tagSupport
        if support.stress != nil { return Self.examples[0] }
        if support.sounds != nil { return Self.examples[1] }
        return support.emotions != nil ? Self.examples[2] : Self.examples[3]
    }

    private func tagGroup(_ title: String, _ detail: String, _ tags: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.8))
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    Button(tag) { use(tag) }
                        .buttonStyle(ChipButtonStyle())
                        .help("Copy \(tag)")
                }
            }
        }
        .padding(.top, 2)
    }

    private func use(_ tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tag, forType: .string)
        copied = tag
        let isEmotion = PetSpeech.emotions.contains(tag.trimmingCharacters(in: CharacterSet(charactersIn: "[]")))
        if isEmotion {
            // One emotion, at the start: replace the current one.
            var body = text
            for emotion in PetSpeech.emotions {
                body = body.replacingOccurrences(of: "[\(emotion)]", with: "", options: .caseInsensitive)
            }
            text = tag + " " + body.trimmingCharacters(in: .whitespaces)
        } else {
            text = text.trimmingCharacters(in: .whitespaces) + " " + tag
        }
    }

    private func speak() {
        guard PetSpeech.hasWords(text) else { return }
        let line = text.replacingOccurrences(of: "{name}", with: settings.petName)
        voice.speak(PetSpeech.emotion(of: line) == nil ? line : PetSpeech.withEmotion(line, default: "mundane"))
    }
}

extension PetVoice.LocalState {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

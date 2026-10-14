import AVFoundation
import SwiftUI

/// Settings → Pet voice: engine, voice, pace/pitch/volume, and the KittenTTS install.
struct PetVoiceSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PetVoice.self) private var voice
    @State private var systemVoices: [AVSpeechSynthesisVoice] = []

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Pet voice")
            row("Voice engine") {
                Picker("Voice engine", selection: $settings.petVoiceEngine) {
                    ForEach(PetVoice.Engine.allCases) { Text($0.title).tag($0.rawValue) }
                }
                .labelsHidden()
                .frame(width: 170)
            }

            if voice.engine != .off {
                switch voice.engine {
                case .system: systemOptions
                case .kitten: kittenOptions
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
                    .disabled(voice.engine == .kitten && !kittenUsable)
                    if voice.isGenerating {
                        ProgressView().controlSize(.small)
                        Text(voice.kittenState == .ready ? "Thinking of how to say it…" : "Loading the voice…")
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
            voice.refreshKittenState()
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

    // MARK: KittenTTS

    private var kittenUsable: Bool {
        switch voice.kittenState {
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
            note("Language voices only speak their own language well. Ask for it in “Talk to me like…” and turn on AI lines, since the built-in lines are in English.")
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
        if model.isExpressive {
            note("Loading takes about 30 seconds, so the first line after an unload is late. While loaded it uses about 6 GB of memory.")
        }

        kittenStatus

        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 6) {
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
                if settings.petKittenPython.isEmpty, voice.kittenState != .notInstalled, voice.kittenState != .installing {
                    HStack {
                        note("The environment lives in ~/.moxie-timer/voice. Models are cached in ~/.cache/huggingface.")
                        Spacer()
                        Button("Remove", role: .destructive) { voice.removeInstall() }.controlSize(.small)
                    }
                }
                note("KittenTTS 2 model: Stellon Labs Community License, free for personal and small-business use. The library is Apache 2.0.")
            }
            .padding(.top, 4)
        }
        .font(.system(size: 11))
    }

    @ViewBuilder private var kittenStatus: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 7, height: 7)
            Text(statusText).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            switch voice.kittenState {
            case .notInstalled, .unknown:
                Button("Install KittenTTS") { Task { await voice.install() } }
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
        if voice.kittenState == .notInstalled || voice.kittenState == .unknown {
            note("Installs Python packages (PyTorch and KittenTTS, about 1 GB) into the app's own folder, then downloads the voice model. Everything runs on this Mac and nothing is sent anywhere.")
        }
        if !voice.installLog.isEmpty, voice.kittenState == .installing || voice.kittenState.isFailure {
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
        switch voice.kittenState {
        case .unknown, .notInstalled: return "Not installed"
        case .installing: return "Installing…"
        case .installed: return "Installed · loads on first line"
        case .loading: return "Loading model (first time downloads it)…"
        case .ready: return "Ready"
        case let .failed(message): return "Problem: \(message.prefix(80))"
        }
    }

    private var statusColor: Color {
        switch voice.kittenState {
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

/// Settings → Pet voice: type a line with voice tags and hear it. Clicking a tag copies it, to paste into your own lines.
private struct PetLineTester: View {
    @Environment(AppSettings.self) private var settings
    @Environment(PetVoice.self) private var voice
    @State private var text = "[joyful] Well done! [laugh] That's [stress: huge]."
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
                    .disabled(!PetSpeech.hasWords(text) || (voice.engine == .kitten && voice.kittenState == .installing))
            }
            Text("Every tag goes in square brackets. Click one to copy it and add it to the line above.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            tagGroup("Emotions — change the voice",
                     "Sets the mood of the whole line: tone, energy and pace change for every word. Use one, at the very start.",
                     PetSpeech.emotions.map { "[\($0)]" })
            tagGroup("Sounds — a moment, not a mood",
                     "Adds one sound where you put it (a laugh, a sigh, a pause). The voice around it stays the same.",
                     PetSpeech.events.map { "[\($0)]" })
            tagGroup("Stress — one word",
                     "Says that word with more weight. Replace “word” with yours.",
                     ["[stress: word]"])
            Text(voice.engine == .kitten && voice.understandsExpressions
                 ? "KittenTTS 2 performs all three."
                 : "Only KittenTTS 2 with “Act out expressions” performs these fully. Mac voices shift pitch and pace a little for emotions and say sounds as words (“ha ha”, “hmm”); stress is ignored.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
            if let copied {
                Text("Copied \(copied) — paste it into your lines.")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.onBreak)
            }
        }
        .padding(.top, 4)
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

extension PetVoice.KittenState {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

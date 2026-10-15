import SwiftUI

/// Pet & Voice tab: every local voice that has files on this Mac, which one is loaded, and removing them.
struct VoiceModelsSection: View {
    @Environment(PetVoice.self) private var voice
    @State private var models: [PetVoice.InstalledModel] = []
    @State private var scanned = false
    @State private var memory: Int64?
    @State private var removing: PetVoice.Engine?
    @State private var confirming: PetVoice.InstalledModel?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Voice models on this Mac")
            if let loaded = voice.loadedEngine {
                HStack(spacing: 8) {
                    Circle().fill(voice.localState == .ready ? Theme.running : Theme.warmup).frame(width: 7, height: 7)
                    Text(voice.localState == .ready ? "Loaded now: \(loaded.modelName)" : "Loading \(loaded.modelName)…")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    if let memory {
                        Text("· \(bytes(memory)) of memory").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Button("Unload") { voice.unload() }.controlSize(.small).help("Free the memory now. It loads again on the next line.")
                }
            } else {
                Text("No voice model is loaded right now.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }

            if !scanned {
                ProgressView().controlSize(.small)
            } else if models.isEmpty {
                Text("No local voices are installed.").font(.system(size: 11)).foregroundStyle(Theme.muted)
            } else {
                ForEach(models) { model in row(model) }
                Text("Total \(bytes(models.reduce(0) { $0 + $1.totalBytes })). Removing deletes the voice's Python packages and its downloaded model; install it again any time.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await refresh() }
        // Installs, loads and unloads change what's on disk and in memory.
        .onChange(of: voice.localState) { Task { await refresh() } }
        .task(id: voice.loadedEngine) {
            while !Task.isCancelled, voice.loadedEngine != nil {
                memory = voice.loadedMemory()
                try? await Task.sleep(for: .seconds(3))
            }
            memory = nil
        }
        .confirmationDialog("Remove \(confirming?.engine.modelName ?? "")?", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { model in
            Button("Remove \(bytes(model.totalBytes))", role: .destructive) { Task { await remove(model.engine) } }
        } message: { model in
            Text(model.engine == voice.engine
                 ? "It's the voice the pet uses now, so the pet stays quiet until you install it again or pick another voice."
                 : "Deletes its Python packages and downloaded model files.")
        }
    }

    private func row(_ model: PetVoice.InstalledModel) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.engine.modelName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ink)
                    if model.engine == voice.engine {
                        Text("IN USE")
                            .font(.system(size: 8, weight: .bold))
                            .tracking(0.4)
                            .foregroundStyle(Theme.running)
                    }
                }
                Text(detail(model)).font(.system(size: 10)).foregroundStyle(Theme.muted)
            }
            Spacer()
            if removing == model.engine {
                ProgressView().controlSize(.small)
            } else {
                Button("Remove", role: .destructive) { confirming = model }
                    .controlSize(.small)
                    .disabled(removing != nil || voice.localState == .installing && model.engine == voice.engine)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cream))
    }

    private func detail(_ model: PetVoice.InstalledModel) -> String {
        var parts: [String] = []
        if model.environmentBytes > 0 { parts.append("Python packages \(bytes(model.environmentBytes))") }
        parts.append(model.modelBytes > 0 ? "model files \(bytes(model.modelBytes))" : "model not downloaded yet")
        return parts.joined(separator: " · ")
    }

    private func remove(_ engine: PetVoice.Engine) async {
        removing = engine
        await voice.removeModels(for: engine)
        removing = nil
        await refresh()
    }

    private func refresh() async {
        models = await voice.installedModels()
        scanned = true
    }

    private func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

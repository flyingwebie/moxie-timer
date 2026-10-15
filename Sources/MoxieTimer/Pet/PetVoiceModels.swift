import Darwin
import Foundation

/// What each local voice keeps on this Mac (its Python environment and downloaded model files), and removing it.
extension PetVoice {
    struct InstalledModel: Identifiable {
        let engine: Engine
        /// Bytes of the app's Python environment for the engine; 0 when there is none.
        let environmentBytes: Int64
        /// Bytes of the engine's files in the Hugging Face cache.
        let modelBytes: Int64
        var id: String { engine.rawValue }
        var totalBytes: Int64 { environmentBytes + modelBytes }
    }

    /// The Hugging Face cache repos each engine downloads. KittenTTS has several models, matched by prefix.
    nonisolated static func cacheRepos(for engine: Engine) -> [String] {
        switch engine {
        case .off, .system: return []
        case .kitten: return ["models--KittenML--kitten-tts-"]
        case .kokoro: return ["models--hexgrad--Kokoro-82M", "models--remsky--kokoro-inno-clone-tuner"]
        case .voxcpm: return ["models--openbmb--VoxCPM2"]
        case .vibevoice: return ["models--vibevoice--VibeVoice-1.5B-hf", "datasets--bezzam--vibevoice_samples"]
        }
    }

    nonisolated static var huggingFaceCache: URL {
        let environment = ProcessInfo.processInfo.environment
        if let hub = environment["HF_HUB_CACHE"], !hub.isEmpty { return URL(fileURLWithPath: hub) }
        if let home = environment["HF_HOME"], !home.isEmpty { return URL(fileURLWithPath: home).appending(path: "hub") }
        return URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/huggingface/hub")
    }

    /// The local engines that have anything on disk.
    func installedModels() async -> [InstalledModel] {
        let voiceDirectory = Self.voiceDirectory
        return await Task.detached(priority: .utility) {
            let cache = HuggingFaceCache(root: Self.huggingFaceCache)
            return Engine.allCases.filter(\.isLocal).compactMap { engine -> InstalledModel? in
                let environment = voiceDirectory.appending(path: engine.environmentName)
                let model = InstalledModel(engine: engine,
                                           environmentBytes: directorySize(environment),
                                           modelBytes: cache.size(of: cache.repos(matching: Self.cacheRepos(for: engine))))
                return model.totalBytes > 0 ? model : nil
            }
        }.value
    }

    /// The engine whose model is in memory right now, if any.
    var loadedEngine: Engine? { localState == .ready || localState == .loading ? engine : nil }

    /// Memory the voice worker uses, GPU allocations included.
    func loadedMemory() -> Int64? {
        guard let pid = runningWorkerPID else { return nil }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return result == 0 ? Int64(usage.ri_phys_footprint) : nil
    }

    /// Deletes an engine's Python environment and its downloaded models. Model files shared with other repos stay.
    func removeModels(for engine: Engine) async {
        if engine == self.engine {
            stop()
            unload()
        }
        let environment = Self.voiceDirectory.appending(path: engine.environmentName)
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: environment)
            let cache = HuggingFaceCache(root: Self.huggingFaceCache)
            cache.remove(cache.repos(matching: Self.cacheRepos(for: engine)))
        }.value
        if engine == self.engine {
            clearInstallLog()
            refreshLocalState()
        }
    }
}

/// Reads the Hugging Face hub cache. Repos keep their files in `blobs/`; newer hub versions make those symlinks
/// into a shared `blobs/` store at the cache root, which other repos (and other apps) can point to as well.
private struct HuggingFaceCache {
    let root: URL

    func repos(matching names: [String]) -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return all.filter { url in
            let name = url.lastPathComponent
            return names.contains { $0.hasSuffix("-") ? name.hasPrefix($0) : name == $0 }
        }
    }

    /// The real files a repo's blobs resolve to.
    private func files(of repo: URL) -> Set<String> {
        let blobs = repo.appending(path: "blobs")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: blobs.path)) ?? []
        return Set(names.map { blobs.appending(path: $0).resolvingSymlinksInPath().path })
    }

    func size(of repos: [URL]) -> Int64 {
        repos.reduce(into: Set<String>()) { $0.formUnion(files(of: $1)) }
            .reduce(0) { $0 + fileSize($1) }
    }

    func remove(_ repos: [URL]) {
        guard !repos.isEmpty else { return }
        let removing = Set(repos.map(\.standardizedFileURL.path))
        let all = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let others = all.filter { !removing.contains($0.standardizedFileURL.path) && $0.lastPathComponent.contains("--") }
        let kept = others.reduce(into: Set<String>()) { $0.formUnion(files(of: $1)) }
        let sharedStore = root.appending(path: "blobs").standardizedFileURL.path + "/"
        for repo in repos {
            // Shared-store files only this repo uses go too; the repo folder holds the rest.
            for file in files(of: repo) where file.hasPrefix(sharedStore) && !kept.contains(file) {
                try? FileManager.default.removeItem(atPath: file)
            }
            try? FileManager.default.removeItem(at: repo)
        }
    }
}

private func fileSize(_ path: String) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
}

/// Allocated size of a folder, not following symlinks (a venv links to its Python).
private func directorySize(_ url: URL) -> Int64 {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey]) else { return 0 }
    var total: Int64 = 0
    for case let file as URL in enumerator {
        let values = try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .isSymbolicLinkKey])
        if values?.isSymbolicLink == true { continue }
        total += Int64(values?.totalFileAllocatedSize ?? 0)
    }
    return total
}

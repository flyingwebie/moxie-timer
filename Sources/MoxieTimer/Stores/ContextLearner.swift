import AppKit
import ApplicationServices

/// A client + project pair the learner can suggest.
struct ProjectChoice: Codable, Hashable {
    var client: Ref
    var project: Ref

    var key: String { "\(client.id)|\(project.id)" }
    var label: String { "\(client.name) · \(project.name)" }
}

/// What you're looking at right now: the frontmost app and, with Accessibility permission, its window title.
struct AppContext: Equatable {
    let bundleId: String
    let appName: String
    let title: String?

    var features: [String] {
        ["app:\(bundleId)"] + AppContext.keywords(in: title ?? "", appName: appName).map { "w:\($0)" }
    }

    private static let stopWords: Set<String> = [
        "untitled", "google", "chrome", "safari", "firefox", "arc", "brave", "edge", "visual", "studio", "code",
        "cursor", "xcode", "window", "inbox", "mail", "home", "page", "new", "tab", "tabs", "search", "edited",
        "document", "file", "files", "folder", "with", "from", "that", "this", "your", "dashboard", "login",
        "settings", "preview", "terminal", "finder", "slack", "zoom", "meeting", "welcome", "http", "https", "www",
    ]

    static func keywords(in title: String, appName: String) -> [String] {
        let appWords = Set(appName.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        var seen = Set<String>()
        return title.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 4 && !$0.allSatisfy(\.isNumber) && !stopWords.contains($0) && !appWords.contains($0) }
            .filter { seen.insert($0).inserted }
            .prefix(8)
            .map { $0 }
    }

    static func current(includeTitle: Bool) -> AppContext? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleId = app.bundleIdentifier,
              bundleId != Bundle.main.bundleIdentifier else { return nil }
        let title = includeTitle ? focusedWindowTitle(pid: app.processIdentifier) : nil
        return AppContext(bundleId: bundleId, appName: app.localizedName ?? bundleId, title: title)
    }

    private static func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }
}

/// Learns which apps and window keywords go with which client/project while you track, and suggests them later.
/// Everything stays in a local file.
@MainActor
final class ContextLearner {
    struct Suggestion: Equatable {
        let choice: ProjectChoice
        let reason: String
    }

    private struct Store: Codable {
        var counts: [String: [String: Int]] = [:]
        var choices: [String: ProjectChoice] = [:]
    }

    private var store = Store()
    private var unsaved = 0
    private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "context.json")
    }()

    init() {
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(Store.self, from: data) {
            store = saved
        }
    }

    func learn(_ context: AppContext, _ choice: ProjectChoice) {
        for feature in context.features {
            store.counts[feature, default: [:]][choice.key, default: 0] += 1
        }
        store.choices[choice.key] = choice
        unsaved += 1
        if unsaved >= 12 { save() }
    }

    func suggest(for context: AppContext) -> Suggestion? {
        var scores: [String: Double] = [:]
        var bestFeature: [String: (feature: String, weight: Double)] = [:]
        for feature in context.features {
            guard let projects = store.counts[feature] else { continue }
            let total = projects.values.reduce(0, +)
            guard total >= 3 else { continue }
            let weight = feature.hasPrefix("w:") ? 3.0 : 1.0
            for (key, count) in projects {
                let contribution = weight * Double(count) / Double(total)
                scores[key, default: 0] += contribution
                if contribution > (bestFeature[key]?.weight ?? 0) { bestFeature[key] = (feature, contribution) }
            }
        }
        guard let (key, score) = scores.max(by: { $0.value < $1.value }), score >= 0.6,
              let choice = store.choices[key] else { return nil }
        let feature = bestFeature[key]?.feature ?? ""
        let reason = feature.hasPrefix("w:")
            ? "“\(feature.dropFirst(2))” in \(context.appName)"
            : "you usually use \(context.appName) for it"
        return Suggestion(choice: choice, reason: reason)
    }

    func forgetAll() {
        store = Store()
        save()
    }

    func save() {
        unsaved = 0
        guard let data = try? JSONEncoder().encode(store) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

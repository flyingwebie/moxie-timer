import Foundation
import Observation

/// A set of pet lines written by AI in the user's tone and style, used instead of the built-in `PetPhrases`.
/// Written once on request (not per moment), so the pet stays instant and works offline.
@MainActor @Observable
final class PetLineLibrary {
    struct Saved: Codable {
        /// tone → event → lines (with placeholders and voice markup).
        var lines: [String: [String: [String]]]
        var createdAt: Date
        var engine: String?
    }

    private(set) var saved: Saved?
    private(set) var isWriting = false
    private(set) var progress: String?
    private(set) var lastError: String?

    /// Tones the AI writes for. Quiet stays emoji only.
    static let writableTones: [PetTone] = [.warm, .coach]
    static let linesPerMoment = 4

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let ai: AIService
    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "pet-lines.json")
    }()

    init(settings: AppSettings, ai: AIService) {
        self.settings = settings
        self.ai = ai
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            saved = try? decoder.decode(Saved.self, from: data)
        }
    }

    func lines(for event: PetEvent, tone: PetTone) -> [String]? {
        guard let lines = saved?.lines[tone.rawValue]?[event.rawValue], !lines.isEmpty else { return nil }
        return lines
    }

    func count(for tone: PetTone) -> Int {
        saved?.lines[tone.rawValue]?.values.reduce(0) { $0 + $1.count } ?? 0
    }

    /// The tones to write for the current Tone setting.
    var tonesToWrite: [PetTone] {
        switch PetTone(rawValue: settings.petTone) ?? .warm {
        case .warm: return [.warm]
        case .coach: return [.coach]
        case .quiet: return []
        case .mix: return Self.writableTones
        }
    }

    func write() async {
        guard !isWriting else { return }
        let tones = tonesToWrite
        guard !tones.isEmpty else { return }
        isWriting = true
        lastError = nil
        defer { isWriting = false; progress = nil }

        var result = saved?.lines ?? [:]
        var failures: [String] = []
        for (index, tone) in tones.enumerated() {
            progress = tones.count > 1 ? "Writing \(tone.title) lines (\(index + 1) of \(tones.count))…" : "Writing lines…"
            let instructions = instructions(for: tone)
            var parsed: [String: [String]]
            do {
                parsed = parse(try await ai.generate(instructions: instructions, prompt: prompt(for: PetEvent.allCases)))
            } catch {
                failures.append("\(tone.title): \(error.localizedDescription)")
                continue
            }
            // Smaller models give up partway through a long list: ask again for the thin moments, a few at a time.
            let thin = PetEvent.allCases.filter { (parsed[$0.rawValue]?.count ?? 0) < 2 }
            for start in stride(from: 0, to: thin.count, by: 4) {
                let batch = Array(thin[start..<min(start + 4, thin.count)])
                guard let reply = try? await ai.generate(instructions: instructions, prompt: prompt(for: batch)) else { break }
                for (key, lines) in parse(reply) {
                    let fresh = lines.filter { !(parsed[key]?.contains($0) ?? false) }
                    parsed[key] = Array(((parsed[key] ?? []) + fresh).prefix(Self.linesPerMoment + 2))
                }
            }
            let missing = PetEvent.allCases.filter { parsed[$0.rawValue]?.isEmpty ?? true }
            guard missing.count < PetEvent.allCases.count / 2 else {
                failures.append("\(tone.title): the AI reply wasn't in the expected format. Try another engine in Settings → AI.")
                continue
            }
            result[tone.rawValue] = parsed
        }
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
        guard result != saved?.lines else { return }
        saved = Saved(lines: result, createdAt: .now, engine: ai.lastEngine?.title)
        persist()
    }

    /// Back to the built-in lines.
    func reset() {
        saved = nil
        lastError = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let saved, let data = try? encoder.encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Prompt

    private func instructions(for tone: PetTone) -> String {
        let toneDescription = tone == .coach
            ? "short, direct and firm, like a sports coach; no baby talk"
            : "warm, playful and encouraging; teases gently when they drift, never guilt-trips"
        let style = settings.petStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        You write the lines for \(settings.petName), a tiny pet that sits next to a focus timer on a Mac and helps \
        a person with ADHD stay on task. Tone: \(toneDescription).\
        \(style.isEmpty ? "" : " The user asked the pet to talk like this (follow it, including the language): \(style).")

        What the app does, so lines can mention it: a timer that logs time to Moxie (the user's client/project tool); \
        focus blocks that start with a 5-minute warm-up and end in a break screen; a task list ranked by due date; \
        it notices when the user switches to a distracting app or website while the timer runs and nudges them back; \
        it reminds them when they're working without a timer; daily streaks, levels and unlockable pets.
        What the pet and app do NOT do, so never claim or promise them: block or close apps or websites, see what's \
        on the screen beyond the app or site name, hear the user, read messages, know their calendar or meetings, \
        remember earlier days beyond the streak, punish or report the user, or give medical advice. Don't diagnose or \
        mention ADHD, and don't shame.

        Write \(Self.linesPerMoment) different lines for EACH moment the prompt lists. Every line: at most 14 words, \
        no quotes, at most one emoji, sounds natural spoken aloud, and is different from the others.
        The pet speaks in the first person as \(settings.petName); it doesn't know the user's name unless the style above \
        gives it. Placeholders the app fills in: {task} (current task name), {level} (the pet's level), {streak} \
        (days in a row). {app} (the distraction) is ONLY for the drift moments and {pet} (a newly unlocked pet) ONLY \
        for newPet. Use placeholders in about half the lines; don't invent other placeholders.
        Voice markup (the speech bubble hides it, the voice acts it out): start each line with one emotion tag from \
        \(PetSpeech.emotions.map { "[\($0)]" }.joined(separator: " ")); optionally add one sound from \
        \(PetSpeech.events.map { "<\($0)>" }.joined(separator: " ")); optionally wrap one key word in (((triple parentheses))).

        Output format, nothing else (no headings, no numbering, no blank commentary), one line each:
        momentName: line
        """
    }

    private func prompt(for events: [PetEvent]) -> String {
        "Moments (name — what just happened):\n"
            + events.map { "\($0.rawValue) — \($0.situation)" }.joined(separator: "\n")
    }

    // MARK: Parsing

    private static let placeholderPattern = try! NSRegularExpression(pattern: "\\{(\\w+)\\}")
    private static let allowedPlaceholders: Set<String> = ["task", "level", "streak", "app", "pet"]

    /// Reads "moment: line" rows; drops lines that would show wrong text in the bubble.
    private func parse(_ reply: String) -> [String: [String]] {
        Self.parse(reply, petName: settings.petName)
    }

    static func parse(_ reply: String, petName: String) -> [String: [String]] {
        let events = Dictionary(uniqueKeysWithValues: PetEvent.allCases.map { ($0.rawValue.lowercased(), $0) })
        var result: [String: [String]] = [:]
        for raw in reply.split(whereSeparator: \.isNewline) {
            var row = raw.trimmingCharacters(in: .whitespaces)
            row = row.trimmingCharacters(in: CharacterSet(charactersIn: "-*•` "))
            guard let colon = row.firstIndex(of: ":") else { continue }
            let key = row[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "*` ")).lowercased()
            guard let event = events[key] else { continue }
            let line = normalize(String(row[row.index(after: colon)...]), petName: petName)
            guard isUsable(line, for: event), !addressesPet(line, petName: petName),
                  !(result[event.rawValue]?.contains(line) ?? false) else { continue }
            result[event.rawValue, default: []].append(line)
        }
        return result.mapValues { Array($0.prefix(linesPerMoment + 2)) }
    }

    /// Fixes common slips: "Blip: …" speaker prefixes, quotes, and (gasp) instead of <gasp>.
    private static func normalize(_ text: String, petName: String) -> String {
        var line = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        for prefix in [petName, "Pet", "\(petName) says"] where !prefix.isEmpty {
            if line.lowercased().hasPrefix(prefix.lowercased() + ":") {
                line = String(line.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        line = line.replacingOccurrences(of: "*", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "\"“” "))
        line = spelledEmotion.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "[$1$2] ")
        return parenthesisedEvent.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "<$1>")
    }

    /// "Nervous: Oh no…" → "[nervous] Oh no…"
    private static let spelledEmotion = try! NSRegularExpression(
        pattern: "^[(\\[]?(\(PetSpeech.emotions.joined(separator: "|")))[)\\]]?\\s*:\\s*|^\\((\(PetSpeech.emotions.joined(separator: "|")))\\)\\s*",
        options: .caseInsensitive)

    private static let parenthesisedEvent = try! NSRegularExpression(
        pattern: "(?<!\\()\\((\(PetSpeech.events.joined(separator: "|")))\\)(?!\\))", options: .caseInsensitive)

    /// Small models mix up who's who and call the user by the pet's name ("Welcome back, Blip!").
    private static func addressesPet(_ line: String, petName: String) -> Bool {
        let name = petName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return false }
        let shown = PetSpeech.display(line).lowercased()
        return shown.hasPrefix(name + ",") || shown.contains(", " + name)
    }

    private static func isUsable(_ line: String, for event: PetEvent) -> Bool {
        let shown = PetSpeech.display(line)
        guard !shown.isEmpty, line.count <= 200, !shown.contains("[") && !shown.contains("<"),
              shown.split(separator: " ").count <= 22, !shown.lowercased().contains("parenthes"), !shown.hasPrefix("(") else { return false }
        let range = NSRange(line.startIndex..., in: line)
        for match in placeholderPattern.matches(in: line, range: range) {
            guard let token = Range(match.range(at: 1), in: line) else { continue }
            let name = line[token].lowercased()
            guard allowedPlaceholders.contains(name) else { return false }
            if name == "app", !event.isDrift || event == .notTracking { return false }
            if name == "pet", event != .newPet { return false }
        }
        return true
    }
}

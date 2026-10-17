import Foundation
import Observation

/// Lines written by AI for each skill: 8 per moment for a persona, 4 per affected moment for a situation rule
/// (written for today's persona). Written ahead, not per moment, so the pet stays instant and works offline,
/// and rewritten once a day or soon after a skill changes, so the lines stay fresh.
@MainActor @Observable
final class PetLineLibrary {
    struct Entry: Codable {
        /// event → lines (with placeholders and voice markup).
        var lines: [String: [String]]
        /// What the lines were written from; a change means they're out of date.
        var signature: String
        var writtenAt: Date
        var engine: String?
    }

    struct Saved: Codable {
        var entries: [String: Entry] = [:]
    }

    private(set) var saved = Saved()
    private(set) var isWriting = false
    private(set) var progress: String?
    private(set) var lastError: String?

    static let personaLines = 8
    static let ruleLines = 4

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let ai: AIService
    @ObservationIgnored private let skills: PetSkillStore
    @ObservationIgnored private var lastAttemptAt: Date = .distantPast
    @ObservationIgnored private var lastAttemptFailed = false
    @ObservationIgnored private var seenRevision = -1
    @ObservationIgnored private var revisionChangedAt: Date = .distantPast
    @ObservationIgnored private let fileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appending(path: "pet-skill-lines.json")
    }()

    init(settings: AppSettings, ai: AIService, skills: PetSkillStore) {
        self.settings = settings
        self.ai = ai
        self.skills = skills
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            saved = (try? decoder.decode(Saved.self, from: data)) ?? Saved()
        }
    }

    // MARK: Reading

    static func personaKey(_ persona: PetSkill) -> String { "persona:\(persona.id)" }
    static func ruleKey(_ rule: PetSkill, persona: PetSkill) -> String { "rule:\(rule.id)@\(persona.id)" }

    /// Lines for a moment, if they were written from the skill as it is now.
    func lines(for event: PetEvent, persona: PetSkill) -> [String]? {
        current(Self.personaKey(persona), signature: signature(persona: persona))?.lines[event.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    func lines(for event: PetEvent, rule: PetSkill, persona: PetSkill) -> [String]? {
        current(Self.ruleKey(rule, persona: persona), signature: signature(rule: rule, persona: persona))?
            .lines[event.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    func entry(for persona: PetSkill) -> Entry? { saved.entries[Self.personaKey(persona)] }
    func entry(for rule: PetSkill, persona: PetSkill) -> Entry? { saved.entries[Self.ruleKey(rule, persona: persona)] }

    private func current(_ key: String, signature: String) -> Entry? {
        guard let entry = saved.entries[key], entry.signature == signature else { return nil }
        return entry
    }

    var lastWritten: Entry? { saved.entries.values.max { $0.writtenAt < $1.writtenAt } }
    var totalLines: Int { saved.entries.values.reduce(0) { $0 + $1.lines.values.reduce(0) { $0 + $1.count } } }

    // MARK: What to write

    private struct Job {
        var key: String
        var signature: String
        var skill: PetSkill
        var persona: PetSkill
        var isRule: Bool { skill.kind == .situation }
        var events: [PetEvent] { isRule ? skill.moments : PetEvent.allCases }
    }

    private var jobs: [Job] {
        var jobs: [Job] = skills.personasToWrite.map {
            Job(key: Self.personaKey($0), signature: signature(persona: $0), skill: $0, persona: $0)
        }
        if let persona = skills.persona() {
            jobs += skills.situations.filter { $0.enabled && !$0.moments.isEmpty }.map {
                Job(key: Self.ruleKey($0, persona: persona), signature: signature(rule: $0, persona: persona), skill: $0, persona: persona)
            }
        }
        return jobs
    }

    private func isStale(_ job: Job, now: Date) -> Bool {
        guard let entry = saved.entries[job.key] else { return true }
        return entry.signature != job.signature || !Calendar.current.isDate(entry.writtenAt, inSameDayAs: now)
    }

    private func signature(persona: PetSkill) -> String {
        [persona.markdown, settings.petName, settings.petUserName].joined(separator: "\u{1}")
    }

    private func signature(rule: PetSkill, persona: PetSkill) -> String {
        [rule.markdown, signature(persona: persona)].joined(separator: "\u{1}")
    }

    private var preferredEngine: AIEngine? { AIEngine(rawValue: settings.petWriterEngine) }

    var canWrite: Bool { settings.petUseAI && (ai.hasEnabledEngine || preferredEngine != nil) && !jobs.isEmpty }

    /// Called every few seconds by the pet while nothing is happening: writes what's out of date
    /// (once a day, or 30 s after a skill changes). Waits an hour after a failure.
    func maintain(now: Date) {
        if skills.revision != seenRevision {
            seenRevision = skills.revision
            revisionChangedAt = now
        }
        guard canWrite, !isWriting, now.timeIntervalSince(revisionChangedAt) >= 30,
              now.timeIntervalSince(lastAttemptAt) >= (lastAttemptFailed ? 3600 : 120),
              jobs.contains(where: { isStale($0, now: now) }) else { return }
        Task { await write(force: false) }
    }

    // MARK: Writing

    /// Writes lines for the out-of-date skills, or for all of them with `force`.
    func write(force: Bool = true) async {
        guard !isWriting else { return }
        let now = Date.now
        let todo = jobs.filter { force || isStale($0, now: now) }
        guard !todo.isEmpty else { return }
        isWriting = true
        lastError = nil
        lastAttemptAt = now
        defer { isWriting = false; progress = nil }

        // The CLI engines handle long lists in one go; smaller models give up partway, so they get smaller asks.
        let big = preferredEngine?.executable != nil
        let personaJobs = todo.filter { !$0.isRule }
        let ruleJobs = todo.filter(\.isRule)
        let steps = personaJobs.count + (ruleJobs.isEmpty ? 0 : 1)
        var failures: [String] = []
        for (index, job) in personaJobs.enumerated() {
            progress = "Writing \(job.skill.name) lines (\(index + 1) of \(steps))…"
            var parsed: [String: [String]] = [:]
            var firstError: Error?
            let size = big ? job.events.count : 8
            for start in stride(from: 0, to: job.events.count, by: size) {
                let batch = Array(job.events[start..<min(start + size, job.events.count)])
                do {
                    let reply = try await ai.generate(instructions: instructions(for: job, count: Self.personaLines),
                                                      prompt: prompt(for: batch), preferring: preferredEngine)
                    merge(parse(reply), into: &parsed)
                } catch {
                    firstError = firstError ?? error
                }
            }
            if let failure = await finish(job, parsed: parsed, firstError: firstError) { failures.append(failure) }
        }
        if !ruleJobs.isEmpty {
            progress = "Writing situation lines (\(steps) of \(steps))…"
            let size = big ? 8 : 2
            for start in stride(from: 0, to: ruleJobs.count, by: size) {
                let chunk = Array(ruleJobs[start..<min(start + size, ruleJobs.count)])
                var replies: [String: [String: [String]]] = [:]
                var firstError: Error?
                do {
                    let reply = try await ai.generate(instructions: combinedInstructions(for: chunk), prompt: combinedPrompt(for: chunk),
                                                      preferring: preferredEngine)
                    replies = splitByRule(reply, rules: chunk.map(\.skill.id))
                } catch {
                    firstError = error
                }
                for job in chunk {
                    if let failure = await finish(job, parsed: replies[job.skill.id] ?? [:], firstError: firstError) { failures.append(failure) }
                }
            }
        }
        // Drop lines for skills that no longer exist.
        let live = Set(skills.skills.map(\.id))
        saved.entries = saved.entries.filter { key, _ in
            let ids = key.split(separator: ":").last?.split(separator: "@").map(String.init) ?? []
            return ids.allSatisfy(live.contains)
        }
        persist()
        lastAttemptFailed = !failures.isEmpty
        if !failures.isEmpty { lastError = failures.joined(separator: "\n") }
    }

    /// Asks again for thin moments (a few at a time), then saves the job's lines. Returns a failure message, if any.
    private func finish(_ job: Job, parsed: [String: [String]], firstError: Error?) async -> String? {
        var parsed = parsed
        let target = job.isRule ? Self.ruleLines : Self.personaLines
        let thin = job.events.filter { (parsed[$0.rawValue]?.count ?? 0) < max(2, target / 2) }
        if firstError == nil || !parsed.isEmpty {
            for start in stride(from: 0, to: thin.count, by: 4) {
                let batch = Array(thin[start..<min(start + 4, thin.count)])
                guard let reply = try? await ai.generate(instructions: instructions(for: job, count: target), prompt: prompt(for: batch),
                                                         preferring: preferredEngine) else { break }
                merge(parse(reply), into: &parsed)
            }
        }
        let missing = job.events.filter { parsed[$0.rawValue]?.isEmpty ?? true }
        guard missing.count * 2 < job.events.count else {
            return "\(job.skill.name): " + (firstError?.localizedDescription ?? "the AI reply wasn't in the expected format. Try another engine.")
        }
        saved.entries[job.key] = Entry(lines: parsed.mapValues { Array($0.prefix(target + 2)) }, signature: job.signature,
                                       writtenAt: .now, engine: ai.lastEngine?.title)
        persist()
        return nil
    }

    /// "rule-id.moment: line" rows → rule → moment → lines.
    private func splitByRule(_ reply: String, rules: [String]) -> [String: [String: [String]]] {
        var perRule: [String: [String]] = [:]
        for raw in reply.split(whereSeparator: \.isNewline) {
            let row = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*•` "))
            guard let colon = row.firstIndex(of: ":") else { continue }
            let key = row[..<colon].trimmingCharacters(in: CharacterSet(charactersIn: "*` "))
            guard let dot = key.lastIndex(of: ".") else { continue }
            let rule = key[..<dot].lowercased()
            guard rules.contains(rule) else { continue }
            perRule[rule, default: []].append(String(key[key.index(after: dot)...]) + ":" + row[row.index(after: colon)...])
        }
        return perRule.mapValues { parse($0.joined(separator: "\n")) }
    }

    private func merge(_ fresh: [String: [String]], into parsed: inout [String: [String]]) {
        for (key, lines) in fresh {
            let new = lines.filter { !(parsed[key]?.contains($0) ?? false) }
            parsed[key] = (parsed[key] ?? []) + new
        }
    }

    /// Three sample lines for a skill as it is in the editor (not saved yet), to try it before saving.
    func preview(_ skill: PetSkill) async throws -> [(PetEvent, String)] {
        let persona = skill.kind == .persona ? skill : (skills.persona() ?? PetSkillTemplates.personas[0])
        let events: [PetEvent] = skill.kind == .persona ? [.hello, .taskDone, .driftStart] : Array(skill.moments.prefix(3))
        guard !events.isEmpty else { return [] }
        let job = Job(key: "", signature: "", skill: skill, persona: persona)
        let reply = try await ai.generate(instructions: instructions(for: job, count: 1), prompt: prompt(for: events), preferring: preferredEngine)
        let parsed = parse(reply)
        return events.compactMap { event in parsed[event.rawValue]?.first.map { (event, $0) } }
    }

    /// Forgets the AI-written lines; the persona's examples and built-in lines are used until the next rewrite.
    func reset() {
        saved = Saved()
        lastError = nil
        lastAttemptAt = .now
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: Prompt

    private func instructions(for job: Job, count: Int) -> String {
        var who = "Who the pet is (persona “\(job.persona.name)”): \(job.persona.instructions)"
        if job.isRule, let condition = job.skill.condition {
            who += "\n\nRight now a special situation is true: \(condition.situation) How to adjust: \(job.skill.instructions)\n"
                + "Every line must fit BOTH the persona and this situation."
        }
        let samples = Array((job.isRule ? job.skill : job.persona).examples.values.flatMap { $0 }.prefix(10))
        return instructions(who: who, samples: samples, count: count, each: "moment the prompt lists", format: "momentName: line")
    }

    /// Several situation rules in one ask, to keep the number of AI calls down.
    private func combinedInstructions(for jobs: [Job]) -> String {
        guard let persona = jobs.first?.persona else { return "" }
        var who = "Who the pet is (persona “\(persona.name)”): \(persona.instructions)\n\nSituations (each line must fit BOTH the persona and its situation):"
        for job in jobs {
            who += "\n- \(job.skill.id): \(job.skill.condition?.situation ?? "") How to adjust: \(job.skill.instructions)"
        }
        let samples = Array(jobs.flatMap { $0.skill.examples.values.flatMap { $0 }.prefix(3) }.prefix(10))
        return instructions(who: who, samples: samples, count: Self.ruleLines, each: "situation + moment pair the prompt lists",
                            format: "situationId.momentName: line")
    }

    private func combinedPrompt(for jobs: [Job]) -> String {
        "Situation + moment pairs (id — what just happened):\n" + jobs.flatMap { job in
            job.events.map { "\(job.skill.id).\($0.rawValue) — \($0.situation)" }
        }.joined(separator: "\n")
    }

    private func instructions(who: String, samples: [String], count: Int, each: String, format: String) -> String {
        let userName = settings.petUserName.trimmingCharacters(in: .whitespaces)
        return """
        You write the lines for \(settings.petName), a tiny pet that sits next to a focus timer on a Mac and helps \
        a person with ADHD stay on task. Follow the persona closely, including its language.

        \(who)
        \(samples.isEmpty ? "" : "\nStyle samples (match the voice; don't copy them):\n" + samples.map { "- \($0)" }.joined(separator: "\n") + "\n")
        What the app does, so lines can mention it: a timer that logs time to Moxie (the user's client/project tool); \
        focus blocks that start with a 5-minute warm-up and end in a break screen; a task list ranked by due date; \
        it notices when the user switches to a distracting app or website while the timer runs and nudges them back; \
        it reminds them when they're working without a timer; daily streaks, levels and unlockable pets.
        What the pet and app do NOT do, so never claim or promise them: block or close apps or websites, see what's \
        on the screen beyond the app or site name, hear the user, read messages, know their calendar or meetings, \
        punish or report the user, or give medical advice. Don't diagnose or mention ADHD, and don't shame.

        Write \(count) different line\(count == 1 ? "" : "s") for EACH \(each). Every line: at most 14 words, \
        no quotes, at most one emoji, sounds natural spoken aloud. Make them varied and alive: different openings \
        (never two lines starting with the same word), a mix of questions, jokes, short commands, observations and \
        little stories. Never just restate the moment's description (not “You finished a task. Celebrate.”).
        The pet speaks in the first person as \(settings.petName); \(userName.isEmpty
            ? "it doesn't know the user's name unless the persona gives it" : "the user's name is \(userName); use it in at most a quarter of the lines"). \
        Placeholders the app fills in: {task} (current task name), {level} (the pet's level), {streak} \
        (days in a row). {app} (the distraction) is ONLY for driftStart, driftFirm and driftPrompt, and {pet} (a newly \
        unlocked pet) ONLY for newPet. Use placeholders in about half the lines; don't invent other placeholders.
        Voice tags (the speech bubble hides them, the voice acts them out). \(PetSpeech.tagFormatHelp)
        EVERY line must start with exactly one emotion. Most lines also get one sound where it fits, or one stressed word. \
        Never write emotions as plain words, bold or labels (no **Angry**, no Angry:).
        Example: [excited] [laugh] You closed {task}! That's [stress: huge].

        Output format, nothing else (no headings, no numbering, no blank commentary), one line each:
        \(format)
        """
    }

    private func prompt(for events: [PetEvent]) -> String {
        "Moments (name — what just happened):\n"
            + events.map { "\($0.rawValue) — \($0.situation)" }.joined(separator: "\n")
    }

    // MARK: Parsing

    nonisolated private static let placeholderPattern = try! NSRegularExpression(pattern: "\\{(\\w+)\\}")
    nonisolated private static let allowedPlaceholders: Set<String> = ["task", "level", "streak", "app", "pet"]

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
            let line = normalize(String(row[row.index(after: colon)...]), petName: petName, event: event)
            guard isUsable(line, for: event), !addressesPet(line, petName: petName),
                  !(result[event.rawValue]?.contains(line) ?? false) else { continue }
            result[event.rawValue, default: []].append(line)
        }
        return result.mapValues { Array($0.prefix(12)) }
    }

    /// Fixes common slips: "Blip: …" speaker prefixes and quotes; markup slips are fixed by `PetSpeech.normalize`.
    private static func normalize(_ text: String, petName: String, event: PetEvent) -> String {
        var line = text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”"))
        for prefix in [petName, "Pet", "\(petName) says"] where !prefix.isEmpty {
            if line.lowercased().hasPrefix(prefix.lowercased() + ":") {
                line = String(line.dropFirst(prefix.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return PetSpeech.normalize(line, defaultEmotion: PetSpeech.defaultEmotion(for: event))
    }

    /// Small models mix up who's who and call the user by the pet's name ("Welcome back, Blip!").
    private static func addressesPet(_ line: String, petName: String) -> Bool {
        let name = petName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return false }
        let shown = PetSpeech.display(line).lowercased()
        return shown.hasPrefix(name + ",") || shown.contains(", " + name)
    }

    nonisolated static func isUsable(_ line: String, for event: PetEvent) -> Bool {
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

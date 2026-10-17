import AppKit
import Observation

/// Which creature the pet is. All share moods, levels and accessories.
enum PetSpecies: String, CaseIterable, Identifiable {
    case blob, cat, dog, plant, ghost, robot, fox, owl, dragon
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blob: return "Blob spirit"
        case .cat: return "Cat"
        case .dog: return "Dog"
        case .plant: return "Plant"
        case .ghost: return "Ghost"
        case .robot: return "Robot"
        case .fox: return "Fox"
        case .owl: return "Owl"
        case .dragon: return "Dragon"
        }
    }

    enum Requirement: Equatable {
        case free, level(Int), streak(Int)

        var label: String {
            switch self {
            case .free: return "Free"
            case let .level(n): return "Level \(n)"
            case let .streak(n): return "🔥 \(n)-day streak"
            }
        }
    }

    /// How each pet is earned. Streaks count your best streak ever, so missing a day never takes a pet away.
    var requirement: Requirement {
        switch self {
        case .blob: return .free
        case .cat: return .level(2)
        case .dog: return .streak(2)
        case .plant: return .level(3)
        case .ghost: return .streak(3)
        case .robot: return .level(5)
        case .fox: return .level(7)
        case .owl: return .streak(5)
        case .dragon: return .level(10)
        }
    }
}

/// Things the pet can wear; unlocked by level.
enum PetAccessory: String, CaseIterable, Identifiable {
    case none, sparkle, bow, sprout, beanie, scarf, crown, halo
    var id: String { rawValue }

    var unlockLevel: Int {
        switch self {
        case .none: return 1
        case .sparkle: return 2
        case .bow: return 3
        case .sprout: return 4
        case .beanie: return 6
        case .scarf: return 8
        case .crown: return 10
        case .halo: return 15
        }
    }

    var title: String { rawValue == "none" ? "Nothing" : rawValue.capitalized }
}

/// The blob spirit next to the pill: reacts to focus and drift, keeps a daily mood and levels up with XP.
/// It observes the other stores (stats, drift, focus phases) instead of being called by them.
@MainActor @Observable
final class PetStore {
    enum Expression { case idle, focused, happy, celebrating, worried, upset, sleeping }

    private struct Persisted: Codable {
        var xp: Double = 0
        var mood: Double = 60
        var day: String = ""
        var saidHello = false
        /// Optional so state saved by older versions still decodes. Set once past stats are counted as XP.
        var seeded: Bool?
        /// Pets earned so far (raw values). Nil in state from older versions.
        var unlocked: [String]?
        var bestStreak: Int?
    }

    private struct Snapshot {
        var day = StatsStore.Day()
        var drift: ActivityWatcher.Nudge = .none
        var nudge: ActivityWatcher.Nudge = .none
        var phase: FocusBlock.Phase?
        var idlePending = false
        var level = 1
    }

    private(set) var mood: Double = 60
    private(set) var xp: Double = 0
    private(set) var expression: Expression = .idle
    private(set) var line: String?
    private(set) var lineIsDrift = false

    var level: Int { Self.level(forXP: xp) }
    var progressToNext: Double {
        let low = Self.xp(forLevel: level), high = Self.xp(forLevel: level + 1)
        return min(max((xp - low) / (high - low), 0), 1)
    }
    var nextUnlock: PetAccessory? { PetAccessory.allCases.first { $0.unlockLevel > level } }
    var unlocked: [PetAccessory] { PetAccessory.allCases.filter { $0.unlockLevel <= level } }

    var species: PetSpecies {
        let chosen = PetSpecies(rawValue: settings.petSpecies) ?? .blob
        return unlockedSpecies.contains(chosen) ? chosen : .blob
    }

    private(set) var unlockedSpecies: Set<PetSpecies> = [.blob]
    private(set) var bestStreak = 0
    /// Last pet unlocked, for the celebration line.
    @ObservationIgnored private var newlyUnlocked: PetSpecies?

    func isUnlocked(_ species: PetSpecies) -> Bool { unlockedSpecies.contains(species) }

    /// 0…1 toward a locked pet's requirement.
    func progress(toward species: PetSpecies) -> Double {
        switch species.requirement {
        case .free: return 1
        case let .level(n):
            return min(1, xp / max(1, Self.xp(forLevel: n)))
        case let .streak(n):
            return min(1, Double(max(bestStreak, stats.streak())) / Double(n))
        }
    }

    private func meets(_ requirement: PetSpecies.Requirement) -> Bool {
        switch requirement {
        case .free: return true
        case let .level(n): return level >= n
        case let .streak(n): return max(bestStreak, stats.streak()) >= n
        }
    }

    /// Unlocks every pet whose requirement is met. Returns the ones that are new.
    @discardableResult
    private func checkUnlocks() -> [PetSpecies] {
        bestStreak = max(bestStreak, stats.streak())
        let fresh = PetSpecies.allCases.filter { !unlockedSpecies.contains($0) && meets($0.requirement) }
        guard !fresh.isEmpty else { return [] }
        unlockedSpecies.formUnion(fresh)
        save()
        return fresh
    }

    /// The next pet still to earn, for the card.
    var nextPet: PetSpecies? { PetSpecies.allCases.first { !unlockedSpecies.contains($0) } }

    /// What it's wearing: the chosen accessory, or the best unlocked one on "auto".
    var accessory: PetAccessory {
        if let chosen = PetAccessory(rawValue: settings.petAccessory), chosen.unlockLevel <= level { return chosen }
        return unlocked.last ?? .none
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let stats: StatsStore
    @ObservationIgnored private let activity: ActivityWatcher
    @ObservationIgnored private let focus: FocusStore
    @ObservationIgnored private let timer: TimerStore
    @ObservationIgnored private let idle: IdleMonitor
    @ObservationIgnored private let ai: AIService
    @ObservationIgnored private let voice: PetVoice
    @ObservationIgnored private let library: PetLineLibrary
    @ObservationIgnored private let skills: PetSkillStore
    /// Lines said recently, so the pet doesn't repeat itself.
    @ObservationIgnored private var memory = PetLineMemory()
    @ObservationIgnored private var driftTimes: [Date] = []
    /// Start of the current stretch of work without a break.
    @ObservationIgnored private var workSince: Date?
    @ObservationIgnored private var lastTrackingAt: Date = .distantPast
    @ObservationIgnored private var lastAway: (minutes: Int, at: Date)?
    @ObservationIgnored private var lastSkillCheck: Date = .distantPast
    @ObservationIgnored private var state = Persisted()
    @ObservationIgnored private var last = Snapshot()
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var transient: (expression: Expression, until: Date)?
    @ObservationIgnored private var lineUntil: Date = .distantPast
    @ObservationIgnored private var lastLineAt: Date = .distantPast
    @ObservationIgnored private var lastAIAt: Date = .distantPast
    /// The next line for each moment, written (and voiced) ahead of time.
    @ObservationIgnored private var upNext: [PetEvent: Prepared] = [:]
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrepareAt: Date = .distantPast
    @ObservationIgnored private var preparedSignature = ""
    @ObservationIgnored private var prepareRun = 0
    @ObservationIgnored private var cleanFocusSince: Date?
    @ObservationIgnored private var lastSave: Date = .distantPast
    @ObservationIgnored private let storageKey = "petState"
    @ObservationIgnored private let memoryKey = "petLineMemory"

    /// A line written ahead of time, and the situation it was written for.
    private struct Prepared {
        var template: String
        var situation: String
    }

    init(settings: AppSettings, stats: StatsStore, activity: ActivityWatcher, focus: FocusStore,
         timer: TimerStore, idle: IdleMonitor, ai: AIService, voice: PetVoice, library: PetLineLibrary, skills: PetSkillStore) {
        self.settings = settings
        self.stats = stats
        self.activity = activity
        self.focus = focus
        self.timer = timer
        self.idle = idle
        self.ai = ai
        self.voice = voice
        self.library = library
        self.skills = skills
        if let data = UserDefaults.standard.data(forKey: memoryKey),
           let saved = try? JSONDecoder().decode(PetLineMemory.self, from: data) {
            memory = saved
        }
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = saved
        }
        mood = state.mood
        xp = state.xp
        if state.seeded != true {
            // XP used to count only what happened after the pet arrived; include earlier focus once.
            xp = max(xp, Self.xp(fromHistory: stats))
            state.seeded = true
        }
        bestStreak = state.bestStreak ?? 0
        if let saved = state.unlocked {
            unlockedSpecies = Set(saved.compactMap(PetSpecies.init(rawValue:))).union([.blob])
        } else {
            // First run with unlocks: keep whichever pet is already chosen, so nobody loses theirs.
            unlockedSpecies = [.blob, PetSpecies(rawValue: settings.petSpecies) ?? .blob]
        }
        checkUnlocks()
        save()

        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    // MARK: Levels

    /// XP needed to reach a level: 0, 60, 180, 360, 600… (1 XP ≈ 1 focused minute).
    static func xp(forLevel level: Int) -> Double { 30 * Double(level) * Double(level - 1) }

    static func level(forXP xp: Double) -> Int {
        var level = 1
        while Self.xp(forLevel: level + 1) <= xp { level += 1 }
        return level
    }

    /// XP implied by all recorded stats: 1 per focused minute plus the same bonuses as live events.
    static func xp(fromHistory stats: StatsStore) -> Double {
        stats.days.values.reduce(0) { total, day in
            total + day.focusSeconds / 60 + Double(day.blocksCompleted * 10 + day.tasksDone * 20 + day.cameBack * 5 + day.checkInsOnTask * 2)
        }
    }

    var xpForNextLevel: Double { Self.xp(forLevel: level + 1) }

    // MARK: Tick

    private func tick() {
        guard settings.petEnabled else { return }
        let now = Date.now
        rollOverDayIfNeeded(now)

        let today = stats.day(now)
        let current = Snapshot(
            day: today, drift: activity.drift, nudge: activity.nudge, phase: focus.block?.phase,
            idlePending: idle.pending != nil, level: level
        )
        // The first tick only records the baseline, so restarting the app doesn't replay old events.
        guard primed else {
            last = current
            primed = true
            if !state.saidHello, settings.isConfigured {
                state.saidHello = true
                say(.hello)
            }
            return
        }
        prepareLines(now: now)
        trackContext(current: current, now: now)

        var events: [PetEvent] = []
        if today.focusSeconds > last.day.focusSeconds { gain(xp: (today.focusSeconds - last.day.focusSeconds) / 60) }
        if today.blocksCompleted > last.day.blocksCompleted { gain(xp: 10, mood: 8); events.append(.blockDone) }
        if today.tasksDone > last.day.tasksDone { gain(xp: 20, mood: 12); events.append(.taskDone) }
        if today.cameBack > last.day.cameBack { gain(xp: 5, mood: 6); events.append(.cameBack) }
        if today.checkInsOnTask > last.day.checkInsOnTask { gain(xp: 2, mood: 2); events.append(.checkInYes) }

        if current.drift != last.drift {
            switch current.drift {
            case .visual: gain(mood: -4); events.append(.driftStart); driftTimes.append(now)
            case .notified: gain(mood: -3); events.append(.driftFirm)
            case .prompted: gain(mood: -3); events.append(.driftPrompt)
            case .none: break
            }
        }
        if current.nudge >= .notified, last.nudge < .notified { gain(mood: -2); events.append(.notTracking) }
        if current.phase != last.phase {
            switch (last.phase, current.phase) {
            case (.warmup?, .focus?): events.append(.warmupDone)
            case (_, .onBreak?): events.append(.breakStart)
            case (_, .breakOver?): events.append(.breakOver)
            default: break
            }
        }
        if current.idlePending, !last.idlePending {
            if let away = idle.pending { lastAway = (Int(away.duration / 60), now) }
            events.append(.welcomeBack)
        }

        // A long clean stretch of focus earns a word of praise.
        let tracking = timer.session?.isRunning == true
        if tracking, activity.drift == .none {
            let since = cleanFocusSince ?? now
            cleanFocusSince = since
            if now.timeIntervalSince(since) >= 25 * 60 {
                cleanFocusSince = now
                gain(xp: 3, mood: 4)
                events.append(.focusMilestone)
            }
        } else {
            cleanFocusSince = nil
        }

        // Mood drifts with what you're doing right now.
        if activity.drift != .none {
            gain(mood: -0.05)
        } else if focus.block?.isWorking == true, focus.block?.pausedAt == nil {
            gain(mood: 0.02)
        } else if tracking {
            gain(mood: 0.01)
        } else {
            gain(mood: (55 - mood) * 0.0005)
        }

        if level > last.level { events.append(.levelUp) }
        if let pet = checkUnlocks().last {
            newlyUnlocked = pet
            events.append(.newPet)
        }
        // Show the most important reaction of this tick.
        if let event = events.max(by: { priority($0) < priority($1) }) { say(event) }

        last = current
        last.level = level
        updateExpression(now: now)
        if lineIsDrift, activity.drift == .none, activity.nudge < .notified { clearLine() }
        if !lineIsDrift, line != nil, now >= lineUntil { clearLine() }
        if now.timeIntervalSince(lastSave) >= 30 { save() }
    }

    // MARK: Context

    /// Keeps what situation rules need: drifts in the last hour, work since the last break; picks up skill edits
    /// and lets the line library rewrite itself while nothing is going on.
    private func trackContext(current: Snapshot, now: Date) {
        driftTimes.removeAll { now.timeIntervalSince($0) > 3600 }
        if timer.session?.isRunning == true {
            lastTrackingAt = now
            if workSince == nil { workSince = now }
        } else if now.timeIntervalSince(lastTrackingAt) > 600 {
            workSince = nil
        }
        if current.phase == .onBreak { workSince = nil }
        if now.timeIntervalSince(lastSkillCheck) >= 20 {
            lastSkillCheck = now
            skills.reload()
            if line == nil, activity.drift == .none, !isInCall() { library.maintain(now: now) }
        }
    }

    /// What's going on right now.
    func context(now: Date = .now) -> PetContext {
        let today = stats.day(now)
        let due: Date? = {
            if let due = focus.target?.due, !due.isEmpty { return MoxieTask.dayFormatter.date(from: String(due.prefix(10))) }
            return timer.draft.task.flatMap { taskDue($0.id) }
        }()
        let tracking = timer.session?.isRunning == true
        return PetContext(
            now: now, blocksToday: today.blocksCompleted, tasksToday: today.tasksDone,
            focusMinutesToday: Int(today.focusSeconds / 60), driftsToday: today.drifts,
            driftsLastHour: driftTimes.filter { now.timeIntervalSince($0) <= 3600 }.count, streak: stats.streak(now: now),
            minutesSinceBreak: tracking ? Int(now.timeIntervalSince(workSince ?? now) / 60) : 0, due: due,
            awayMinutes: lastAway.flatMap { now.timeIntervalSince($0.at) <= 900 ? $0.minutes : nil }
        )
    }

    /// Which rules apply to a moment, as a key (prepared lines are only used for the same situation).
    private func situationKey(_ rules: [PetSkill]) -> String {
        ([skills.persona()?.id ?? PetSkillStore.quietID] + rules.map(\.id)).joined(separator: "+")
    }

    private func priority(_ event: PetEvent) -> Int {
        switch event {
        case .newPet: return 11
        case .levelUp: return 10
        case .taskDone: return 9
        case .driftPrompt: return 8
        case .driftFirm: return 7
        case .blockDone: return 6
        case .cameBack: return 5
        case .driftStart, .notTracking: return 4
        case .breakStart, .breakOver, .warmupDone: return 3
        case .welcomeBack, .focusMilestone: return 2
        case .checkInYes, .hello: return 1
        }
    }

    private func gain(xp amount: Double = 0, mood delta: Double = 0) {
        xp += max(0, amount)
        mood = min(100, max(0, mood + delta))
    }

    private func updateExpression(now: Date) {
        if let transient, transient.until > now {
            expression = transient.expression
            return
        }
        transient = nil
        if activity.drift >= .notified { expression = .upset }
        else if activity.drift == .visual || activity.nudge >= .visual { expression = .worried }
        else if let phase = focus.block?.phase, phase == .onBreak || phase == .breakDue || phase == .breakOver { expression = .sleeping }
        else if timer.session?.isRunning == true { expression = .focused }
        else { expression = mood < 25 ? .worried : .idle }
    }

    private func rollOverDayIfNeeded(_ now: Date) {
        let key = StatsStore.key(now)
        guard state.day != key else { return }
        state.day = key
        state.saidHello = false
        // A fresh start each morning, a bit brighter if you're on a streak.
        mood = min(100, 55 + Double(min(stats.streak(now: now) * 3, 15)))
        last.day = stats.day(now)
        save()
    }

    // MARK: Talking

    /// Set by the app: the pet stays quiet during calls.
    @ObservationIgnored var isInCall: () -> Bool = { false }
    /// Set by the app: a task's due date by id, from the task list.
    @ObservationIgnored var taskDue: (String) -> Date? = { _ in nil }

    func say(_ event: PetEvent) {
        guard !isInCall() else { return }
        let now = Date.now
        let important = Self.importantEvents
        // Don't chatter: minor positive lines wait if something was said recently.
        if event.isPositive, !important.contains(event), now.timeIntervalSince(lastLineAt) < 20 { return }
        if skills.isQuiet, !important.contains(event), !event.isDrift { return }

        let context = context(now: now)
        let rules = skills.rules(for: event, context: context)
        let situation = situationKey(rules)
        // Lines carry voice markup ([excited], <laugh>…); the bubble shows them without it.
        // A line prepared ahead of time (AI text and voice audio) is used first, so it plays at once,
        // as long as it was written for the same persona and situation and wasn't said recently.
        var prepared = upNext.removeValue(forKey: event)
        if let ready = prepared, ready.situation != situation || memory.isRecent(ready.template, now: now) { prepared = nil }
        let template = prepared?.template ?? PetSpeech.withEmotion(pickLine(for: event, rules: rules), default: PetSpeech.defaultEmotion(for: event))
        let spoken = fill(template, for: event)
        let text = PetSpeech.display(spoken)
        guard !text.isEmpty else { return }
        line = text
        lineIsDrift = event.isDrift
        lastLineAt = now
        lineUntil = now.addingTimeInterval(event.isDrift ? 3600 : (important.contains(event) ? 9 : 7))
        memory.remember(template: template, said: spoken, at: now)
        if event.isPositive {
            let celebrate = event == .taskDone || event == .levelUp || event == .newPet || event == .blockDone
            transient = (celebrate ? .celebrating : .happy, now.addingTimeInterval(celebrate ? 5 : 3))
        }
        updateExpression(now: now)
        if event == .taskDone || event == .levelUp || event == .newPet { NSSound(named: "Funk")?.play() }

        let speakIt = !settings.petVoiceImportantOnly || important.contains(event)
        if prepared == nil, usesAI(for: event), now.timeIntervalSince(lastAIAt) >= 60 {
            lastAIAt = now
            let placeholder = text
            // Speak once, after the AI answers, so the voice doesn't say two different lines.
            Task { await writeWithAI(event, rules: rules, context: context, replacing: placeholder, thenSpeak: speakIt ? spoken : nil) }
        } else if speakIt {
            voice.speak(spoken)
        }
        lastPrepareAt = .distantPast
    }

    private static let importantEvents: Set<PetEvent> = [.taskDone, .levelUp, .newPet, .blockDone, .driftFirm, .driftPrompt, .cameBack]

    private func usesAI(for event: PetEvent) -> Bool {
        settings.petUseAI && ai.hasEnabledEngine && !skills.isQuiet
            && (Self.importantEvents.contains(event) || event == .hello || event == .notTracking || event == .welcomeBack)
    }

    /// A line for the moment, freshest first: a matching situation rule's lines most of the time, otherwise the
    /// persona's AI-written lines, its examples and (when those are few) the built-in lines.
    private func pickLine(for event: PetEvent, rules: [PetSkill]) -> String {
        guard let persona = skills.persona() else { return PetPhrases.line(for: event, tone: .quiet) }
        var situational: [String] = []
        for rule in rules {
            situational += library.lines(for: event, rule: rule, persona: persona) ?? []
            situational += rule.examples(for: event)
        }
        var pool = library.lines(for: event, persona: persona) ?? []
        pool += persona.examples(for: event)
        if pool.count < 6 { pool += PetPhrases.lines(for: event, tone: persona.base) }
        if !situational.isEmpty, Double.random(in: 0..<1) < 0.75, let fresh = memory.unused(situational) { return fresh }
        return memory.freshest(pool) ?? PetPhrases.line(for: event, tone: persona.base)
    }

    /// The name call ("David, listen up!") in front of a line, if it's on for this moment.
    private func calls(for event: PetEvent) -> Bool {
        switch settings.petCallMode {
        case "all": return true
        case "nudges": return event.isDrift
        default: return false
        }
    }

    private func userNameHint(for event: PetEvent) -> String {
        let name = settings.petUserName.trimmingCharacters(in: .whitespaces)
        var hint = name.isEmpty ? "" : " The user's name is \(name)."
        if calls(for: event) { hint += " Don't start with their name: the app puts a call to them in front of your line." }
        return hint
    }

    private func fill(_ template: String, for event: PetEvent) -> String {
        let filled = fill(template)
        return calls(for: event) ? PetSpeech.calling(filled, name: settings.petUserName, word: settings.petCallWord) : filled
    }

    private func fill(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{task}", with: activity.currentTaskName)
            .replacingOccurrences(of: "{name}", with: settings.petName)
            .replacingOccurrences(of: "{app}", with: activity.driftLabel ?? "that")
            .replacingOccurrences(of: "{level}", with: "\(level)")
            .replacingOccurrences(of: "{streak}", with: "\(stats.streak())")
            .replacingOccurrences(of: "{pet}", with: newlyUnlocked?.title ?? "a new pet")
    }

    private func writeWithAI(_ event: PetEvent, rules: [PetSkill], context: PetContext, replacing placeholder: String,
                             thenSpeak fallback: String?) async {
        let template = await aiLine(for: event, drift: activity.driftLabel, rules: rules, context: context, ahead: false)
        // Only swap if the built-in line is still showing.
        guard line == placeholder else { return }
        if let template {
            let written = fill(template, for: event)
            memory.remember(template: template, said: written)
            line = PetSpeech.display(written)
            if fallback != nil, !isInCall() { voice.speak(written) }
        } else if let fallback, !isInCall() {
            voice.speak(fallback)
        }
    }

    /// One line from the AI for a moment, as a template ({task} etc. filled in later), with voice markup.
    /// `ahead`: written before the moment happens, so today's counts may be one short and are left out.
    private func aiLine(for event: PetEvent, drift: String?, rules: [PetSkill], context: PetContext, ahead: Bool) async -> String? {
        guard let persona = skills.persona() else { return nil }
        var who = "Who you are (persona “\(persona.name)”): \(persona.instructions)"
        for rule in rules {
            if let condition = rule.condition { who += "\nRight now: \(condition.situation) How to adjust: \(rule.instructions)" }
        }
        let samples = (rules.flatMap { $0.examples(for: event) } + persona.examples(for: event)).prefix(4)
        let recent = memory.recentSaid(12)
        let instructions = """
        You are \(settings.petName), a tiny mascot that lives next to a focus timer and helps a person with ADHD stay \
        on task. Follow the persona closely, including its language.
        \(who)
        Reply with ONE short line, at most 16 words, no quotes, no markdown, at most one emoji. Make it specific to \
        this moment and the context; never just restate the situation (not “You finished a task. Celebrate.”), and \
        never repeat or paraphrase a recent line. Vary how you open. Write {task} where you'd say the task's name; \
        the app fills it in.\(userNameHint(for: event))\(Self.expressionRules)
        """
        var prompt = """
        Situation: \(event.situation)
        Context: \(context.summary(includeCounts: !ahead))
        Current task: {task}
        \(drift.map { "Distraction: \($0)" } ?? "")
        Your level: \(level).
        """
        if !samples.isEmpty { prompt += "\nStyle samples (match the voice, don't copy):\n" + samples.map { "- " + PetSpeech.display($0) }.joined(separator: "\n") }
        if !recent.isEmpty { prompt += "\nRecent lines (don't repeat):\n" + recent.map { "- \($0)" }.joined(separator: "\n") }
        guard let reply = try? await ai.generate(instructions: instructions, prompt: prompt),
              let first = reply.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }).first(where: { !$0.isEmpty })
        else { return nil }
        let written = PetSpeech.normalize(first, defaultEmotion: PetSpeech.defaultEmotion(for: event))
        // Placeholders it may use; {app} only when the distraction is known.
        let usable = PetLineLibrary.isUsable(written, for: event) && (drift != nil || !written.contains("{app}"))
        return usable && written.count <= 200 && !memory.isRecent(written) ? written : nil
    }

    private static let expressionRules = """
     The voice acts the line out from tags the bubble hides. \(PetSpeech.tagFormatHelp) ALWAYS start with exactly \
    one emotion; where it fits, add one sound and stress one key word. Never write the emotion as a plain word, label or \
    bold text. Example: [stern] [scoff] Five minutes gone. Back to {task}, [stress: now].
    """

    // MARK: Lines prepared ahead

    /// Moments worth preparing: the ones the pet says often or that matter most.
    private static let preparedEvents: [PetEvent] = [
        .notTracking, .driftStart, .driftFirm, .driftPrompt, .cameBack, .taskDone, .blockDone, .breakStart,
        .breakOver, .warmupDone, .checkInYes, .focusMilestone, .welcomeBack, .hello,
    ]

    /// Fills `upNext` one moment at a time while nothing else is going on, and keeps the audio of each
    /// prepared line in the voice's cache (lines that mention {task} are rendered again after the task changes).
    private func prepareLines(now: Date) {
        // What the pet would say changed (persona, skills, names…): prepare again.
        let signature = [skills.persona(on: now)?.id ?? PetSkillStore.quietID, "\(skills.revision)", settings.petName,
                         "\(settings.petUseAI)", settings.petUserName, settings.petCallMode,
                         "\(library.lastWritten?.writtenAt.timeIntervalSince1970 ?? 0)"].joined(separator: "|")
        if signature != preparedSignature {
            resetPreparedLines()
            preparedSignature = signature
        }
        guard prepareTask == nil, now.timeIntervalSince(lastPrepareAt) >= 20, !isInCall() else { return }
        let slowVoice = voice.preparesAhead
        let anyAI = Self.preparedEvents.contains(where: usesAI)
        guard slowVoice || anyAI, !skills.isQuiet else { return }
        lastPrepareAt = now
        prepareRun += 1
        let run = prepareRun
        prepareTask = Task {
            defer { if prepareRun == run { prepareTask = nil } }
            for event in Self.preparedEvents {
                guard !Task.isCancelled, !isInCall() else { return }
                let context = context()
                let rules = skills.rules(for: event, context: context)
                let situation = situationKey(rules)
                if let ready = upNext[event], ready.situation != situation { upNext[event] = nil }
                if upNext[event] == nil {
                    var template = usesAI(for: event) ? await aiLine(for: event, drift: nil, rules: rules, context: context, ahead: true) : nil
                    if template == nil {
                        template = PetSpeech.withEmotion(pickLine(for: event, rules: rules), default: PetSpeech.defaultEmotion(for: event))
                    }
                    guard !Task.isCancelled else { return }
                    guard let template, PetSpeech.hasWords(template) else { continue }
                    upNext[event] = Prepared(template: template, situation: situation)
                }
                // {app} is only known at the moment itself, so those lines are voiced live.
                if let template = upNext[event]?.template, !template.contains("{app}"), voice.preparesAhead {
                    await voice.prepare(fill(template, for: event))
                }
            }
        }
    }

    private func resetPreparedLines() {
        prepareTask?.cancel()
        prepareTask = nil
        upNext.removeAll()
        lastPrepareAt = .distantPast
    }

    func clearLine() {
        if line != nil { voice.stop() }
        line = nil
        lineIsDrift = false
    }

    /// Clicking the pet: a random encouraging line.
    func poke() {
        transient = (.happy, Date.now.addingTimeInterval(2))
        lastLineAt = .distantPast
        say(activity.drift != .none ? .driftStart : (timer.session?.isRunning == true ? .checkInYes : .hello))
    }

    private func save() {
        lastSave = .now
        state.mood = mood
        state.xp = xp
        state.unlocked = unlockedSpecies.map(\.rawValue).sorted()
        state.bestStreak = bestStreak
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: storageKey) }
        if let data = try? JSONEncoder().encode(memory) { UserDefaults.standard.set(data, forKey: memoryKey) }
    }

    func saveNow() { save() }
}

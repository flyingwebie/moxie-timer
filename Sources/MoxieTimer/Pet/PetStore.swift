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
    @ObservationIgnored private var state = Persisted()
    @ObservationIgnored private var last = Snapshot()
    @ObservationIgnored private var primed = false
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var transient: (expression: Expression, until: Date)?
    @ObservationIgnored private var lineUntil: Date = .distantPast
    @ObservationIgnored private var lastLineAt: Date = .distantPast
    @ObservationIgnored private var lastAIAt: Date = .distantPast
    @ObservationIgnored private var cleanFocusSince: Date?
    @ObservationIgnored private var lastSave: Date = .distantPast
    @ObservationIgnored private let storageKey = "petState"

    init(settings: AppSettings, stats: StatsStore, activity: ActivityWatcher, focus: FocusStore,
         timer: TimerStore, idle: IdleMonitor, ai: AIService, voice: PetVoice, library: PetLineLibrary) {
        self.settings = settings
        self.stats = stats
        self.activity = activity
        self.focus = focus
        self.timer = timer
        self.idle = idle
        self.ai = ai
        self.voice = voice
        self.library = library
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

        var events: [PetEvent] = []
        if today.focusSeconds > last.day.focusSeconds { gain(xp: (today.focusSeconds - last.day.focusSeconds) / 60) }
        if today.blocksCompleted > last.day.blocksCompleted { gain(xp: 10, mood: 8); events.append(.blockDone) }
        if today.tasksDone > last.day.tasksDone { gain(xp: 20, mood: 12); events.append(.taskDone) }
        if today.cameBack > last.day.cameBack { gain(xp: 5, mood: 6); events.append(.cameBack) }
        if today.checkInsOnTask > last.day.checkInsOnTask { gain(xp: 2, mood: 2); events.append(.checkInYes) }

        if current.drift != last.drift {
            switch current.drift {
            case .visual: gain(mood: -4); events.append(.driftStart)
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
        if current.idlePending, !last.idlePending { events.append(.welcomeBack) }

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

    func say(_ event: PetEvent) {
        guard !isInCall() else { return }
        let now = Date.now
        let important: Set<PetEvent> = [.taskDone, .levelUp, .newPet, .blockDone, .driftFirm, .driftPrompt, .cameBack]
        // Don't chatter: minor positive lines wait if something was said recently.
        if event.isPositive, !important.contains(event), now.timeIntervalSince(lastLineAt) < 20 { return }
        if settings.petTone == PetTone.quiet.rawValue, !important.contains(event), !event.isDrift { return }

        // Lines carry voice markup ([excited], <laugh>…); the bubble shows them without it.
        let spoken = fill(pickLine(for: event))
        let text = PetSpeech.display(spoken)
        guard !text.isEmpty else { return }
        line = text
        lineIsDrift = event.isDrift
        lastLineAt = now
        lineUntil = now.addingTimeInterval(event.isDrift ? 3600 : (important.contains(event) ? 9 : 7))
        if event.isPositive {
            let celebrate = event == .taskDone || event == .levelUp || event == .newPet || event == .blockDone
            transient = (celebrate ? .celebrating : .happy, now.addingTimeInterval(celebrate ? 5 : 3))
        }
        updateExpression(now: now)
        if event == .taskDone || event == .levelUp || event == .newPet { NSSound(named: "Funk")?.play() }

        let speakIt = !settings.petVoiceImportantOnly || important.contains(event)
        if settings.petUseAI, ai.hasEnabledEngine, important.contains(event) || event == .hello || event == .notTracking,
           now.timeIntervalSince(lastAIAt) >= 60 {
            lastAIAt = now
            let placeholder = text
            // Speak once, after the AI answers, so the voice doesn't say two different lines.
            Task { await writeWithAI(event, replacing: placeholder, thenSpeak: speakIt ? spoken : nil) }
        } else if speakIt {
            voice.speak(spoken)
        }
    }

    private func pickLine(for event: PetEvent) -> String {
        let custom = (event.isDrift || !event.isPositive ? settings.petDriftLines : settings.petPraiseLines)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let relevant = event.isPositive || event.isDrift
        if relevant, !custom.isEmpty, Bool.random() || PetTone(rawValue: settings.petTone) == nil {
            return custom.randomElement()!
        }
        let tone = PetTone(rawValue: settings.petTone) ?? .warm
        let resolved = tone == .mix ? [PetTone.warm, .coach, .quiet].randomElement()! : tone
        // AI-written lines (Settings → Your pet) replace the built-in ones where they exist.
        return library.lines(for: event, tone: resolved)?.randomElement() ?? PetPhrases.line(for: event, tone: resolved)
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

    private func writeWithAI(_ event: PetEvent, replacing placeholder: String, thenSpeak fallback: String?) async {
        let tone = PetTone(rawValue: settings.petTone) ?? .warm
        let toneDescription: String = {
            switch tone == .mix ? [PetTone.warm, .coach, .quiet].randomElement()! : tone {
            case .warm, .mix: return "warm, playful and encouraging; tease gently when they drift"
            case .coach: return "short, direct and firm, like a sports coach"
            case .quiet: return "extremely brief: one emoji or a few words"
            }
        }()
        let style = settings.petStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        let instructions = """
        You are \(settings.petName), a tiny blob-spirit mascot that lives next to a focus timer and helps a person \
        with ADHD stay on task. Your tone: \(toneDescription).\(style.isEmpty ? "" : " The user asked you to talk like this: \(style).") \
        Reply with ONE short line, at most 16 words, no quotes, at most one emoji.\(voice.engine == .off ? "" : Self.expressionHint)
        """
        let prompt = """
        Situation: \(event.situation)
        Current task: \(activity.currentTaskName)
        \(activity.driftLabel.map { "Distraction: \($0)" } ?? "")
        Your level: \(level). Focus streak: \(stats.streak()) days.
        """
        let reply = try? await ai.generate(instructions: instructions, prompt: prompt)
        let text = reply?.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        // Only swap if the built-in line is still showing.
        guard line == placeholder else { return }
        let shown = PetSpeech.display(cleaned)
        if !shown.isEmpty, cleaned.count <= 200 {
            line = shown
            if fallback != nil, !isInCall() { voice.speak(cleaned) }
        } else if let fallback, !isInCall() {
            voice.speak(fallback)
        }
    }

    private static let expressionHint = """
     You may start with one emotion tag from \(PetSpeech.emotions.map { "[\($0)]" }.joined(separator: " ")) \
    and add at most one sound from \(PetSpeech.events.map { "<\($0)>" }.joined(separator: " ")); \
    wrap one key word in (((triple parentheses))) to stress it.
    """

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
    }

    func saveNow() { save() }
}

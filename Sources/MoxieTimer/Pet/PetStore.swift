import AppKit
import Observation

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
         timer: TimerStore, idle: IdleMonitor, ai: AIService) {
        self.settings = settings
        self.stats = stats
        self.activity = activity
        self.focus = focus
        self.timer = timer
        self.idle = idle
        self.ai = ai
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let saved = try? JSONDecoder().decode(Persisted.self, from: data) {
            state = saved
        }
        mood = state.mood
        xp = state.xp

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

    func say(_ event: PetEvent) {
        let now = Date.now
        let important: Set<PetEvent> = [.taskDone, .levelUp, .blockDone, .driftFirm, .driftPrompt, .cameBack]
        // Don't chatter: minor positive lines wait if something was said recently.
        if event.isPositive, !important.contains(event), now.timeIntervalSince(lastLineAt) < 20 { return }
        if settings.petTone == PetTone.quiet.rawValue, !important.contains(event), !event.isDrift { return }

        let text = fill(pickLine(for: event))
        guard !text.isEmpty else { return }
        line = text
        lineIsDrift = event.isDrift
        lastLineAt = now
        lineUntil = now.addingTimeInterval(event.isDrift ? 3600 : (important.contains(event) ? 9 : 7))
        if event.isPositive {
            let celebrate = event == .taskDone || event == .levelUp || event == .blockDone
            transient = (celebrate ? .celebrating : .happy, now.addingTimeInterval(celebrate ? 5 : 3))
        }
        updateExpression(now: now)
        if event == .taskDone || event == .levelUp { NSSound(named: "Funk")?.play() }

        if settings.petUseAI, ai.hasEnabledEngine, important.contains(event) || event == .hello || event == .notTracking,
           now.timeIntervalSince(lastAIAt) >= 60 {
            lastAIAt = now
            let placeholder = text
            Task { await writeWithAI(event, replacing: placeholder) }
        }
    }

    private func pickLine(for event: PetEvent) -> String {
        let custom = (event.isDrift || !event.isPositive ? settings.petDriftLines : settings.petPraiseLines)
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let relevant = event.isPositive || event.isDrift
        if relevant, !custom.isEmpty, Bool.random() || PetTone(rawValue: settings.petTone) == nil {
            return custom.randomElement()!
        }
        return PetPhrases.line(for: event, tone: PetTone(rawValue: settings.petTone) ?? .warm)
    }

    private func fill(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{task}", with: activity.currentTaskName)
            .replacingOccurrences(of: "{name}", with: settings.petName)
            .replacingOccurrences(of: "{app}", with: activity.driftLabel ?? "that")
            .replacingOccurrences(of: "{level}", with: "\(level)")
            .replacingOccurrences(of: "{streak}", with: "\(stats.streak())")
    }

    private func writeWithAI(_ event: PetEvent, replacing placeholder: String) async {
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
        Reply with ONE short line, at most 16 words, no quotes, at most one emoji.
        """
        let prompt = """
        Situation: \(event.situation)
        Current task: \(activity.currentTaskName)
        \(activity.driftLabel.map { "Distraction: \($0)" } ?? "")
        Your level: \(level). Focus streak: \(stats.streak()) days.
        """
        guard let reply = try? await ai.generate(instructions: instructions, prompt: prompt) else { return }
        let text = reply.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”"))
        // Only swap if the built-in line is still showing.
        guard !cleaned.isEmpty, cleaned.count <= 160, line == placeholder else { return }
        line = cleaned
    }

    func clearLine() {
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
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    func saveNow() { save() }
}

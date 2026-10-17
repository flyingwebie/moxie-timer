import Foundation

/// A skill shapes what the pet says. A persona is who's talking (one at a time); a situation rule changes how it
/// talks when something is true (late at night, task due today…). Each skill is a Markdown file the user can edit.
struct PetSkill: Identifiable, Equatable {
    enum Kind: String, CaseIterable { case persona, situation }

    /// The file name without `.md`.
    var id: String
    var kind: Kind
    var name: String
    var enabled = true
    /// The template it was made from, for "Reset to template".
    var template: String?
    /// Built-in lines used when the persona has no line of its own for a moment.
    var base: PetTone = .warm
    /// Situations only: when the rule applies.
    var condition: PetCondition?
    /// Situations only: the moments it changes.
    var moments: [PetEvent] = []
    /// Situations only: lower comes first when several match.
    var order = 100
    /// How to talk, in plain words. Shown to the AI.
    var instructions = ""
    /// Example lines per group: said as written, and shown to the AI as samples of the style.
    var examples: [PetMomentGroup: [String]] = [:]

    func affects(_ event: PetEvent) -> Bool { kind == .persona || moments.contains(event) }

    /// Example lines that fit a moment (placeholders checked).
    func examples(for event: PetEvent) -> [String] {
        (examples[PetMomentGroup(event)] ?? []).filter { PetLineLibrary.isUsable($0, for: event) }
    }
}

/// Groups of moments that example lines are written for, so a line is never said at the wrong time.
enum PetMomentGroup: String, CaseIterable, Identifiable {
    case hello, praise, drift, breaks, comeback
    var id: String { rawValue }

    init(_ event: PetEvent) {
        switch event {
        case .hello: self = .hello
        case .warmupDone, .blockDone, .taskDone, .focusMilestone, .checkInYes, .levelUp, .newPet: self = .praise
        case .driftStart, .driftFirm, .driftPrompt, .notTracking: self = .drift
        case .breakStart, .breakOver: self = .breaks
        case .cameBack, .welcomeBack: self = .comeback
        }
    }

    var title: String {
        switch self {
        case .hello: return "Saying hello"
        case .praise: return "Praise"
        case .drift: return "Drifting / timer off"
        case .breaks: return "Breaks"
        case .comeback: return "Coming back"
        }
    }
}

/// What a situation rule waits for. Only things the app can tell on its own.
enum PetCondition: String, CaseIterable, Identifiable {
    case morningStart, lateNight, weekEdge, dueToday, hyperfocus, roughPatch, onFire, longAway
    var id: String { rawValue }

    var title: String {
        switch self {
        case .morningStart: return "Morning, before the first block"
        case .lateNight: return "Late night (after 9 pm)"
        case .weekEdge: return "Monday morning or Friday afternoon"
        case .dueToday: return "Current task is due today or overdue"
        case .hyperfocus: return "90+ minutes without a break"
        case .roughPatch: return "3+ drifts in the last hour"
        case .onFire: return "3+ blocks today or a 5-day streak"
        case .longAway: return "Back after 30+ minutes away"
        }
    }

    /// For the AI prompt.
    var situation: String {
        switch self {
        case .morningStart: return "It's morning and the user hasn't finished a focus block yet today."
        case .lateNight: return "It's late at night."
        case .weekEdge: return "It's Monday morning or Friday afternoon."
        case .dueToday: return "The current task is due today or overdue."
        case .hyperfocus: return "The user has worked for over 90 minutes without a break."
        case .roughPatch: return "The user drifted to distractions 3 or more times in the last hour."
        case .onFire: return "The user is having a great run (3+ blocks today or a 5+ day streak)."
        case .longAway: return "The user just came back after more than 30 minutes away."
        }
    }

    /// The moments a new rule with this condition starts with.
    var defaultMoments: [PetEvent] {
        switch self {
        case .morningStart: return [.hello, .warmupDone, .notTracking, .welcomeBack]
        case .lateNight: return [.hello, .blockDone, .taskDone, .breakStart, .breakOver, .focusMilestone, .notTracking, .welcomeBack]
        case .weekEdge: return [.hello, .blockDone, .taskDone, .breakStart, .breakOver, .welcomeBack]
        case .dueToday: return [.hello, .cameBack, .driftStart, .driftFirm, .driftPrompt, .breakOver, .notTracking, .welcomeBack]
        case .hyperfocus: return [.focusMilestone, .checkInYes, .blockDone, .breakStart]
        case .roughPatch: return [.driftStart, .driftFirm, .driftPrompt, .cameBack, .breakOver, .checkInYes]
        case .onFire: return [.blockDone, .taskDone, .focusMilestone, .levelUp, .warmupDone, .cameBack]
        case .longAway: return [.welcomeBack, .hello, .breakOver, .notTracking]
        }
    }
}

// MARK: Markdown

extension PetSkill {
    /// A file like:
    /// ```
    /// ---
    /// kind: persona
    /// name: Coach
    /// ---
    /// ## How to talk
    /// Short and direct…
    /// ## Examples
    /// ### praise
    /// - [stern] Block done. Next.
    /// ```
    var markdown: String {
        var head = ["kind: \(kind.rawValue)", "name: \(name)", "enabled: \(enabled)"]
        if let template { head.append("template: \(template)") }
        if kind == .persona { head.append("base: \(base.rawValue)") }
        if kind == .situation {
            if let condition { head.append("when: \(condition.rawValue)") }
            head.append("moments: \(moments.map(\.rawValue).joined(separator: ", "))")
            head.append("order: \(order)")
        }
        var text = "---\n" + head.joined(separator: "\n") + "\n---\n\n## How to talk\n\n"
        text += instructions.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n## Examples\n"
        for group in PetMomentGroup.allCases {
            let lines = (examples[group] ?? []).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }
            text += "\n### \(group.rawValue)\n" + lines.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return text
    }

    init?(id: String, markdown: String) {
        var lines = markdown.components(separatedBy: .newlines)[...]
        var fields: [String: String] = [:]
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---" {
            lines = lines.dropFirst()
            while let line = lines.first, line.trimmingCharacters(in: .whitespaces) != "---" {
                lines = lines.dropFirst()
                guard let colon = line.firstIndex(of: ":") else { continue }
                fields[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            lines = lines.dropFirst()
        }
        guard let kind = fields["kind"].flatMap({ Kind(rawValue: $0.lowercased()) }) else { return nil }
        self.id = id
        self.kind = kind
        self.name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id
        self.enabled = fields["enabled"].map { $0.lowercased() != "false" && $0.lowercased() != "no" } ?? true
        self.template = fields["template"].flatMap { $0.isEmpty ? nil : $0 }
        self.base = fields["base"].flatMap { PetTone(rawValue: $0.lowercased()) } ?? .warm
        self.condition = fields["when"].flatMap { PetCondition(rawValue: $0) }
        self.moments = (fields["moments"] ?? "").split(separator: ",")
            .compactMap { PetEvent(rawValue: $0.trimmingCharacters(in: .whitespaces)) }
        self.order = fields["order"].flatMap { Int($0) } ?? 100
        if kind == .situation, moments.isEmpty, let condition { moments = condition.defaultMoments }

        var section = "", group: PetMomentGroup?
        var how: [String] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("### ") {
                group = PetMomentGroup(rawValue: line.dropFirst(4).trimmingCharacters(in: .whitespaces).lowercased())
                continue
            }
            if line.hasPrefix("## ") {
                section = line.dropFirst(3).lowercased()
                group = nil
                continue
            }
            if section.hasPrefix("example") {
                guard let group, line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
                let text = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty { examples[group, default: []].append(text) }
            } else if section.hasPrefix("how") {
                how.append(raw)
            }
        }
        instructions = how.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

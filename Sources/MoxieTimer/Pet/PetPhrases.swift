import Foundation

/// Things the pet reacts to.
enum PetEvent: String, CaseIterable {
    case hello, warmupDone, blockDone, taskDone, focusMilestone, cameBack, checkInYes, levelUp
    case driftStart, driftFirm, driftPrompt, notTracking
    case breakStart, breakOver, welcomeBack

    var isPositive: Bool {
        switch self {
        case .hello, .warmupDone, .blockDone, .taskDone, .focusMilestone, .cameBack, .checkInYes, .levelUp, .breakOver, .welcomeBack:
            return true
        case .driftStart, .driftFirm, .driftPrompt, .notTracking, .breakStart:
            return false
        }
    }

    var isDrift: Bool { self == .driftStart || self == .driftFirm || self == .driftPrompt || self == .notTracking }

    /// For the AI prompt.
    var situation: String {
        switch self {
        case .hello: return "The user just opened the app for the day."
        case .warmupDone: return "The user finished a 5-minute warm-up and is now properly focused."
        case .blockDone: return "The user just completed a full focus block."
        case .taskDone: return "The user finished and closed a task. Celebrate."
        case .focusMilestone: return "The user has stayed focused without drifting for a long stretch."
        case .cameBack: return "The user came back to work after drifting to a distraction. Praise the comeback."
        case .checkInYes: return "The user confirmed they are still on their task."
        case .levelUp: return "The pet just levelled up thanks to the user's focus."
        case .driftStart: return "The user just switched to a distraction while their timer runs. Gentle nudge."
        case .driftFirm: return "The user has been on a distraction for 2 minutes. Be firmer."
        case .driftPrompt: return "The user has been on a distraction for 5 minutes. Insist they go back now."
        case .notTracking: return "The user is working but forgot to start the timer."
        case .breakStart: return "A focus block ended and it's break time. Encourage resting."
        case .breakOver: return "The break is over; encourage getting back into it."
        case .welcomeBack: return "The user came back to the computer after being away."
        }
    }
}

enum PetTone: String, CaseIterable, Identifiable {
    case warm, coach, quiet, mix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .warm: return "Warm & playful"
        case .coach: return "Coach"
        case .quiet: return "Quiet"
        case .mix: return "Mix of all"
        }
    }
}

/// Built-in lines. Placeholders: {task}, {name}, {app}, {level}, {streak}.
enum PetPhrases {
    static func line(for event: PetEvent, tone: PetTone) -> String {
        let resolved = tone == .mix ? [PetTone.warm, .coach, .quiet].randomElement()! : tone
        return bank[resolved]?[event]?.randomElement() ?? ""
    }

    private static let bank: [PetTone: [PetEvent: [String]]] = [
        .warm: [
            .hello: ["Hi! Ready to do one thing at a time? ✨", "Hey! I saved you a spot next to the timer."],
            .warmupDone: ["You're in! I can feel the focus ✨", "Warm-up done — look at you go."],
            .blockDone: ["A whole block! I'm glowing 🌟", "Block done. That's how it's done!", "Yesss, another one. Proud of you."],
            .taskDone: ["TASK DONE! 🎉 Happy dance!", "You finished it! I'm doing laps of joy.", "Crossed off. That felt good, right?"],
            .focusMilestone: ["Still going strong on {task} 💪", "Deep in the zone. I'll be quiet."],
            .cameBack: ["Welcome back to {task}! That comeback counts.", "Yay, you're back! Distractions: 0, you: 1."],
            .checkInYes: ["Love it. Keep going 💛", "Good! I'm right here."],
            .levelUp: ["I levelled up to {level}! Thanks to you ✨", "Level {level}! Look at my new look!"],
            .driftStart: ["Psst… {app}? {task} misses you 👀", "Ooh, {app}. Quick peek, then back?"],
            .driftFirm: ["Two minutes on {app}… let's go back to {task}?", "I'm getting a bit sad here. Back to {task}? 🥺"],
            .driftPrompt: ["Okay, rescue mission: back to {task} now! 🚨", "Five minutes gone. Come back, I believe in you."],
            .notTracking: ["You're working but I'm not counting! Start the timer?", "Hey, the timer's asleep. Wake it up?"],
            .breakStart: ["Break time! Stretch, water, eyes off the screen 🌿", "Rest now — you earned it."],
            .breakOver: ["Break's over! Ready for round two?", "Recharged? Let's do {task}."],
            .welcomeBack: ["You're back! Missed you.", "Welcome back! Shall we pick up {task}?"],
        ],
        .coach: [
            .hello: ["New day. One task at a time.", "Let's set the first focus block."],
            .warmupDone: ["Warm-up done. Lock in.", "You're in. Stay on it."],
            .blockDone: ["Block complete. Solid work.", "That's a full block. Take the break."],
            .taskDone: ["Task closed. Next one.", "Done. That's progress."],
            .focusMilestone: ["Long focus run. Keep the pace.", "Clean stretch. Stay on {task}."],
            .cameBack: ["Good recovery. Back on {task}.", "Back on track. Keep it there."],
            .checkInYes: ["Confirmed. Carry on.", "Good. Eyes on {task}."],
            .levelUp: ["Level {level}. Earned it.", "Level {level} unlocked."],
            .driftStart: ["{app}. Not the task.", "Off task: {app}. Back to {task}."],
            .driftFirm: ["Two minutes on {app}. Return to {task}.", "Drifting. Close {app}."],
            .driftPrompt: ["Five minutes off task. Back to {task} now.", "Stop. Close {app}. {task}."],
            .notTracking: ["Working untracked. Start the timer.", "Timer's off. Fix that."],
            .breakStart: ["Break. Step away from the screen.", "Rest now. No screens."],
            .breakOver: ["Break over. Next block.", "Back to work: {task}."],
            .welcomeBack: ["Welcome back. Resume {task}.", "Back. Pick up where you left off."],
        ],
        .quiet: [
            .hello: ["👋"], .warmupDone: ["✨"], .blockDone: ["🌟"], .taskDone: ["🎉"], .focusMilestone: ["💪"],
            .cameBack: ["💛"], .checkInYes: ["👍"], .levelUp: ["⬆️ {level}"],
            .driftStart: ["👀"], .driftFirm: ["🥺"], .driftPrompt: ["🚨 {task}"], .notTracking: ["⏱?"],
            .breakStart: ["🌿"], .breakOver: ["☀️"], .welcomeBack: ["👋"],
        ],
    ]
}

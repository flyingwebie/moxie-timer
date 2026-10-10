import Foundation

/// Things the pet reacts to.
enum PetEvent: String, CaseIterable {
    case hello, warmupDone, blockDone, taskDone, focusMilestone, cameBack, checkInYes, levelUp, newPet
    case driftStart, driftFirm, driftPrompt, notTracking
    case breakStart, breakOver, welcomeBack

    var isPositive: Bool {
        switch self {
        case .hello, .warmupDone, .blockDone, .taskDone, .focusMilestone, .cameBack, .checkInYes, .levelUp, .newPet, .breakOver, .welcomeBack:
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
        case .newPet: return "The user's focus unlocked a new pet companion they can now choose. Celebrate it."
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
/// Each may carry voice markup (see `PetSpeech`): a leading [emotion], inline <event> beats, (((emphasis))).
enum PetPhrases {
    static func line(for event: PetEvent, tone: PetTone) -> String {
        let resolved = tone == .mix ? [PetTone.warm, .coach, .quiet].randomElement()! : tone
        return bank[resolved]?[event]?.randomElement() ?? ""
    }

    private static let bank: [PetTone: [PetEvent: [String]]] = [
        .warm: [
            .hello: ["[joyful] Hi! Ready to do (((one))) thing at a time? ✨", "[tender] Hey! I saved you a spot next to the timer."],
            .warmupDone: ["[excited] You're in! I can feel the focus ✨", "[joyful] Warm-up done <giggle> look at you go."],
            .blockDone: ["[excited] A (((whole))) block! I'm glowing 🌟", "[joyful] Block done. That's how it's done!", "[tender] Yesss, another one. Proud of you."],
            .taskDone: ["[excited] TASK DONE! <laugh> Happy dance! 🎉", "[joyful] You finished it! I'm doing laps of joy.", "[joyful] Crossed off. <sigh> That felt good, right?"],
            .focusMilestone: ["[tender] Still going strong on {task} 💪", "[tender] Deep in the zone. <pause> I'll be quiet."],
            .cameBack: ["[joyful] Welcome back to {task}! That comeback (((counts))).", "[excited] Yay, you're back! <giggle> Distractions: 0, you: 1."],
            .checkInYes: ["[tender] Love it. Keep going 💛", "[joyful] Good! I'm right here."],
            .levelUp: ["[excited] <gasp> I levelled up to {level}! Thanks to you ✨", "[excited] Level {level}! Look at my new look!"],
            .newPet: ["[excited] <gasp> You unlocked the {pet}! 🎉 Click me to meet them.", "[joyful] A new friend: the {pet}! Swap me in my card if you like 🥹"],
            .driftStart: ["[surprised] Psst… {app}? {task} misses you 👀", "[nervous] Ooh, {app}. <um> Quick peek, then back?"],
            .driftFirm: ["[sad] <sigh> Two minutes on {app}… let's go back to {task}?", "[sad] I'm getting a bit sad here. Back to {task}? 🥺"],
            .driftPrompt: ["[stern] Okay, rescue mission: back to {task} (((now)))! 🚨", "[tender] Five minutes gone. <pause> Come back, I believe in you."],
            .notTracking: ["[surprised] <gasp> You're working but I'm not counting! Start the timer?", "[joyful] Hey, the timer's asleep. Wake it up?"],
            .breakStart: ["[tender] Break time! Stretch, water, eyes off the screen 🌿", "[tender] <sigh> Rest now. You earned it."],
            .breakOver: ["[excited] Break's over! Ready for round two?", "[joyful] Recharged? Let's do {task}."],
            .welcomeBack: ["[joyful] You're back! Missed you.", "[tender] Welcome back! Shall we pick up {task}?"],
        ],
        .coach: [
            .hello: ["[mundane] New day. One task at a time.", "[stern] Let's set the first focus block."],
            .warmupDone: ["[stern] Warm-up done. Lock in.", "[stern] You're in. Stay on it."],
            .blockDone: ["[joyful] Block complete. Solid work.", "[mundane] That's a full block. Take the break."],
            .taskDone: ["[excited] Task closed. Next one.", "[joyful] Done. That's (((progress)))."],
            .focusMilestone: ["[stern] Long focus run. Keep the pace.", "[mundane] Clean stretch. Stay on {task}."],
            .cameBack: ["[joyful] Good recovery. Back on {task}.", "[stern] Back on track. Keep it there."],
            .checkInYes: ["[mundane] Confirmed. Carry on.", "[stern] Good. Eyes on {task}."],
            .levelUp: ["[excited] Level {level}. Earned it.", "[joyful] Level {level} unlocked."],
            .newPet: ["[joyful] {pet} unlocked. Earned.", "[mundane] New pet available: {pet}."],
            .driftStart: ["[stern] {app}. <pause> Not the task.", "[stern] Off task: {app}. Back to {task}."],
            .driftFirm: ["[stern] Two minutes on {app}. Return to {task}.", "[angry] <scoff> Drifting. Close {app}."],
            .driftPrompt: ["[angry] Five minutes off task. Back to {task} (((now))).", "[stern] Stop. <pause> Close {app}. {task}."],
            .notTracking: ["[stern] Working untracked. Start the timer.", "[stern] Timer's off. Fix that."],
            .breakStart: ["[mundane] Break. Step away from the screen.", "[stern] Rest now. No screens."],
            .breakOver: ["[stern] Break over. Next block.", "[stern] Back to work: {task}."],
            .welcomeBack: ["[mundane] Welcome back. Resume {task}.", "[mundane] Back. Pick up where you left off."],
        ],
        .quiet: [
            .hello: ["👋"], .warmupDone: ["✨"], .blockDone: ["🌟"], .taskDone: ["🎉"], .focusMilestone: ["💪"],
            .cameBack: ["💛"], .checkInYes: ["👍"], .levelUp: ["⬆️ {level}"], .newPet: ["🎁 {pet}"],
            .driftStart: ["👀"], .driftFirm: ["🥺"], .driftPrompt: ["🚨 {task}"], .notTracking: ["⏱?"],
            .breakStart: ["🌿"], .breakOver: ["☀️"], .welcomeBack: ["👋"],
        ],
    ]
}

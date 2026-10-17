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

    /// All built-in lines for a moment in a tone.
    static func lines(for event: PetEvent, tone: PetTone) -> [String] {
        bank[tone == .mix ? .warm : tone]?[event] ?? []
    }

    private static let bank: [PetTone: [PetEvent: [String]]] = [
        .warm: [
            .hello: ["[joyful] Hi! Ready to do (((one))) thing at a time? ✨", "[tender] Hey! I saved you a spot next to the timer.", "[excited] Good to see you! What's the first tiny win?", "[joyful] Hello hello! Shall we pick today's main thing?", "[tender] Coffee, deep breath, one task. Deal?", "[joyful] I stretched already. Your turn: first block?"],
            .warmupDone: ["[excited] You're in! I can feel the focus ✨", "[joyful] Warm-up done <giggle> look at you go.", "[tender] Engines warm. Now the good part.", "[excited] Five minutes in and already rolling!", "[joyful] Warm-up complete. {task}, here we come.", "[tender] That's the hardest bit done: starting."],
            .blockDone: ["[excited] A (((whole))) block! I'm glowing 🌟", "[joyful] Block done. That's how it's done!", "[tender] Yesss, another one. Proud of you.", "[excited] <laugh> Full block! My tail is wagging.", "[joyful] Look at that ring fill up. Beautiful.", "[tender] One more block in the bank. Go rest."],
            .taskDone: ["[excited] TASK DONE! <laugh> Happy dance! 🎉", "[joyful] You finished it! I'm doing laps of joy.", "[joyful] Crossed off. <sigh> That felt good, right?", "[excited] <gasp> {task} is DONE. Legend behaviour.", "[joyful] Bye bye, {task}! Off the list forever.", "[tender] Done and dusted. Take a second to enjoy it."],
            .focusMilestone: ["[tender] Still going strong on {task} 💪", "[tender] Deep in the zone. <pause> I'll be quiet.", "[joyful] Twenty-five minutes, no wandering. Wow.", "[tender] You're in flow. I'm tiptoeing.", "[joyful] Look at you, steady as a rock.", "[contemplative] This is what focus looks like. Nice."],
            .cameBack: ["[joyful] Welcome back to {task}! That comeback (((counts))).", "[excited] Yay, you're back! <giggle> Distractions: 0, you: 1.", "[tender] You noticed and came back. That's the skill.", "[joyful] And we're back! {task} missed you.", "[excited] Comeback of the day! 🎉", "[tender] Back on track. No harm done."],
            .checkInYes: ["[tender] Love it. Keep going 💛", "[joyful] Good! I'm right here.", "[joyful] Great, carry on, I'll keep watch.", "[tender] Steady wins it. Onward.", "[joyful] Perfect. {task} is lucky to have you.", "[tender] Noted! Back to it."],
            .levelUp: ["[excited] <gasp> I levelled up to {level}! Thanks to you ✨", "[excited] Level {level}! Look at my new look!", "[joyful] Level {level}! Your focus made me grow.", "[excited] <laugh> I'm level {level} now. Fancy!", "[tender] Level {level}. We did that together.", "[excited] Ding! Level {level}! More focus, more me."],
            .newPet: ["[excited] <gasp> You unlocked the {pet}! 🎉 Click me to meet them.", "[joyful] A new friend: the {pet}! Swap me in my card if you like 🥹", "[excited] The {pet} wants to join the team!", "[joyful] Ooh, the {pet} is free to play now!"],
            .driftStart: ["[surprised] Psst… {app}? {task} misses you 👀", "[nervous] Ooh, {app}. <um> Quick peek, then back?", "[surprised] Was that {app}? I saw that 👀", "[joyful] <giggle> {app} again? {task} is jealous.", "[nervous] Tiny detour to {app}? Let's keep it tiny.", "[tender] Hey, {task} is still open. Back soon?"],
            .driftFirm: ["[sad] <sigh> Two minutes on {app}… let's go back to {task}?", "[sad] I'm getting a bit sad here. Back to {task}? 🥺", "[nervous] {app} is winning. Want to beat it?", "[sad] <sob> {task} is waiting all alone.", "[tender] Okay, deep breath. Close {app}, open {task}.", "[stern] Two minutes now. Let's head back."],
            .driftPrompt: ["[stern] Okay, rescue mission: back to {task} (((now)))! 🚨", "[tender] Five minutes gone. <pause> Come back, I believe in you.", "[stern] Five minutes on {app}. Time to come home.", "[sad] I miss you! {task}, please?", "[stern] Let's break the spell: close {app}.", "[tender] No guilt. Just one click back to {task}."],
            .notTracking: ["[surprised] <gasp> You're working but I'm not counting! Start the timer?", "[joyful] Hey, the timer's asleep. Wake it up?", "[nervous] Um, is this time going anywhere? Timer?", "[joyful] Working hard! Shall I start counting?", "[surprised] Oops, no timer running. Want one?", "[tender] Let's make this time count. Start the timer?"],
            .breakStart: ["[tender] Break time! Stretch, water, eyes off the screen 🌿", "[tender] <sigh> Rest now. You earned it.", "[joyful] Break! Go look at something far away.", "[tender] Stand up, roll those shoulders. Ahh.", "[joyful] Snack o'clock? Your brain says yes.", "[tender] Close your eyes for a minute. I'll wait."],
            .breakOver: ["[excited] Break's over! Ready for round two?", "[joyful] Recharged? Let's do {task}.", "[joyful] Welcome back! Shall we start the next block?", "[excited] Fresh brain, fresh block. Let's go!", "[tender] Rested? Ease back into {task}.", "[joyful] Round two, fight! (Gently.)"],
            .welcomeBack: ["[joyful] You're back! Missed you.", "[tender] Welcome back! Shall we pick up {task}?", "[joyful] There you are! Ready when you are.", "[tender] Hi again. Where were we? Ah, {task}.", "[excited] Yay, company! Back to it?", "[tender] Welcome back. Small step first?"],
        ],
        .coach: [
            .hello: ["[mundane] New day. One task at a time.", "[stern] Let's set the first focus block.", "[stern] Morning. Pick the one thing. Go.", "[mundane] Plan's simple: start, focus, finish.", "[excited] Fresh day, fresh reps. Let's work.", "[stern] No warm-up talk. First block now."],
            .warmupDone: ["[stern] Warm-up done. Lock in.", "[stern] You're in. Stay on it.", "[mundane] Warm-up complete. Real work starts now.", "[stern] Engine's on. Keep it running.", "[joyful] Good start. Now hold the pace.", "[stern] Focus mode. {task}, nothing else."],
            .blockDone: ["[joyful] Block complete. Solid work.", "[mundane] That's a full block. Take the break.", "[excited] Another block banked. Strong.", "[stern] Block done. Rest, then repeat.", "[joyful] Clean block. That's discipline.", "[mundane] Good rep. Recover, then go again."],
            .taskDone: ["[excited] Task closed. Next one.", "[joyful] Done. That's (((progress))).", "[excited] {task}: finished. Big win.", "[stern] Closed it. Don't stop now.", "[joyful] Off the board. Well played.", "[excited] Done! Pick the next target."],
            .focusMilestone: ["[stern] Long focus run. Keep the pace.", "[mundane] Clean stretch. Stay on {task}.", "[joyful] Twenty-five clean minutes. Respect.", "[stern] You're locked in. Don't break it.", "[mundane] Steady. Exactly like that.", "[stern] Keep grinding on {task}."],
            .cameBack: ["[joyful] Good recovery. Back on {task}.", "[stern] Back on track. Keep it there.", "[stern] Reset done. Now push.", "[joyful] That's the comeback. Finish the set.", "[mundane] Drift over. Work resumes.", "[stern] Good. Eyes on {task} now."],
            .checkInYes: ["[mundane] Confirmed. Carry on.", "[stern] Good. Eyes on {task}.", "[stern] Copy. Keep moving.", "[mundane] Noted. Stay with it.", "[joyful] Good answer. Keep going.", "[stern] Then finish it."],
            .levelUp: ["[excited] Level {level}. Earned it.", "[joyful] Level {level} unlocked.", "[excited] Level {level}. The work shows.", "[stern] Level {level}. Raise the bar.", "[joyful] Level {level}. Keep stacking.", "[excited] Up to {level}. Next level's waiting."],
            .newPet: ["[joyful] {pet} unlocked. Earned.", "[mundane] New pet available: {pet}.", "[excited] {pet} joins the team.", "[joyful] Focus paid off: {pet} unlocked."],
            .driftStart: ["[stern] {app}. <pause> Not the task.", "[stern] Off task: {app}. Back to {task}.", "[stern] {app} isn't on the plan.", "[mundane] Noticed {app}. Return to {task}.", "[stern] Quick check: is {app} the task? No.", "[stern] Close {app}. {task} is waiting."],
            .driftFirm: ["[stern] Two minutes on {app}. Return to {task}.", "[angry] <scoff> Drifting. Close {app}.", "[stern] Enough {app}. Back to work.", "[stern] Two minutes lost. Win them back.", "[angry] {app} again? Back to {task}.", "[stern] Discipline now. Close it."],
            .driftPrompt: ["[angry] Five minutes off task. Back to {task} (((now))).", "[stern] Stop. <pause> Close {app}. {task}.", "[angry] Five minutes. That's the limit. Back.", "[stern] Decision time: {task} or {app}? Pick {task}.", "[stern] Reset. One click. Back to work.", "[angry] We're done with {app}. Move."],
            .notTracking: ["[stern] Working untracked. Start the timer.", "[stern] Timer's off. Fix that.", "[stern] No timer, no record. Start it.", "[mundane] This time counts too. Track it.", "[stern] Hit start. Then work.", "[mundane] Timer first, then the task."],
            .breakStart: ["[mundane] Break. Step away from the screen.", "[stern] Rest now. No screens.", "[mundane] Recovery is training. Take it.", "[stern] Stand up. Water. Breathe.", "[mundane] Break time. Earned, not optional.", "[stern] Off the screen. That's an order."],
            .breakOver: ["[stern] Break over. Next block.", "[stern] Back to work: {task}.", "[stern] Rested. Now go.", "[mundane] Break done. Start the block.", "[excited] Round two. Let's work.", "[stern] Back in. {task}, full focus."],
            .welcomeBack: ["[mundane] Welcome back. Resume {task}.", "[mundane] Back. Pick up where you left off.", "[stern] You're back. Restart the timer.", "[mundane] Back at it. One step on {task}.", "[stern] Good. Re-engage.", "[mundane] Welcome back. Next move: {task}."],
        ],
        .quiet: [
            .hello: ["👋"], .warmupDone: ["✨"], .blockDone: ["🌟"], .taskDone: ["🎉"], .focusMilestone: ["💪"],
            .cameBack: ["💛"], .checkInYes: ["👍"], .levelUp: ["⬆️ {level}"], .newPet: ["🎁 {pet}"],
            .driftStart: ["👀"], .driftFirm: ["🥺"], .driftPrompt: ["🚨 {task}"], .notTracking: ["⏱?"],
            .breakStart: ["🌿"], .breakOver: ["☀️"], .welcomeBack: ["👋"],
        ],
    ]
}

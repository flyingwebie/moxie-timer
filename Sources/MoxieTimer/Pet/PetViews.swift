import SwiftUI

/// The pet sitting next to the pill. Click it for its card.
struct PetPerch: View {
    @Environment(PetStore.self) private var pet
    @State private var showCard = false

    var body: some View {
        PetView(size: 46)
            .frame(width: 50, height: 46)
            .contentShape(Rectangle())
            .onTapGesture {
                pet.poke()
                showCard.toggle()
            }
            .help("\(pet.level > 1 ? "Level \(pet.level) · " : "")Click to see how you're doing together")
            .popover(isPresented: $showCard, arrowEdge: .bottom) { PetCard() }
    }
}

/// What the pet says, under the pill. Drift lines stay until you're back on track.
struct PetBubble: View {
    @Environment(PetStore.self) private var pet
    @Environment(ActivityWatcher.self) private var activity
    @Environment(AppSettings.self) private var settings

    var body: some View {
        if let line = pet.line {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(settings.petName.uppercased())
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(0.6)
                        .foregroundStyle(pet.lineIsDrift ? Theme.onBreak : Theme.running)
                    Text(line)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if pet.lineIsDrift, activity.drift != .none {
                        Button("Back to it") {
                            activity.backToWork(dropDrift: false)
                            pet.clearLine()
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .controlSize(.small)
                    }
                }
                Spacer(minLength: 0)
                Button { pet.clearLine() } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
            }
            .padding(12)
            .frame(width: 270, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder((pet.lineIsDrift ? Theme.onBreak : Theme.running).opacity(0.45), lineWidth: 1.2))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
    }
}

/// The pet's card: level, mood, wardrobe.
struct PetCard: View {
    @Environment(PetStore.self) private var pet
    @Environment(StatsStore.self) private var stats
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        let today = stats.day(.now)

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PetView(size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(settings.petName).font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.ink)
                    Text("Level \(pet.level) · \(moodWord)").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    if stats.streak() > 0 {
                        Text("🔥 \(stats.streak())-day streak").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.onBreak)
                    }
                }
            }

            meter("Mood", value: pet.mood / 100, color: pet.mood >= 70 ? Theme.running : (pet.mood >= 40 ? Theme.warmup : Theme.onBreak))
            meter("Next level · \(Int(pet.xp)) / \(Int(pet.xpForNextLevel)) XP", value: pet.progressToNext, color: Theme.navy)
            if let next = pet.nextUnlock {
                Text("Level \(next.unlockLevel) unlocks: \(next.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
            }
            if let nextPet = pet.nextPet {
                HStack(spacing: 8) {
                    PetBlob(expression: .sleeping, mood: 80, accessory: .none, time: 0, species: nextPet, level: 6)
                        .frame(width: 26, height: 26)
                        .saturation(0)
                        .opacity(0.6)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Next pet: \(nextPet.title) · \(nextPet.requirement.label)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.ink)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Theme.cream)
                                Capsule().fill(Theme.onBreak).frame(width: max(5, proxy.size.width * pet.progress(toward: nextPet)))
                            }
                        }
                        .frame(height: 6)
                    }
                }
            } else {
                Text("You've unlocked every pet 🏆").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.running)
            }

            Text("Today: \(today.blocksCompleted) blocks · \(DurationFormat.short(today.focusSeconds)) focus · \(today.tasksDone) done · came back \(today.cameBack)×")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)

            SpeciesPicker(selection: $settings.petSpecies, compact: true)

            HStack {
                Text("Wearing").font(.system(size: 12))
                Spacer()
                Picker("Wearing", selection: $settings.petAccessory) {
                    Text("Best unlocked").tag("auto")
                    ForEach(pet.unlocked) { item in Text(item.title).tag(item.rawValue) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 3) {
                CapsLabel("How to make \(settings.petName) happy")
                guide("timer", "Focus in a block (Focus tab)", "+1 XP / min")
                guide("scope", "Finish a focus block", "+10 XP")
                guide("checkmark.circle", "Complete a task or ticket", "+20 XP")
                guide("arrow.uturn.backward", "Come back after drifting", "+5 XP")
                guide("hand.thumbsup", "Answer “Yes” at check-ins", "+2 XP")
                Text("Its face shows what's happening now: worried when you drift or forget the timer, asleep on breaks.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private func guide(_ icon: String, _ text: String, _ reward: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.navy).frame(width: 14)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.ink)
            Spacer(minLength: 4)
            Text(reward).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.running)
        }
    }

    private var moodWord: String {
        switch pet.mood {
        case 85...: return "thrilled"
        case 70..<85: return "happy"
        case 50..<70: return "content"
        case 30..<50: return "a bit low"
        default: return "sad"
        }
    }

    private func meter(_ label: String, value: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CapsLabel(label)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.cream)
                    Capsule().fill(color).frame(width: max(6, proxy.size.width * value))
                }
            }
            .frame(height: 8)
        }
    }
}

struct PetSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIService.self) private var ai

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Your pet")
            Toggle("Show the pet next to the timer", isOn: $settings.petEnabled)
                .toggleStyle(.switch).tint(Theme.navy).controlSize(.small).font(.system(size: 12))

            SpeciesPicker(selection: $settings.petSpecies)

            HStack {
                Text("Name").font(.system(size: 12))
                Spacer()
                FieldBox { TextField("Blip", text: $settings.petName).textFieldStyle(.plain).font(.system(size: 12)) }
                    .frame(width: 150)
            }
            HStack {
                Text("Tone").font(.system(size: 12))
                Spacer()
                Picker("Tone", selection: $settings.petTone) {
                    ForEach(PetTone.allCases) { tone in Text(tone.title).tag(tone.rawValue) }
                }
                .labelsHidden()
                .frame(width: 150)
            }

            editor("Talk to me like…", text: $settings.petStyle,
                   placeholder: "e.g. Call me Davide, speak Italian, football metaphors, a bit sarcastic")
            editor("Your praise lines (one per line)", text: $settings.petPraiseLines,
                   placeholder: "Grande Davide! 🔥\nAnother one bites the dust")
            editor("Your get-back-on-track lines (one per line)", text: $settings.petDriftLines,
                   placeholder: "{app} again? {task} is waiting.\nPhone down, Davide.")
            Text("Use {task}, {app}, {name}, {level} or {streak} in your lines. Voices also understand [excited], <laugh> and (((emphasis))).")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Let AI write lines in my style", isOn: $settings.petUseAI)
                .toggleStyle(.switch).tint(Theme.navy).controlSize(.small).font(.system(size: 12))
                .disabled(!ai.hasEnabledEngine)
            Text(settings.petUseAI
                 ? "Uses the AI engines below (at most once a minute). A built-in line shows first and is replaced when the AI answers."
                 : "Built-in and your own lines are used. Turn on AI to follow your style even more closely, in any language.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)

            PetLinesWriter()
        }
    }

    private func editor(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            TextField(placeholder, text: text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(2...5)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.cream))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border))
        }
    }
}

/// Grid of live previews to choose the pet. Locked pets show what earns them.
struct SpeciesPicker: View {
    @Binding var selection: String
    var compact = false
    @Environment(PetStore.self) private var pet

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: compact ? 5 : 3), spacing: 6) {
                ForEach(PetSpecies.allCases) { species in
                    let unlocked = pet.isUnlocked(species)
                    let selected = pet.species == species
                    Button { if unlocked { selection = species.rawValue } } label: {
                        VStack(spacing: 2) {
                            ZStack(alignment: .bottomTrailing) {
                                PetBlob(expression: selected ? .happy : (unlocked ? .idle : .sleeping), mood: 80, accessory: .none,
                                        time: unlocked ? time : 0, species: species, level: 6)
                                    .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
                                    .saturation(unlocked ? 1 : 0)
                                    .opacity(unlocked ? 1 : 0.45)
                                if !unlocked {
                                    Image(systemName: "lock.fill")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(3)
                                        .background(Circle().fill(Theme.ink.opacity(0.7)))
                                }
                            }
                            if !compact {
                                Text(species.title)
                                    .font(.system(size: 10, weight: selected ? .bold : .regular))
                                    .foregroundStyle(unlocked ? (selected ? Theme.ink : Theme.muted) : Theme.faint)
                                if !unlocked {
                                    Text(species.requirement.label)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Theme.onBreak)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.navy.opacity(0.08) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.navy.opacity(0.5) : Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(unlocked ? species.title : "\(species.title) — unlock at \(species.requirement.label) (\(Int(pet.progress(toward: species) * 100))% there)")
                }
            }
        }
    }
}

/// Settings → Your pet: have AI write the pet's whole set of lines in the user's tone and style.
struct PetLinesWriter: View {
    @Environment(AppSettings.self) private var settings
    @Environment(AIService.self) private var ai
    @Environment(PetLineLibrary.self) private var library

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Built-in lines").font(.system(size: 12))
                    Text(status).font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                Spacer()
                if library.isWriting {
                    ProgressView().controlSize(.small)
                } else {
                    if library.saved != nil {
                        Button("Use the originals") { library.reset() }.controlSize(.small)
                    }
                    Button(library.saved == nil ? "Write new lines with AI" : "Rewrite") { Task { await library.write() } }
                        .buttonStyle(PrimaryButtonStyle())
                        .controlSize(.small)
                        .disabled(!ai.hasEnabledEngine || library.tonesToWrite.isEmpty)
                }
            }
            if let progress = library.progress {
                note(progress + " This can take a minute.")
            } else if !ai.hasEnabledEngine {
                note("Turn on an AI engine below to write new lines.")
            } else if library.tonesToWrite.isEmpty {
                note("The Quiet tone only uses emoji, so there's nothing to write.")
            } else {
                note("Writes \(PetLineLibrary.linesPerMoment) fresh lines for every moment (finishing, drifting, breaks…) in your tone and “Talk to me like…”, with voice expressions. They're saved on this Mac and replace the originals, so lines stay instant. Claude, Codex, Gemini or a good Ollama model write much better lines than Apple's on-device model.")
            }
            if let error = library.lastError {
                Text(error).font(.system(size: 10)).foregroundStyle(Theme.onBreak).fixedSize(horizontal: false, vertical: true)
            }
            if library.saved != nil {
                DisclosureGroup("See the lines") { lineList.padding(.top, 4) }
                    .font(.system(size: 11))
            }
        }
    }

    private var status: String {
        guard let saved = library.saved else { return "The originals that come with the app." }
        let tones = PetLineLibrary.writableTones.filter { library.count(for: $0) > 0 }
            .map { "\($0.title): \(library.count(for: $0))" }.joined(separator: ", ")
        let date = saved.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "AI-written \(date)\(saved.engine.map { " by \($0)" } ?? "") · \(tones)"
    }

    private var lineList: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(PetLineLibrary.writableTones.filter { library.count(for: $0) > 0 }) { tone in
                Text(tone.title).font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.ink)
                ForEach(PetEvent.allCases, id: \.self) { event in
                    if let lines = library.lines(for: event, tone: tone) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(event.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                            ForEach(lines, id: \.self) { line in
                                Text("• " + PetSpeech.display(line))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.ink)
                                    .help(line)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 10)).foregroundStyle(Theme.faint).fixedSize(horizontal: false, vertical: true)
    }
}

extension PetEvent {
    /// For the line list in Settings.
    var title: String {
        switch self {
        case .hello: return "Saying hello"
        case .warmupDone: return "Warm-up done"
        case .blockDone: return "Focus block done"
        case .taskDone: return "Task done"
        case .focusMilestone: return "Long focus stretch"
        case .cameBack: return "Came back from a distraction"
        case .checkInYes: return "Still on task"
        case .levelUp: return "Level up"
        case .newPet: return "New pet unlocked"
        case .driftStart: return "Drifting"
        case .driftFirm: return "Drifting for 2 minutes"
        case .driftPrompt: return "Drifting for 5 minutes"
        case .notTracking: return "Working without a timer"
        case .breakStart: return "Break starts"
        case .breakOver: return "Break over"
        case .welcomeBack: return "Back at the Mac"
        }
    }
}

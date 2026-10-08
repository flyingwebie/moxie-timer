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
            meter("Next level", value: pet.progressToNext, color: Theme.navy)
            if let next = pet.nextUnlock {
                Text("Level \(next.unlockLevel) unlocks: \(next.title)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
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
            Text("Focus, finished blocks, done tasks and comebacks raise \(settings.petName)'s mood and XP. Drifting makes it sad.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 280)
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
            Text("Use {task}, {app}, {name}, {level} or {streak} in your lines.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)

            Toggle("Let AI write lines in my style", isOn: $settings.petUseAI)
                .toggleStyle(.switch).tint(Theme.navy).controlSize(.small).font(.system(size: 12))
                .disabled(!ai.hasEnabledEngine)
            Text(settings.petUseAI
                 ? "Uses the AI engines below (at most once a minute). A built-in line shows first and is replaced when the AI answers."
                 : "Built-in and your own lines are used. Turn on AI to follow your style even more closely, in any language.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
                .fixedSize(horizontal: false, vertical: true)
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

/// Grid of live previews to choose the pet.
struct SpeciesPicker: View {
    @Binding var selection: String
    var compact = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: compact ? 6 : 3), spacing: 6) {
                ForEach(PetSpecies.allCases) { species in
                    let selected = selection == species.rawValue
                    Button { selection = species.rawValue } label: {
                        VStack(spacing: 2) {
                            PetBlob(expression: selected ? .happy : .idle, mood: 80, accessory: .none,
                                    time: time, species: species, level: 6)
                                .frame(width: compact ? 30 : 40, height: compact ? 30 : 40)
                            if !compact {
                                Text(species.title)
                                    .font(.system(size: 10, weight: selected ? .bold : .regular))
                                    .foregroundStyle(selected ? Theme.ink : Theme.muted)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Theme.navy.opacity(0.08) : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? Theme.navy.opacity(0.5) : Theme.border))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(species.title)
                }
            }
        }
    }
}

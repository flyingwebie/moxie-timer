import AppKit
import SwiftUI

/// The Pet Skills window: personas and situation rules on the left, the editor on the right.
@MainActor
final class PetSkillsWindow {
    static let shared = PetSkillsWindow()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let model = AppModel.shared
            let root = PetSkillsView()
                .environment(model.petSkills)
                .environment(model.petLines)
                .environment(model.settings)
                .environment(model.voice)
                .environment(model.ai)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false
            )
            window.title = "Pet Skills"
            window.contentView = NSHostingView(rootView: root)
            window.contentMinSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("PetSkillsWindow")
            if !window.setFrameUsingName("PetSkillsWindow") { window.center() }
            self.window = window
        }
        AppModel.shared.petSkills.reload()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PetSkillsView: View {
    @Environment(PetSkillStore.self) private var skills
    @Environment(AppSettings.self) private var settings
    @State private var selection: String?

    init(initial: String? = nil) {
        _selection = State(initialValue: initial)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            if let id = selection, let skill = skills.skill(id) {
                PetSkillEditor(original: skill, select: { selection = $0 }).id(id)
            } else {
                VStack(spacing: 8) {
                    Text("Pick a skill to edit").font(.system(size: 14, weight: .semibold))
                    Text("A persona is who the pet is. Situation rules change how it talks when something is true, like a task due today or a late night. Skills are Markdown files: you can also edit them in any editor.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { if selection == nil { selection = skills.persona()?.id ?? skills.personas.first?.id } }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section("Personas") {
                    ForEach(skills.personas) { persona in
                        HStack {
                            Text(persona.name).foregroundStyle(persona.enabled ? .primary : .secondary)
                            Spacer()
                            if skills.persona()?.id == persona.id {
                                Text(settings.petPersonaRotate ? "Today" : "Active")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.white)
                                    .padding(.horizontal, 6).padding(.vertical, 1)
                                    .background(Capsule().fill(Theme.navy))
                            }
                        }
                        .tag(persona.id)
                    }
                }
                Section("Situation rules (top wins)") {
                    ForEach(Array(skills.situations.enumerated()), id: \.element.id) { index, rule in
                        HStack(spacing: 6) {
                            Text("\(index + 1)").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary).frame(width: 14)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rule.name).foregroundStyle(rule.enabled ? .primary : .secondary)
                                Text(rule.condition?.title ?? "No condition").font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if selection == rule.id {
                                Button { skills.move(rule, by: -1) } label: { Image(systemName: "chevron.up") }
                                    .buttonStyle(.borderless).disabled(index == 0).help("Higher priority")
                                Button { skills.move(rule, by: 1) } label: { Image(systemName: "chevron.down") }
                                    .buttonStyle(.borderless).disabled(index == skills.situations.count - 1).help("Lower priority")
                            }
                        }
                        .tag(rule.id)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            HStack(spacing: 6) {
                Menu {
                    Button("New persona") { selection = skills.create(.persona).id }
                    Button("New situation rule") { selection = skills.create(.situation).id }
                    if skills.missingTemplates > 0 {
                        Divider()
                        Button("Restore \(skills.missingTemplates) deleted template\(skills.missingTemplates == 1 ? "" : "s")") {
                            skills.restoreMissingTemplates()
                        }
                    }
                } label: { Image(systemName: "plus") }
                    .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                Button("Open folder") { skills.revealInFinder() }.controlSize(.small)
            }
            .padding(8)
        }
    }
}

/// Edits a copy of a skill; Save writes the file.
private struct PetSkillEditor: View {
    let original: PetSkill
    let select: (String?) -> Void

    @Environment(PetSkillStore.self) private var skills
    @Environment(PetLineLibrary.self) private var library
    @Environment(AppSettings.self) private var settings
    @Environment(PetVoice.self) private var voice
    @State private var draft: PetSkill
    @State private var preview: [(PetEvent, String)] = []
    @State private var previewing = false
    @State private var previewError: String?
    @State private var confirmDelete = false

    init(original: PetSkill, select: @escaping (String?) -> Void) {
        self.original = original
        self.select = select
        _draft = State(initialValue: original)
    }

    private var changed: Bool { cleaned(draft) != original }
    private var isPersona: Bool { draft.kind == .persona }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    if isPersona { personaFields } else { situationFields }
                    field("How to talk", note: isPersona
                          ? "Who the pet is and how it speaks: attitude, words it likes, language. The AI follows this for every line."
                          : "How the pet should change its lines while this is true. Write {task} for the task's name.") {
                        textEditor($draft.instructions, minHeight: 90)
                    }
                    examplesSection
                    previewSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .onDisappear { if changed { saveDraft() } }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 10) {
            TextField("Name", text: $draft.name)
                .textFieldStyle(.plain)
                .font(.system(size: 20, weight: .bold))
            Spacer()
            Toggle(isPersona ? "In “Surprise me”" : "On", isOn: $draft.enabled)
                .toggleStyle(.switch).controlSize(.small)
                .help(isPersona ? "Whether “Surprise me” can pick this persona." : "Whether this rule is used.")
        }
    }

    private var personaFields: some View {
        HStack(spacing: 12) {
            if settings.petPersona == draft.id, !settings.petPersonaRotate {
                Label("Your active persona", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.running).font(.system(size: 12))
            } else {
                Button("Use as my persona") {
                    if changed { saveDraft() }
                    settings.petPersonaRotate = false
                    settings.petPersona = draft.id
                }
                .controlSize(.small)
            }
            Spacer()
            Text("Fallback lines").font(.system(size: 12)).foregroundStyle(.secondary)
            Picker("Fallback lines", selection: $draft.base) {
                Text("Warm & playful").tag(PetTone.warm)
                Text("Coach").tag(PetTone.coach)
            }
            .labelsHidden().frame(width: 150)
            .help("Built-in lines used for moments this persona has no line for yet.")
        }
    }

    private var situationFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("When", note: "Up to two rules apply at once; the higher one in the list wins.") {
                Picker("When", selection: Binding(get: { draft.condition ?? .lateNight }, set: { draft.condition = $0 })) {
                    ForEach(PetCondition.allCases) { condition in Text(condition.title).tag(condition) }
                }
                .labelsHidden().frame(width: 320)
            }
            field("Moments it changes", note: nil) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(PetEvent.allCases, id: \.self) { event in
                        Toggle(event.title, isOn: Binding(
                            get: { draft.moments.contains(event) },
                            set: { on in
                                if on { draft.moments = PetEvent.allCases.filter { draft.moments.contains($0) || $0 == event } }
                                else { draft.moments.removeAll { $0 == event } }
                            }
                        ))
                        .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }
                if let condition = draft.condition, Set(condition.defaultMoments) != Set(draft.moments) {
                    Button("Use the usual moments for “\(condition.title)”") { draft.moments = condition.defaultMoments }
                        .buttonStyle(.link).font(.system(size: 11))
                }
            }
        }
    }

    private var examplesSection: some View {
        field("Example lines", note: "One per line. Said as written when there's no AI line, and shown to the AI as samples of the style. Placeholders: {task}, {streak}, {level}; {app} only in drifting lines. Voice tags: [joyful] at the start, [laugh] anywhere, [stress: word].") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PetMomentGroup.allCases) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        textEditor(Binding(
                            get: { (draft.examples[group] ?? []).joined(separator: "\n") },
                            set: { text in
                                let lines = text.components(separatedBy: "\n")
                                draft.examples[group] = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } ? nil : lines
                            }
                        ), minHeight: 52)
                    }
                }
            }
        }
    }

    private var previewSection: some View {
        field("Preview", note: "Writes three sample lines from this skill as it is now, before you save. Uses the “Write with” engine in Settings → Pet.") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button(previewing ? "Writing…" : "Write 3 sample lines") { runPreview() }
                        .disabled(previewing)
                    if previewing { ProgressView().controlSize(.small) }
                }
                if let previewError {
                    Text(previewError).font(.system(size: 11)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(preview.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Button { voice.speak(Self.sample(item.1)) } label: { Image(systemName: "speaker.wave.2") }
                            .buttonStyle(.borderless).help("Hear it")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.0.title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            Text(PetSpeech.display(Self.sample(item.1))).font(.system(size: 12)).textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Duplicate") {
                if changed { saveDraft() }
                select(skills.duplicate(draft).id)
            }
            if draft.template != nil {
                Button("Reset to template") { if let fresh = skills.resetToTemplate(draft) { draft = fresh } }
            }
            Button("Show in Finder") { skills.revealInFinder(original) }
            Button("Delete", role: .destructive) { confirmDelete = true }
                .confirmationDialog("Delete “\(draft.name)”?", isPresented: $confirmDelete) {
                    Button("Delete", role: .destructive) {
                        skills.delete(original)
                        select(nil)
                    }
                } message: {
                    Text(draft.template != nil ? "You can bring it back later with + → Restore deleted templates." : "This can't be undone.")
                }
            Spacer()
            if changed {
                Button("Revert") { draft = original }
            }
            Button("Save") { saveDraft() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!changed)
        }
        .controlSize(.small)
        .padding(12)
    }

    // MARK: Helpers

    private func saveDraft() {
        draft = cleaned(draft)
        skills.save(draft)
    }

    private func runPreview() {
        previewing = true
        previewError = nil
        let skill = cleaned(draft)
        Task {
            defer { previewing = false }
            do {
                preview = try await library.preview(skill)
                if preview.isEmpty { previewError = "The AI reply wasn't in the expected format. Try again or pick another engine." }
            } catch {
                previewError = error.localizedDescription
            }
        }
    }

    /// Example lines without blank rows, as they'll be saved.
    private func cleaned(_ skill: PetSkill) -> PetSkill {
        var skill = skill
        skill.examples = skill.examples.mapValues { $0.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return skill
    }

    /// Fills placeholders with sample values for the preview.
    static func sample(_ template: String) -> String {
        template
            .replacingOccurrences(of: "{task}", with: "the client proposal")
            .replacingOccurrences(of: "{app}", with: "YouTube")
            .replacingOccurrences(of: "{level}", with: "4")
            .replacingOccurrences(of: "{streak}", with: "3")
            .replacingOccurrences(of: "{pet}", with: "Fox")
            .replacingOccurrences(of: "{name}", with: AppModel.shared.settings.petName)
    }

    private func field<Content: View>(_ title: String, note: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 13, weight: .semibold))
            if let note {
                Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
    }

    private func textEditor(_ text: Binding<String>, minHeight: CGFloat) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12))
            .scrollContentBackground(.hidden)
            .padding(6)
            .frame(minHeight: minHeight)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }
}

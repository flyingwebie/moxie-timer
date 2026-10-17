import AppKit
import Observation

/// The pet's skills: Markdown files in Application Support/MoxieTimer/Skills, editable in the app or any editor.
@MainActor @Observable
final class PetSkillStore {
    /// The persona id that means "emoji only".
    static let quietID = "quiet"

    private(set) var skills: [PetSkill] = []
    /// Goes up whenever a skill changes, so prepared and AI-written lines know to refresh.
    private(set) var revision = 0
    private(set) var lastError: String?

    var personas: [PetSkill] { skills.filter { $0.kind == .persona }.sorted { $0.name.localizedCompare($1.name) == .orderedAscending } }
    var situations: [PetSkill] { skills.filter { $0.kind == .situation }.sorted { ($0.order, $0.name) < ($1.order, $1.name) } }

    let folder: URL

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadPending = false

    init(settings: AppSettings, folder: URL? = nil) {
        self.settings = settings
        self.folder = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "MoxieTimer/Skills", directoryHint: .isDirectory)
        let firstRun = !FileManager.default.fileExists(atPath: self.folder.path)
        try? FileManager.default.createDirectory(at: self.folder, withIntermediateDirectories: true)
        if firstRun { seed() }
        reload()
        watch()
    }

    // MARK: Active skills

    /// Today's persona, or nil for Quiet (emoji only). "Surprise me" picks one enabled persona per day.
    func persona(on date: Date = .now) -> PetSkill? {
        if settings.petPersonaRotate {
            let pool = personas.filter(\.enabled)
            if !pool.isEmpty {
                let day = Calendar.current.ordinality(of: .day, in: .era, for: date) ?? 0
                return pool[day % pool.count]
            }
        }
        if settings.petPersona == Self.quietID { return nil }
        return skills.first { $0.id == settings.petPersona && $0.kind == .persona }
            ?? skills.first { $0.id == PetSkillTemplates.defaultPersona }
            ?? personas.first
    }

    var isQuiet: Bool { persona() == nil }

    /// The personas the AI writes lines for: today's, or every enabled one with "Surprise me".
    var personasToWrite: [PetSkill] {
        if settings.petPersonaRotate {
            let pool = personas.filter(\.enabled)
            if !pool.isEmpty { return pool }
        }
        return persona().map { [$0] } ?? []
    }

    /// Up to two enabled situation rules that apply right now and change this moment, most important first.
    func rules(for event: PetEvent, context: PetContext) -> [PetSkill] {
        Array(situations.filter { rule in
            rule.enabled && rule.affects(event) && rule.condition.map(context.matches) == true
        }.prefix(2))
    }

    // MARK: Editing

    func skill(_ id: String) -> PetSkill? { skills.first { $0.id == id } }

    func save(_ skill: PetSkill) {
        do {
            try skill.markdown.write(to: url(for: skill.id), atomically: true, encoding: .utf8)
            lastError = nil
        } catch {
            lastError = "Couldn't save \(skill.name): \(error.localizedDescription)"
        }
        reload()
    }

    @discardableResult
    func create(_ kind: PetSkill.Kind) -> PetSkill {
        var skill = PetSkill(id: uniqueID(kind == .persona ? "my-persona" : "my-rule"), kind: kind,
                             name: kind == .persona ? "My persona" : "My rule")
        if kind == .situation {
            skill.condition = .lateNight
            skill.moments = PetCondition.lateNight.defaultMoments
            skill.order = (situations.map(\.order).max() ?? 0) + 1
        }
        skill.instructions = kind == .persona ? "Describe who the pet is and how it talks." : "Describe how the pet should change its lines when this is true."
        save(skill)
        return skill
    }

    @discardableResult
    func duplicate(_ skill: PetSkill) -> PetSkill {
        var copy = skill
        copy.id = uniqueID(skill.id + "-copy")
        copy.name = skill.name + " copy"
        copy.template = nil
        if copy.kind == .situation { copy.order = skill.order }
        save(copy)
        return copy
    }

    func delete(_ skill: PetSkill) {
        try? FileManager.default.removeItem(at: url(for: skill.id))
        if settings.petPersona == skill.id { settings.petPersona = PetSkillTemplates.defaultPersona }
        reload()
    }

    /// The template's version, keeping the on/off switch and the rule order.
    func resetToTemplate(_ skill: PetSkill) -> PetSkill? {
        guard let id = skill.template, var fresh = PetSkillTemplates.template(id) else { return nil }
        fresh.id = skill.id
        fresh.enabled = skill.enabled
        if skill.kind == .situation { fresh.order = skill.order }
        save(fresh)
        return fresh
    }

    /// Brings back templates whose files were deleted.
    func restoreMissingTemplates() {
        let used = Set(skills.compactMap(\.template))
        for template in PetSkillTemplates.all where !used.contains(template.id) && skill(template.id) == nil {
            try? template.markdown.write(to: url(for: template.id), atomically: true, encoding: .utf8)
        }
        reload()
    }

    var missingTemplates: Int {
        let used = Set(skills.compactMap(\.template))
        return PetSkillTemplates.all.filter { !used.contains($0.id) && skill($0.id) == nil }.count
    }

    /// Moves a situation rule up or down in priority.
    func move(_ skill: PetSkill, by offset: Int) {
        var list = situations
        guard let index = list.firstIndex(where: { $0.id == skill.id }) else { return }
        let target = min(max(index + offset, 0), list.count - 1)
        guard target != index else { return }
        list.insert(list.remove(at: index), at: target)
        for (position, var rule) in list.enumerated() where rule.order != position + 1 {
            rule.order = position + 1
            try? rule.markdown.write(to: url(for: rule.id), atomically: true, encoding: .utf8)
        }
        reload()
    }

    func revealInFinder(_ skill: PetSkill? = nil) {
        if let skill {
            NSWorkspace.shared.activateFileViewerSelecting([url(for: skill.id)])
        } else {
            NSWorkspace.shared.open(folder)
        }
    }

    // MARK: Files

    func reload() {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let loaded = files.filter { $0.pathExtension.lowercased() == "md" }
            .compactMap { url -> PetSkill? in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return PetSkill(id: url.deletingPathExtension().lastPathComponent, markdown: text)
            }
            .sorted { $0.id < $1.id }
        guard loaded != skills else { return }
        skills = loaded
        revision += 1
    }

    private func url(for id: String) -> URL { folder.appending(path: id + ".md") }

    private func uniqueID(_ base: String) -> String {
        let slug = base.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        var id = slug, n = 2
        while FileManager.default.fileExists(atPath: url(for: id).path) { id = "\(slug)-\(n)"; n += 1 }
        return id
    }

    /// First run: copy the templates in, carrying over the old "Talk to me like…" text and own lines into Coach.
    private func seed() {
        for var template in PetSkillTemplates.all {
            if template.id == PetSkillTemplates.defaultPersona { template = migrated(template) }
            try? template.markdown.write(to: url(for: template.id), atomically: true, encoding: .utf8)
        }
        if settings.petPersona.isEmpty {
            settings.petPersona = settings.petTone == PetTone.quiet.rawValue ? Self.quietID : PetSkillTemplates.defaultPersona
        }
    }

    private func migrated(_ coach: PetSkill) -> PetSkill {
        var coach = coach
        let style = settings.petStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty { coach.instructions = style + "\n\n" + coach.instructions }
        func own(_ text: String) -> [String] {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        coach.examples[.praise, default: []].insert(contentsOf: own(settings.petPraiseLines), at: 0)
        coach.examples[.drift, default: []].insert(contentsOf: own(settings.petDriftLines), at: 0)
        return coach
    }

    /// Picks up edits made in other editors (they save by replacing the file, which changes the folder).
    private func watch() {
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.reloadPending else { return }
                self.reloadPending = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        self.reloadPending = false
                        self.reload()
                    }
                }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}

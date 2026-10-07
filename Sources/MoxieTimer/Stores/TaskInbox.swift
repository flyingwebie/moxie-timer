import Foundation
import Observation

/// Open Moxie tasks across all projects — the source for one-thing mode and "pick for me".
@MainActor @Observable
final class TaskInbox {
    private(set) var tasks: [MoxieTask] = []
    private(set) var isLoading = false
    private(set) var lastLoaded: Date?
    var lastError: String?

    /// Show only tasks assigned to me (plus unassigned ones).
    var onlyMine: Bool {
        didSet { UserDefaults.standard.set(onlyMine, forKey: "inboxOnlyMine") }
    }

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var myUserId: Int?
    @ObservationIgnored private var myUserEmail: String?

    init(settings: AppSettings) {
        self.settings = settings
        onlyMine = UserDefaults.standard.object(forKey: "inboxOnlyMine") as? Bool ?? true
    }

    /// Tasks after the "only mine" filter, best candidates first.
    var visibleTasks: [MoxieTask] {
        let filtered = tasks.filter { task in
            guard onlyMine, let me = myUserId else { return true }
            let assignees = task.assignedToList ?? []
            return assignees.isEmpty || assignees.contains(me)
        }
        return TaskInbox.ranked(filtered, now: .now)
    }

    func refreshIfStale() async {
        if let lastLoaded, Date.now.timeIntervalSince(lastLoaded) < 300, !tasks.isEmpty { return }
        await refresh()
    }

    func refresh() async {
        guard let api = settings.makeAPI() else {
            lastError = LogError.notConfigured.localizedDescription
            return
        }
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            await resolveMe(api)
            let all = try await api.allTasks()
            tasks = all.filter { $0.isOpen && $0.isSubTask != true }
            lastLoaded = .now
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Quick capture: creates the task in Moxie, assigned to me.
    @discardableResult
    func create(name: String, client: Ref?, project: Ref?, due: Date?) async throws -> MoxieTask {
        guard let api = settings.makeAPI() else { throw LogError.notConfigured }
        let email = settings.userEmail.trimmingCharacters(in: .whitespaces)
        let request = TaskCreateRequest(
            name: name,
            clientName: client?.name,
            projectName: project?.name,
            dueDate: due.map { MoxieTask.dayFormatter.string(from: $0) },
            assignedTo: email.isEmpty ? nil : [email]
        )
        let created = try await api.createTask(request)
        // Fall back to a local stand-in if Moxie's response didn't decode, so the user can focus on it straight away.
        let task = created ?? MoxieTask(
            id: "local-\(UUID().uuidString)", name: name, projectId: project?.id, status: nil, parentTaskId: nil,
            clientId: client?.id,
            client: client.map { .init(id: $0.id, name: $0.name) },
            project: project.map { .init(id: $0.id, name: $0.name) },
            dueDate: request.dueDate
        )
        tasks.insert(task, at: 0)
        return task
    }

    /// Moves the task to its project type's "complete" stage. Returns false if Moxie didn't confirm it.
    func markComplete(_ task: MoxieTask) async throws -> Bool {
        guard let api = settings.makeAPI() else { throw LogError.notConfigured }
        guard !task.id.hasPrefix("local-") else { throw UpdateError("This task hasn't synced with Moxie yet.") }
        let stages = try await api.taskStages(projectTypeId: task.projectTypeId)
        guard let done = stages.first(where: { $0.complete == true }) else {
            throw UpdateError("Couldn't find a “complete” stage for this project in Moxie.")
        }
        let updated = try await api.updateTask(id: task.id, fields: ["statusId": done.id])
        tasks.removeAll { $0.id == task.id }
        guard let updated else { return true }
        return updated.statusId == done.id || !(updated.completed ?? "").isEmpty
    }

    private func resolveMe(_ api: MoxieAPI) async {
        let email = settings.userEmail.trimmingCharacters(in: .whitespaces).lowercased()
        guard myUserId == nil || myUserEmail != email else { return }
        guard let users = try? await api.users() else { return }
        myUserId = users.first { $0.user.email?.lowercased() == email }?.user.userId
        myUserEmail = email
    }

    // MARK: Ranking

    /// Rule-based priority: overdue and due-soon first, then priority, then how long it's been waiting.
    static func score(_ task: MoxieTask, now: Date) -> Double {
        var score = Double(task.priorityRank) * 15
        if let due = task.due {
            let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: now), to: due).day ?? 0
            switch days {
            case ..<0: score += 100 + min(Double(-days) * 2, 40)
            case 0: score += 90
            case 1: score += 60
            case 2...7: score += 40 - Double(days) * 3
            default: break
            }
        }
        if let created = task.created.flatMap(parseTimestamp) {
            score += min(now.timeIntervalSince(created) / 86_400 * 0.5, 15)
        }
        return score
    }

    static func ranked(_ tasks: [MoxieTask], now: Date) -> [MoxieTask] {
        tasks.map { ($0, score($0, now: now)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.name < $1.0.name }
            .map(\.0)
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

import Foundation
import Observation

/// Cached clients / projects / tasks / tickets fetched from Moxie for the pickers.
@MainActor @Observable
final class Catalog {
    private(set) var clients: [MoxieClient] = []
    private(set) var projectsByClient: [String: [MoxieProject]] = [:]
    private(set) var tasksByProject: [String: [MoxieTask]] = [:]
    private(set) var ticketsByClient: [String: [MoxieTicket]] = [:]
    private(set) var loading: Set<String> = []
    var lastError: String?

    @ObservationIgnored private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func isLoading(_ key: String) -> Bool { loading.contains(key) }

    func reset() {
        clients = []
        projectsByClient = [:]
        tasksByProject = [:]
        ticketsByClient = [:]
    }

    func loadClients(force: Bool = false) async {
        guard force || clients.isEmpty else { return }
        await fetch("clients") { api in
            let result = try await api.clients()
            self.clients = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func loadProjects(for client: Ref, force: Bool = false) async {
        guard force || projectsByClient[client.id] == nil else { return }
        await fetch("projects:\(client.id)") { api in
            let result = try await api.projects(clientName: client.name)
            self.projectsByClient[client.id] = result
                .filter { $0.clientId == nil || $0.clientId == client.id }
                .sorted { ($0.isActive ? 0 : 1, $0.name.lowercased()) < ($1.isActive ? 0 : 1, $1.name.lowercased()) }
        }
    }

    func loadTasks(for project: Ref, force: Bool = false) async {
        guard force || tasksByProject[project.id] == nil else { return }
        await fetch("tasks:\(project.id)") { api in
            let result = try await api.tasks(projectId: project.id)
            self.tasksByProject[project.id] = result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    func loadTickets(for client: Ref, force: Bool = false) async {
        guard force || ticketsByClient[client.id] == nil else { return }
        await fetch("tickets:\(client.id)") { api in
            let result = try await api.tickets(clientId: client.id)
            self.ticketsByClient[client.id] = result.sorted { ($0.ticketNumber ?? 0) > ($1.ticketNumber ?? 0) }
        }
    }

    private func fetch(_ key: String, _ work: (MoxieAPI) async throws -> Void) async {
        guard let api = settings.makeAPI() else {
            lastError = "Add your Moxie API key in Settings."
            return
        }
        guard !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        do {
            try await work(api)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }
}

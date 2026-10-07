import Foundation

/// Thin client for the Moxie Public API (https://api-docs.withmoxie.com).
struct MoxieAPI: Sendable {
    let baseURL: URL
    let apiKey: String

    enum APIError: LocalizedError {
        case http(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .http(401, _), .http(403, _):
                return "Moxie rejected the API key (check Settings)."
            case let .http(code, body):
                let detail = body.trimmingCharacters(in: .whitespacesAndNewlines)
                return detail.isEmpty ? "Moxie returned HTTP \(code)." : "Moxie returned HTTP \(code): \(detail.prefix(240))"
            case .invalidResponse:
                return "Unexpected response from Moxie."
            }
        }
    }

    // MARK: Endpoints

    func clients() async throws -> [MoxieClient] {
        try await get("public/action/clients/list")
    }

    /// `query` must be the exact client name.
    func projects(clientName: String) async throws -> [MoxieProject] {
        try await get("public/action/projects/search", query: [URLQueryItem(name: "query", value: clientName)])
    }

    func tasks(projectId: String) async throws -> [MoxieTask] {
        try await get("public/action/tasks/list", query: [
            URLQueryItem(name: "projectId", value: projectId),
            URLQueryItem(name: "archived", value: "false"),
        ])
    }

    func tickets(clientId: String) async throws -> [MoxieTicket] {
        try await get("public/action/tickets/list", query: [
            URLQueryItem(name: "clientId", value: clientId),
            URLQueryItem(name: "open", value: "true"),
            URLQueryItem(name: "archived", value: "false"),
        ])
    }

    /// Every task in the workspace (optionally limited to one client); the caller filters to open ones.
    func allTasks(clientId: String? = nil) async throws -> [MoxieTask] {
        var query = [URLQueryItem(name: "archived", value: "false")]
        if let clientId { query.append(URLQueryItem(name: "clientId", value: clientId)) }
        return try await get("public/action/tasks/list", query: query)
    }

    func createTask(_ task: TaskCreateRequest) async throws -> MoxieTask? {
        let data = try await send("public/action/tasks/create", method: "POST", body: try JSONEncoder().encode(task))
        return try? JSONDecoder().decode(MoxieTask.self, from: data)
    }

    /// `PATCH tasks/update` merges any subset of task fields into the task with `id`.
    func updateTask(id: String, fields: [String: String]) async throws -> MoxieTask? {
        var body = fields
        body["id"] = id
        let data = try await send("public/action/tasks/update", method: "PATCH", body: try JSONEncoder().encode(body))
        return try? JSONDecoder().decode(MoxieTask.self, from: data)
    }

    func taskStages(projectTypeId: String?) async throws -> [MoxieTaskStage] {
        let query = projectTypeId.map { [URLQueryItem(name: "projectTypeId", value: $0)] } ?? []
        return try await get("public/action/taskStages/list", query: query)
    }

    func users() async throws -> [MoxieUser] {
        try await get("public/action/users/list")
    }

    @discardableResult
    func createTimeEntry(_ entry: TimeEntryRequest) async throws -> TimerEvent? {
        let body = try JSONEncoder().encode(entry)
        let data = try await send("public/action/timeWorked/create", method: "POST", body: body)
        return try? JSONDecoder().decode(TimerEvent.self, from: data)
    }

    // MARK: Transport

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let data = try await send(path, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil) async throws -> Data {
        guard var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw APIError.invalidResponse }

        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue(apiKey, forHTTPHeaderField: "X-API-KEY")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        return data
    }
}

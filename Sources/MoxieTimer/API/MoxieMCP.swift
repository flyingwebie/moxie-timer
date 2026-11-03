import Foundation

/// A Moxie time entry or running timer, as the MCP tools return it.
struct MoxieTimeEntry: Decodable, Equatable {
    let id: String?
    let timerStart: String?
    let timerEnd: String?
    let pausedAt: String?
    let durationSeconds: Double?
    let pausedSeconds: Double?
    let notes: String?
    let billable: Bool?
    let clientId: String?
    let projectId: String?
    let taskId: String?
    let ticketId: String?
    let clientName: String?
    let projectName: String?
    let taskName: String?
    let ticketName: String?

    var start: Date? { timerStart.flatMap(MoxieMCP.parseDate) }
    var isPaused: Bool { pausedAt != nil }

    /// The same links as an entry draft (only those that come with a name).
    var draft: EntryDraft {
        func ref(_ id: String?, _ name: String?) -> Ref? {
            guard let id, !id.isEmpty, let name, !name.isEmpty else { return nil }
            return Ref(id: id, name: name)
        }
        return EntryDraft(client: ref(clientId, clientName), project: ref(projectId, projectName), task: ref(taskId, taskName),
                          ticket: ref(ticketId, ticketName), notes: notes ?? "", billable: billable ?? true)
    }
}

/// Minimal MCP client for Moxie's server: JSON-RPC 2.0 over Streamable HTTP, OAuth bearer from `MCPAuth`.
@MainActor
final class MoxieMCP {
    enum MCPError: LocalizedError {
        case http(Int, String)
        case rpc(String)
        case tool(String)
        case unreadable

        var errorDescription: String? {
            switch self {
            case let .http(code, body): return "Moxie MCP returned HTTP \(code)\(body.isEmpty ? "" : ": \(body.prefix(200))")"
            case let .rpc(message): return "Moxie MCP: \(message)"
            case let .tool(message): return message
            case .unreadable: return "Moxie MCP sent a reply the app couldn't read."
            }
        }
    }

    private let auth: MCPAuth
    private var sessionId: String?
    private var negotiatedVersion = "2025-06-18"
    private var nextId = 1

    init(auth: MCPAuth) { self.auth = auth }

    // MARK: Timer & time entries

    /// The running (or paused) timer in Moxie, if any.
    func timerGet() async throws -> MoxieTimeEntry? {
        let result = try await callTool("timer_get")
        if (result["running"] as? Bool) == false { return nil }
        return Self.findEntry(in: result)
    }

    /// Starts Moxie's timer. If one is already running, Moxie returns it unchanged.
    func timerStart(_ draft: EntryDraft) async throws -> MoxieTimeEntry? {
        var args: [String: Any] = ["billable": draft.isBillable]
        if let id = draft.client?.id { args["clientId"] = id }
        // Moxie links an entry to a project or a ticket, not both.
        if let id = draft.ticket?.id {
            args["ticketId"] = id
        } else {
            if let id = draft.project?.id { args["projectId"] = id }
            if let id = draft.task?.id { args["taskId"] = id }
        }
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { args["notes"] = notes }
        return Self.findEntry(in: try await callTool("timer_start", args))
    }

    func timerPause() async throws { _ = try await callTool("timer_pause") }
    func timerResume() async throws { _ = try await callTool("timer_resume") }
    func timerDiscard() async throws { _ = try await callTool("timer_discard") }

    /// Stops Moxie's timer; it saves it as an entry and returns that entry.
    func timerStop() async throws -> MoxieTimeEntry? {
        Self.findEntry(in: try await callTool("timer_stop"))
    }

    /// Sets an entry's exact times and links (Moxie can't edit a running timer, so this runs after stop).
    func updateEntry(id: String, start: Date, end: Date, draft: EntryDraft) async throws -> MoxieTimeEntry? {
        var args: [String: Any] = [
            "timeEntryId": id,
            "timerStart": start.formatted(.iso8601),
            "timerEnd": end.formatted(.iso8601),
            "billable": draft.isBillable,
        ]
        var clear: [String] = []
        func set(_ key: String, _ ref: Ref?) {
            if let ref { args[key] = ref.id } else { clear.append(key) }
        }
        set("clientId", draft.client)
        if draft.ticket != nil {
            set("ticketId", draft.ticket)
            clear += ["projectId", "taskId"]
        } else {
            set("projectId", draft.project)
            set("taskId", draft.task)
            clear.append("ticketId")
        }
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.isEmpty { clear.append("notes") } else { args["notes"] = notes }
        args["clearFields"] = clear
        return Self.findEntry(in: try await callTool("time_entries_update", args))
    }

    // MARK: Tools

    /// Calls a tool and returns its structured result. Tool-level failures throw with Moxie's message.
    func callTool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        if sessionId == nil { try await initialize() }
        let result: [String: Any]
        do {
            result = try await rpc("tools/call", ["name": name, "arguments": arguments])
        } catch MCPError.http(404, _) {
            // The server forgot our session: start a new one and retry once.
            sessionId = nil
            try await initialize()
            result = try await rpc("tools/call", ["name": name, "arguments": arguments])
        }
        let text = (result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined(separator: "\n") ?? ""
        if result["isError"] as? Bool == true {
            throw MCPError.tool(text.isEmpty ? "Moxie couldn't run \(name)." : text)
        }
        if let structured = result["structuredContent"] as? [String: Any] { return structured }
        // Older servers put the JSON after a sentence in the text part.
        if let brace = text.firstIndex(of: "{"),
           let object = try? JSONSerialization.jsonObject(with: Data(text[brace...].utf8)) as? [String: Any] {
            return object
        }
        return [:]
    }

    private func initialize() async throws {
        let result = try await rpc("initialize", [
            "protocolVersion": negotiatedVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "Moxie Timer", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"],
        ])
        if let version = result["protocolVersion"] as? String { negotiatedVersion = version }
        try await notify("notifications/initialized")
    }

    // MARK: Transport

    private func rpc(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        let id = nextId
        nextId += 1
        let body: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let (data, response) = try await post(body)
        let message = try Self.message(withId: id, in: data, contentType: response.value(forHTTPHeaderField: "Content-Type") ?? "")
        if let error = message["error"] as? [String: Any] {
            throw MCPError.rpc(error["message"] as? String ?? "request failed")
        }
        return message["result"] as? [String: Any] ?? [:]
    }

    private func notify(_ method: String) async throws {
        _ = try await post(["jsonrpc": "2.0", "method": method])
    }

    private func post(_ body: [String: Any], retried: Bool = false) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: MCPAuth.resource, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(try await auth.accessToken(forceRefresh: retried))", forHTTPHeaderField: "Authorization")
        if let sessionId { request.setValue(sessionId, forHTTPHeaderField: "Mcp-Session-Id") }
        if (body["method"] as? String) != "initialize" { request.setValue(negotiatedVersion, forHTTPHeaderField: "MCP-Protocol-Version") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MCPError.unreadable }
        if http.statusCode == 401, !retried { return try await post(body, retried: true) }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(http.statusCode, String(decoding: data, as: UTF8.self))
        }
        if let id = http.value(forHTTPHeaderField: "Mcp-Session-Id") { sessionId = id }
        return (data, http)
    }

    /// Finds the JSON-RPC reply with `id` in a plain JSON body or an SSE stream.
    static func message(withId id: Int, in data: Data, contentType: String) throws -> [String: Any] {
        func matches(_ object: [String: Any]) -> Bool { (object["id"] as? Int) == id || (object["id"] as? String) == String(id) }
        if contentType.contains("text/event-stream") {
            var buffer = ""
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
                if line.hasPrefix("data:") {
                    buffer += line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                } else if line.trimmingCharacters(in: .whitespaces).isEmpty, !buffer.isEmpty {
                    if let object = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)) as? [String: Any], matches(object) {
                        return object
                    }
                    buffer = ""
                }
            }
            if let object = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)) as? [String: Any], matches(object) {
                return object
            }
            throw MCPError.unreadable
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MCPError.unreadable }
        return object
    }

    // MARK: Parsing

    /// The first object shaped like a time entry (has `timerStart`), at the top or nested one level down
    /// under keys like `timer` / `timeEntry`.
    static func findEntry(in object: [String: Any]) -> MoxieTimeEntry? {
        func decode(_ dict: [String: Any]) -> MoxieTimeEntry? {
            guard dict["timerStart"] != nil, let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(MoxieTimeEntry.self, from: data)
        }
        if let entry = decode(object) { return entry }
        for value in object.values {
            if let dict = value as? [String: Any], let entry = findEntry(in: dict) { return entry }
        }
        return nil
    }

    nonisolated static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

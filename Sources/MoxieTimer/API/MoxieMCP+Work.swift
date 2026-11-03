import Foundation

/// Extra Moxie MCP tools for ticket/task work: turning a ticket into a task, Moxie's own urgency
/// signals, task checklists, and private ticket comments. Kept separate from `MoxieMCP.swift` (owned
/// elsewhere) so this file can be edited freely; every call goes through the shared `callTool`.
extension MoxieMCP {
    /// Creates a project task from a ticket; Moxie keeps their comments linked both ways. Only call this
    /// after the user explicitly asked for it (the button tap is the confirmation Moxie's tool wants).
    func createTask(fromTicket ticketId: String, projectId: String) async throws {
        _ = try await callTool("tickets_create_task", ["ticketId": ticketId, "projectId": projectId, "confirmCreate": true])
    }

    /// Adds a short, internal-only ticket comment. Never sends a public/client-visible reply.
    func postPrivateTicketComment(ticketId: String, comment: String) async throws {
        _ = try await callTool("ticket_comments_create", ["ticketId": ticketId, "comment": comment, "type": "PRIVATE"])
    }

    // MARK: Checklists

    struct ChecklistItem {
        var itemId: String?
        var text: String
        var completed: Bool
    }

    /// The task's existing checklist, read first so a new item can be appended rather than overwriting it.
    func checklist(taskId: String) async throws -> [ChecklistItem] {
        let result = try await callTool("task_checklist_list", ["taskId": taskId])
        let raw = (result["items"] as? [[String: Any]]) ?? (result["checklist"] as? [[String: Any]]) ?? []
        return raw.compactMap { dict in
            guard let text = (dict["text"] as? String) ?? (dict["title"] as? String) ?? (dict["name"] as? String) else { return nil }
            let id = (dict["itemId"] as? String) ?? (dict["id"] as? String)
            let completed = (dict["completed"] as? Bool) ?? (dict["done"] as? Bool) ?? false
            return ChecklistItem(itemId: id, text: text, completed: completed)
        }
    }

    /// Appends one item to the task's Moxie checklist, keeping every existing item (and its completion state).
    func appendChecklistItem(taskId: String, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let existing = try await checklist(taskId: taskId)
        var items: [[String: Any]] = existing.map { item in
            var dict: [String: Any] = ["text": item.text, "completed": item.completed]
            if let id = item.itemId { dict["itemId"] = id }
            return dict
        }
        items.append(["text": trimmed, "completed": false])
        _ = try await callTool("task_checklist_set", ["taskId": taskId, "items": items, "confirmReplace": true])
    }

    // MARK: Urgency signals

    /// One thing Moxie itself flagged as urgent, with a short reason for the UI.
    struct UrgencySignal {
        var id: String
        var reason: String
    }

    /// Moxie's own "what needs doing" view, blended into the inbox's local ranking as a tie-breaker.
    /// Best-effort: the exact reply shape isn't documented, so a changed shape just yields no signals
    /// rather than an error — the inbox falls back to its own ranking either way.
    func urgencySignals() async throws -> [UrgencySignal] {
        async let focus = try callTool("dashboard_daily_focus")
        async let attention = try callTool("dashboard_needs_attention")
        let (focusResult, attentionResult) = try await (focus, attention)
        return Self.extractSignals(focusResult, defaultReason: "Moxie: today's focus")
            + Self.extractSignals(attentionResult, defaultReason: "Moxie: needs attention")
    }

    /// Walks a JSON-ish reply for anything shaped like a task/ticket reference and turns it into a signal.
    private static func extractSignals(_ object: [String: Any], defaultReason: String) -> [UrgencySignal] {
        var results: [UrgencySignal] = []
        func walk(_ value: Any) {
            if let dict = value as? [String: Any] {
                let id = (dict["taskId"] as? String) ?? (dict["ticketId"] as? String) ?? (dict["entityId"] as? String)
                if let id, !id.isEmpty {
                    let reason = (dict["reason"] as? String) ?? (dict["category"] as? String) ?? (dict["lane"] as? String) ?? defaultReason
                    results.append(UrgencySignal(id: id, reason: reason))
                }
                for nested in dict.values { walk(nested) }
            } else if let array = value as? [Any] {
                for item in array { walk(item) }
            }
        }
        walk(object)
        return results
    }
}

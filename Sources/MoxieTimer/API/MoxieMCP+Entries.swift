import Foundation

/// A time entry as `time_entries_list` / `time_entries_get` return it. Separate from `MoxieTimeEntry`
/// (which mirrors the live timer) because this one also carries invoice state, used to tell "unbilled"
/// from merely "billable", and an `id` that's always present (needed to reconcile against local history).
///
/// Moxie's exact MCP reply shape for these two tools isn't documented, so every field below is optional
/// except `id`, and decoding is tolerant: an entry missing a field we don't recognise is still usable.
struct MoxieRemoteEntry: Decodable, Identifiable, Hashable {
    let id: String
    let timerStart: String?
    let timerEnd: String?
    let durationSeconds: Double?
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
    /// Invoice linkage, whichever shape Moxie actually sends (field names are a best guess).
    let invoiceId: String?
    let invoiced: Bool?

    var start: Date? { timerStart.flatMap(MoxieMCP.parseDate) }
    var end: Date? { timerEnd.flatMap(MoxieMCP.parseDate) }

    var duration: TimeInterval {
        if let durationSeconds { return durationSeconds }
        if let start, let end { return end.timeIntervalSince(start) }
        return 0
    }

    var isBillable: Bool { billable ?? true }
    /// Best-effort: true once we recognise an invoice link; false (not "unbilled confirmed") otherwise.
    var isInvoiced: Bool { invoiced == true || (invoiceId?.isEmpty == false) }

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

/// Entry list/edit/delete calls, split out from the live-timer mirror in `MoxieMCP.swift`: Recent/Review
/// editing real Moxie entries, and Insights' unbilled-hours reconciliation.
extension MoxieMCP {
    /// Entries in `[earliest, latest)`, paged until a short page signals the end. Used to reconcile
    /// Recent/Review against what's actually in Moxie, and to total unbilled hours for Insights.
    func listEntries(earliest: Date, latest: Date) async throws -> [MoxieRemoteEntry] {
        let pageSize = 100
        var all: [MoxieRemoteEntry] = []
        var cursor = 0
        while true {
            let args: [String: Any] = [
                "earliest": earliest.formatted(.iso8601),
                "latest": latest.formatted(.iso8601),
                "limit": pageSize,
                "cursor": cursor,
            ]
            let page = Self.decodeEntries(from: try await callTool("time_entries_list", args))
            all += page
            guard page.count == pageSize else { break }
            cursor += page.count
            if all.count > 2000 { break }  // guard against an unexpected non-terminating cursor
        }
        return all
    }

    /// Edits a sent entry directly (Recent tab): any of times, links, billable, or notes. Fields left `nil`
    /// are untouched; a `draft` with no client/project/task/ticket clears those links. Throws with Moxie's
    /// message when the entry is already invoiced (it can't be changed).
    @discardableResult
    func editEntry(id: String, start: Date? = nil, end: Date? = nil, draft: EntryDraft? = nil, billable: Bool? = nil) async throws -> MoxieRemoteEntry? {
        var args: [String: Any] = ["timeEntryId": id]
        if let start { args["timerStart"] = start.formatted(.iso8601) }
        if let end { args["timerEnd"] = end.formatted(.iso8601) }
        if let billable { args["billable"] = billable }
        var clear: [String] = []
        if let draft {
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
        }
        if !clear.isEmpty { args["clearFields"] = clear }
        return Self.decodeEntry(from: try await callTool("time_entries_update", args))
    }

    /// Permanently deletes an entry in Moxie. Invoiced entries throw with Moxie's message; callers should
    /// confirm with the user first since this can't be undone.
    func deleteEntry(id: String) async throws {
        _ = try await callTool("time_entries_delete", ["timeEntryId": id, "confirmDelete": true])
    }

    // MARK: Parsing (defensive: the exact response shape isn't documented)

    private static func decodeEntry(from dict: [String: Any]) -> MoxieRemoteEntry? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(MoxieRemoteEntry.self, from: data)
    }

    /// Finds the array of entries in a `time_entries_list` reply: tries common container keys first, then
    /// falls back to any array of dicts that look like entries (every element has an `id`).
    private static func decodeEntries(from object: [String: Any]) -> [MoxieRemoteEntry] {
        func asEntryDicts(_ array: [Any]) -> [[String: Any]]? {
            let dicts = array.compactMap { $0 as? [String: Any] }
            guard dicts.count == array.count, !dicts.isEmpty, dicts.allSatisfy({ $0["id"] != nil }) else { return nil }
            return dicts
        }
        for key in ["items", "entries", "timeEntries", "data", "results"] {
            if let array = object[key] as? [Any], let dicts = asEntryDicts(array) {
                return dicts.compactMap(decodeEntry)
            }
        }
        for value in object.values {
            if let array = value as? [Any], let dicts = asEntryDicts(array) {
                return dicts.compactMap(decodeEntry)
            }
        }
        return []
    }
}

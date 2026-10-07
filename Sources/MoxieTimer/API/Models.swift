import Foundation

// MARK: - Moxie API payloads (only the fields the widget uses)

struct MoxieClient: Codable, Identifiable, Hashable {
    let id: String
    let name: String
}

struct MoxieProject: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let active: Bool?
    let clientId: String?
    let hexColor: String?

    var isActive: Bool { active ?? true }
}

struct MoxieTask: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let projectId: String?
    let status: String?
    let parentTaskId: String?
}

struct MoxieTicket: Codable, Identifiable, Hashable {
    let id: String
    let ticketNumber: Int?
    let subject: String?
    let open: Bool?
    let status: String?

    var title: String {
        let subject = (subject?.isEmpty == false) ? subject! : "Untitled ticket"
        if let ticketNumber { return "#\(ticketNumber) \(subject)" }
        return subject
    }
}

struct MoxieUser: Decodable, Hashable {
    struct Profile: Decodable, Hashable {
        let userId: Int?
        let firstName: String?
        let lastName: String?
        let email: String?
    }

    let userType: String?
    let user: Profile

    var displayName: String {
        let name = [user.firstName, user.lastName].compactMap { $0 }.joined(separator: " ")
        return name.isEmpty ? (user.email ?? "Unknown") : name
    }
}

struct TimeEntryRequest: Encodable {
    let timerStart: String
    let timerEnd: String
    let clientName: String
    let projectName: String
    let deliverableName: String?
    let notes: String?
    let userEmail: String
    /// Not in the documented request schema; Moxie's TimerEvent has a `billable` field, so we send it and
    /// check the response to see whether it was applied.
    let billable: Bool?
}

struct TimerEvent: Decodable {
    let id: String?
    let billable: Bool?
}

// MARK: - Local models

/// A lightweight reference to a Moxie record, persisted with drafts and history.
struct Ref: Codable, Hashable {
    var id: String
    var name: String
}

/// What the time is being logged against.
struct EntryDraft: Codable, Hashable {
    var client: Ref?
    var project: Ref?
    var task: Ref?
    var ticket: Ref?
    var notes: String = ""
    /// Optional so drafts saved by older versions still decode; `nil` means billable.
    var billable: Bool? = true

    var isBillable: Bool {
        get { billable ?? true }
        set { billable = newValue }
    }

    mutating func setClient(_ newValue: Ref?) {
        guard newValue != client else { return }
        client = newValue
        project = nil
        task = nil
        ticket = nil
    }

    mutating func setProject(_ newValue: Ref?) {
        guard newValue != project else { return }
        project = newValue
        task = nil
    }

    /// The Moxie create endpoint has no ticket field, so the ticket is folded into the notes.
    var composedNotes: String? {
        var parts: [String] = []
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        if let ticket { parts.append("Ticket \(ticket.name)") }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Same client/project/task, fresh notes — used when starting again from a past entry.
    var reusable: EntryDraft {
        EntryDraft(client: client, project: project, task: task, ticket: ticket, notes: "", billable: billable)
    }
}

/// An entry this widget successfully pushed to Moxie.
struct LoggedEntry: Codable, Identifiable, Hashable {
    var id: String
    var moxieId: String?
    var start: Date
    var end: Date
    var draft: EntryDraft
    /// What Moxie reported back for `billable`, when it reported anything.
    var moxieBillable: Bool?

    var duration: TimeInterval { end.timeIntervalSince(start) }
    /// Billable state as Moxie stored it, falling back to what was requested.
    var isBillable: Bool { moxieBillable ?? draft.isBillable }
}

/// A running or paused timer. Elapsed time excludes pauses; the reported start time is
/// derived as `end - elapsed`, so editing the duration moves the start ("start follows along").
struct TimerSession: Codable, Equatable {
    var accumulated: TimeInterval = 0
    var runningSince: Date?
    var pausedAt: Date?

    var isRunning: Bool { runningSince != nil }

    func end(at now: Date) -> Date {
        runningSince != nil ? now : (pausedAt ?? now)
    }

    func elapsed(at now: Date) -> TimeInterval {
        accumulated + (runningSince.map { now.timeIntervalSince($0) } ?? 0)
    }

    func start(at now: Date) -> Date {
        end(at: now).addingTimeInterval(-elapsed(at: now))
    }

    mutating func pause(at now: Date) {
        guard let runningSince else { return }
        accumulated += now.timeIntervalSince(runningSince)
        self.runningSince = nil
        pausedAt = now
    }

    mutating func resume(at now: Date) {
        guard runningSince == nil else { return }
        runningSince = now
        pausedAt = nil
    }

    mutating func setElapsed(_ value: TimeInterval, at now: Date) {
        accumulated = max(0, value)
        if isRunning { runningSince = now }
    }
}

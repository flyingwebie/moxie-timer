import SwiftUI

/// "Make a task from this ticket" — Moxie's `tickets_create_task` needs a destination project, which
/// a ticket doesn't have on its own, so this asks for one before calling it. Shown from the ticket's
/// context menu, only when MCP is active.
struct MakeTaskFromTicketSheet: View {
    let ticket: MoxieTask
    @Environment(\.dismiss) private var dismiss
    @Environment(TaskInbox.self) private var inbox
    @Environment(Catalog.self) private var catalog
    @Environment(MoxieLiveTimer.self) private var live
    @Environment(FocusStore.self) private var focus

    @State private var project: Ref?
    @State private var isCreating = false
    @State private var error: String?

    private var clientRef: Ref? { ticket.clientRef }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Make a task from this ticket").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.ink)
            Text(ticket.name)
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    CapsLabel("Project")
                    Text("· required by Moxie").font(.system(size: 10)).foregroundStyle(Theme.faint)
                }
                SearchPicker(
                    icon: "folder", placeholder: clientRef == nil ? "No client on this ticket" : "Pick a project",
                    selection: project?.name,
                    items: clientRef.flatMap { catalog.projectsByClient[$0.id] } ?? [], title: \.name,
                    badge: { $0.isActive ? nil : "Completed" },
                    isLoading: clientRef.map { catalog.isLoading("projects:\($0.id)") } ?? false,
                    disabled: clientRef == nil,
                    onOpen: { if let clientRef { await catalog.loadProjects(for: clientRef) } },
                    onRefresh: { if let clientRef { await catalog.loadProjects(for: clientRef, force: true) } },
                    onSelect: { picked in project = picked.map { Ref(id: $0.id, name: $0.name) } }
                )
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
            }

            if let error {
                ErrorBanner(message: error) { self.error = nil }
            }

            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(ChipButtonStyle())
                Spacer()
                Button {
                    create()
                } label: {
                    HStack(spacing: 6) {
                        if isCreating { ProgressView().controlSize(.small).tint(.white) }
                        Text("Create task")
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(project == nil || isCreating)
            }
        }
        .padding(16)
        .frame(width: 320)
        .task { if let clientRef { await catalog.loadProjects(for: clientRef) } }
    }

    private func create() {
        guard let project, let ticketId = ticket.sourceTicketId else { return }
        isCreating = true
        error = nil
        Task {
            defer { isCreating = false }
            do {
                try await live.mcp.createTask(fromTicket: ticketId, projectId: project.id)
                await inbox.refresh(mcp: live.isActive ? live.mcp : nil)
                focus.banner = "Created a task in Moxie from “\(ticket.name)”."
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

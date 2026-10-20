import SwiftUI

/// Due-date shortcuts shared by the composer and the capture screen.
enum DueChoice: Int, CaseIterable, Identifiable {
    case none, today, tomorrow, nextWeek

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "No date"
        case .today: return "Today"
        case .tomorrow: return "Tomorrow"
        case .nextWeek: return "Next week"
        }
    }

    var date: Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        switch self {
        case .none: return nil
        case .today: return today
        case .tomorrow: return calendar.date(byAdding: .day, value: 1, to: today)
        case .nextWeek: return calendar.date(byAdding: .day, value: 7, to: today)
        }
    }
}

/// The Focus home's main action: name the work, link it to a client/project on the fly, and start.
/// Enter = add to Moxie and focus now. "Later" adds it to Up next. "Just focus" skips Moxie entirely.
struct QuickStartComposer: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(FocusStore.self) private var focus
    @Environment(Catalog.self) private var catalog
    @Environment(TimerStore.self) private var timer

    @State private var name = ""
    @State private var client: Ref?
    @State private var project: Ref?
    @State private var due: DueChoice = .none
    @State private var saving: Kind?
    @State private var error: String?
    @State private var added: String?
    @FocusState private var fieldFocused: Bool

    private enum Kind { case focus, later, freeform }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmed.isEmpty && saving == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(fieldFocused ? .white : Theme.navy)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(fieldFocused ? Theme.navy : Theme.navy.opacity(0.08)))
                TextField("What are you working on?", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .medium))
                    .focused($fieldFocused)
                    .onSubmit { save(.focus) }
            }
            .padding(.horizontal, 12)
            .frame(height: 48)

            HStack(spacing: 6) {
                SearchChip(
                    icon: "person.2.fill", placeholder: "Client",
                    selection: client?.name, items: catalog.clients, title: \.name,
                    isLoading: catalog.isLoading("clients"), maxWidth: 150,
                    onOpen: { await catalog.loadClients() },
                    onRefresh: { await catalog.loadClients(force: true) },
                    onSelect: { picked in
                        let ref = picked.map { Ref(id: $0.id, name: $0.name) }
                        if ref?.id != client?.id { project = nil }
                        client = ref
                        if let ref { Task { await catalog.loadProjects(for: ref) } }
                    }
                )
                SearchChip(
                    icon: "folder.fill", placeholder: "Project",
                    selection: project?.name,
                    items: client.flatMap { catalog.projectsByClient[$0.id] } ?? [], title: \.name,
                    badge: { $0.isActive ? nil : "Completed" },
                    isLoading: client.map { catalog.isLoading("projects:\($0.id)") } ?? false,
                    disabled: client == nil, maxWidth: 150,
                    onOpen: { if let client { await catalog.loadProjects(for: client) } },
                    onRefresh: { if let client { await catalog.loadProjects(for: client, force: true) } },
                    onSelect: { picked in project = picked.map { Ref(id: $0.id, name: $0.name) } }
                )
                .help(client == nil ? "Pick a client first" : "Project")
                dueMenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            if let error {
                ErrorBanner(message: error) { self.error = nil }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                if let added {
                    Label(added, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.running)
                        .lineLimit(1)
                        .transition(.opacity)
                } else {
                    Button { save(.freeform) } label: {
                        Text("Just focus")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(canSave ? Theme.muted : Theme.faint)
                            .underline(true, color: Theme.border)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSave)
                    .help("Start focusing without creating a task in Moxie")
                }
                Spacer(minLength: 4)
                Button { save(.later) } label: {
                    HStack(spacing: 5) {
                        if saving == .later { ProgressView().controlSize(.mini) }
                        Text("Add for later")
                    }
                }
                .buttonStyle(ChipButtonStyle())
                .disabled(!canSave)
                .help("Add to Moxie and keep it in Up next")
                Button { save(.focus) } label: {
                    HStack(spacing: 6) {
                        if saving == .focus { ProgressView().controlSize(.mini).tint(.white) } else {
                            Image(systemName: "play.fill").font(.system(size: 9, weight: .bold))
                        }
                        Text("Add & focus")
                        Text("↩").font(.system(size: 11, weight: .bold)).opacity(0.55)
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Theme.navy.opacity(canSave ? 1 : 0.4)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!canSave)
                .help("Add to Moxie and start focusing on it (Enter)")
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Theme.cream.opacity(0.7))
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.white))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(fieldFocused ? Theme.navy.opacity(0.45) : Theme.border, lineWidth: fieldFocused ? 1.5 : 1)
        )
        .shadow(color: Theme.navy.opacity(fieldFocused ? 0.12 : 0.05), radius: fieldFocused ? 10 : 4, y: 2)
        .animation(.easeOut(duration: 0.15), value: fieldFocused)
        .onAppear { adoptFilter() }
        .onChange(of: inbox.filterClient) { adoptFilter() }
        .onChange(of: inbox.filterProject) { adoptFilter() }
    }

    private var dueMenu: some View {
        Menu {
            ForEach(DueChoice.allCases) { choice in
                Button(choice.title) { due = choice }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "calendar").font(.system(size: 10, weight: .semibold))
                Text(due == .none ? "Due" : due.title)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .heavy)).opacity(0.6)
            }
            .font(.system(size: 11.5, weight: due == .none ? .medium : .semibold))
            .foregroundStyle(due == .none ? Theme.ink.opacity(0.6) : Theme.navy)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(Capsule().fill(due == .none ? Theme.cream : Theme.navy.opacity(0.09)))
            .overlay(Capsule().strokeBorder(due == .none ? Theme.border : Theme.navy.opacity(0.3)))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    /// New tasks land where you're looking: the composer follows the Up next filter.
    private func adoptFilter() {
        guard saving == nil else { return }
        if let filter = inbox.filterClient {
            client = filter
            project = inbox.filterProject
            Task { await catalog.loadProjects(for: filter) }
        } else if inbox.filterProject == nil, client != nil, trimmed.isEmpty {
            client = nil
            project = nil
        }
    }

    private func save(_ kind: Kind) {
        let text = trimmed
        guard !text.isEmpty, saving == nil else { return }
        error = nil
        if kind == .freeform {
            let link = (client, project)
            name = ""
            Task {
                await focus.select(freeform: text)
                if let client = link.0 {
                    timer.draft.setClient(client)
                    if let project = link.1 { timer.draft.setProject(project) }
                }
            }
            return
        }
        saving = kind
        Task {
            defer { saving = nil }
            do {
                let task = try await inbox.create(name: text, client: client, project: project, due: due.date)
                name = ""
                due = .none
                if kind == .focus {
                    await focus.select(task)
                } else {
                    withAnimation { added = inbox.matchesFilter(task) ? "Added to Up next" : "Added — outside this filter" }
                    fieldFocused = true
                    try? await Task.sleep(for: .seconds(3))
                    withAnimation { added = nil }
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

import SwiftUI

/// All open Moxie tasks, grouped by when they're due.
struct TaskListView: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(FocusStore.self) private var focus
    @Environment(WidgetUI.self) private var ui

    @State private var query = ""

    var body: some View {
        @Bindable var inbox = inbox

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { ui.route = nil } label: {
                    Label("Tasks", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
                if inbox.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await inbox.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .help("Reload from Moxie")
                }
                Button { ui.route = .capture } label: { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.navy)
                    .help("New task")
            }

            FieldBox {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                    TextField("Search tasks", text: $query).textFieldStyle(.plain)
                }
            }

            Toggle("Only tasks assigned to me", isOn: $inbox.onlyMine)
                .toggleStyle(.switch)
                .tint(Theme.navy)
                .controlSize(.mini)
                .font(.system(size: 12))

            if let error = inbox.lastError {
                ErrorBanner(message: error) { inbox.lastError = nil }
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups, id: \.title) { group in
                        Section {
                            ForEach(group.tasks) { task in
                                TaskRow(task: task) {
                                    Task {
                                        await focus.select(task)
                                        ui.tab = .focus
                                        ui.route = nil
                                    }
                                }
                            }
                        } header: {
                            HStack {
                                CapsLabel(group.title)
                                Spacer()
                                Text("\(group.tasks.count)").font(.system(size: 11)).foregroundStyle(Theme.faint)
                            }
                            .padding(.vertical, 6)
                            .background(.white)
                        }
                    }
                    if groups.isEmpty && !inbox.isLoading {
                        Text(query.isEmpty ? "No open tasks in Moxie." : "No tasks match “\(query)”.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(.vertical, 30)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(height: 400)
        }
        .padding(16)
        .task { await inbox.refreshIfStale() }
    }

    private struct Group {
        let title: String
        let tasks: [MoxieTask]
    }

    private var groups: [Group] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let tasks = inbox.visibleTasks.filter { task in
            q.isEmpty || task.name.localizedCaseInsensitiveContains(q)
                || (task.client?.name ?? "").localizedCaseInsensitiveContains(q)
                || (task.project?.name ?? "").localizedCaseInsensitiveContains(q)
        }
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        func bucket(_ task: MoxieTask) -> Int {
            guard let due = task.due else { return 4 }
            let days = calendar.dateComponents([.day], from: today, to: due).day ?? 0
            switch days {
            case ..<0: return 0
            case 0: return 1
            case 1...7: return 2
            default: return 3
            }
        }
        let titles = ["Overdue", "Today", "This week", "Later", "No due date"]
        let grouped = Dictionary(grouping: tasks, by: bucket)
        return (0..<titles.count).compactMap { index in
            guard let items = grouped[index], !items.isEmpty else { return nil }
            return Group(title: titles[index], tasks: items)
        }
    }
}

/// Quick capture (also opened with the global hotkey): get the thought out of your head and into Moxie.
struct CaptureView: View {
    @Environment(TaskInbox.self) private var inbox
    @Environment(FocusStore.self) private var focus
    @Environment(TimerStore.self) private var timer
    @Environment(Catalog.self) private var catalog
    @Environment(WidgetUI.self) private var ui

    @State private var name = ""
    @State private var draft = EntryDraft()
    @State private var dueChoice = 0
    @State private var isSaving = false
    @State private var error: String?
    @State private var didPrefill = false
    @FocusState private var nameFocused: Bool

    private let dueOptions = ["No date", "Today", "Tomorrow", "Next week"]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button { ui.route = nil } label: {
                    Label("Capture a task", systemImage: "chevron.left")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                WindowDragArea().frame(maxWidth: .infinity, minHeight: 24)
                Text(HotKey.captureDescription)
                    .font(.system(size: 10, weight: .semibold).monospaced())
                    .foregroundStyle(Theme.faint)
            }

            FieldBox {
                TextField("What needs doing?", text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($nameFocused)
                    .onSubmit { save(focusNow: false) }
            }

            VStack(alignment: .leading, spacing: 0) {
                SearchPicker(
                    icon: "person.2", placeholder: "No client",
                    selection: draft.client?.name, items: catalog.clients, title: \.name,
                    isLoading: catalog.isLoading("clients"),
                    onOpen: { await catalog.loadClients() },
                    onRefresh: { await catalog.loadClients(force: true) },
                    onSelect: { client in draft.setClient(client.map { Ref(id: $0.id, name: $0.name) }) }
                )
                Divider()
                SearchPicker(
                    icon: "folder", placeholder: "No project",
                    selection: draft.project?.name,
                    items: draft.client.flatMap { catalog.projectsByClient[$0.id] } ?? [], title: \.name,
                    badge: { $0.isActive ? nil : "Completed" },
                    isLoading: draft.client.map { catalog.isLoading("projects:\($0.id)") } ?? false,
                    disabled: draft.client == nil,
                    onOpen: { if let c = draft.client { await catalog.loadProjects(for: c) } },
                    onRefresh: { if let c = draft.client { await catalog.loadProjects(for: c, force: true) } },
                    onSelect: { project in draft.setProject(project.map { Ref(id: $0.id, name: $0.name) }) }
                )
            }

            HStack(spacing: 6) {
                ForEach(dueOptions.indices, id: \.self) { index in
                    Button { dueChoice = index } label: {
                        Text(dueOptions[index])
                            .font(.system(size: 12, weight: dueChoice == index ? .bold : .medium))
                            .foregroundStyle(dueChoice == index ? .white : Theme.ink.opacity(0.8))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                            .background(Capsule().fill(dueChoice == index ? Theme.navy : .white))
                            .overlay(Capsule().strokeBorder(dueChoice == index ? .clear : Theme.border))
                    }
                    .buttonStyle(.plain)
                }
            }

            if let error {
                ErrorBanner(message: error) { self.error = nil }
            }

            HStack(spacing: 8) {
                Button { save(focusNow: true) } label: {
                    Text("Add & focus now").frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                Button { save(focusNow: false) } label: {
                    HStack(spacing: 6) {
                        if isSaving { ProgressView().controlSize(.small).tint(.white) }
                        Text("Add to Moxie")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .disabled(isSaving || name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
        .onAppear {
            nameFocused = true
            guard !didPrefill else { return }
            didPrefill = true
            draft = timer.draft.reusable
        }
    }

    private var dueDate: Date? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        switch dueChoice {
        case 1: return today
        case 2: return calendar.date(byAdding: .day, value: 1, to: today)
        case 3: return calendar.date(byAdding: .day, value: 7, to: today)
        default: return nil
        }
    }

    private func save(focusNow: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !isSaving else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                let task = try await inbox.create(name: trimmed, client: draft.client, project: draft.project, due: dueDate)
                name = ""
                if focusNow {
                    await focus.select(task)
                    ui.tab = .focus
                    ui.route = nil
                } else {
                    focus.banner = "Added “\(trimmed)” to Moxie."
                    ui.route = nil
                    ui.collapse()
                }
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

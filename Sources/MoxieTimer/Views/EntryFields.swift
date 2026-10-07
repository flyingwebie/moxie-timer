import SwiftUI

/// Client / project / task / ticket / notes rows, shared by the timer and manual entry screens.
struct EntryFields: View {
    @Binding var draft: EntryDraft
    var labelled = false
    @Environment(Catalog.self) private var catalog

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Client") {
                SearchPicker(
                    icon: "person.2", placeholder: "No client",
                    selection: draft.client?.name,
                    items: catalog.clients, title: \.name,
                    isLoading: catalog.isLoading("clients"),
                    onOpen: { await catalog.loadClients() },
                    onRefresh: { await catalog.loadClients(force: true) },
                    onSelect: { client in
                        draft.setClient(client.map { Ref(id: $0.id, name: $0.name) })
                        if let ref = draft.client { Task { await catalog.loadProjects(for: ref) } }
                    }
                )
            }
            row("Project") {
                SearchPicker(
                    icon: "folder", placeholder: "No project",
                    selection: draft.project?.name,
                    items: draft.client.flatMap { catalog.projectsByClient[$0.id] } ?? [],
                    title: \.name,
                    badge: { $0.isActive ? nil : "Completed" },
                    isLoading: draft.client.map { catalog.isLoading("projects:\($0.id)") } ?? false,
                    disabled: draft.client == nil,
                    onOpen: { if let c = draft.client { await catalog.loadProjects(for: c) } },
                    onRefresh: { if let c = draft.client { await catalog.loadProjects(for: c, force: true) } },
                    onSelect: { project in
                        draft.setProject(project.map { Ref(id: $0.id, name: $0.name) })
                        if let ref = draft.project { Task { await catalog.loadTasks(for: ref) } }
                    }
                )
            }
            row("Task") {
                SearchPicker(
                    icon: "checklist", placeholder: "No task",
                    selection: draft.task?.name,
                    items: draft.project.flatMap { catalog.tasksByProject[$0.id] } ?? [],
                    title: \.name,
                    badge: { $0.status },
                    isLoading: draft.project.map { catalog.isLoading("tasks:\($0.id)") } ?? false,
                    disabled: draft.project == nil,
                    onOpen: { if let p = draft.project { await catalog.loadTasks(for: p) } },
                    onRefresh: { if let p = draft.project { await catalog.loadTasks(for: p, force: true) } },
                    onSelect: { task in draft.task = task.map { Ref(id: $0.id, name: $0.name) } }
                )
            }
            row("Ticket") {
                SearchPicker(
                    icon: "ticket", placeholder: "No ticket",
                    selection: draft.ticket?.name,
                    items: draft.client.flatMap { catalog.ticketsByClient[$0.id] } ?? [],
                    title: \.title,
                    badge: { $0.status },
                    isLoading: draft.client.map { catalog.isLoading("tickets:\($0.id)") } ?? false,
                    disabled: draft.client == nil,
                    onOpen: { if let c = draft.client { await catalog.loadTickets(for: c) } },
                    onRefresh: { if let c = draft.client { await catalog.loadTickets(for: c, force: true) } },
                    onSelect: { ticket in draft.ticket = ticket.map { Ref(id: $0.id, name: $0.title) } }
                )
            }
            row("Notes", divider: false) {
                HStack(alignment: .top, spacing: 10) {
                    if !labelled {
                        Image(systemName: "text.bubble")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 20)
                            .padding(.top, 2)
                    }
                    TextField(labelled ? "What was this time for?" : "What are you working on?", text: $draft.notes, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .lineLimit(1...4)
                }
                .padding(.vertical, 12)
                .padding(.horizontal, labelled ? 12 : 0)
                .background {
                    if labelled {
                        RoundedRectangle(cornerRadius: 10).fill(Theme.cream)
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    }
                }
            }

            if !labelled { Divider() }
            billableRow

            if let error = catalog.lastError {
                ErrorBanner(message: error) { catalog.lastError = nil }
                    .padding(.top, 6)
            }
        }
    }

    private var billableRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "dollarsign.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
                .frame(width: 20)
            Text("Billable")
                .font(.system(size: 13))
                .foregroundStyle(Theme.ink)
            Spacer()
            Toggle("Billable", isOn: $draft.isBillable)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(Theme.navy)
                .controlSize(.small)
        }
        .padding(.vertical, labelled ? 4 : 10)
    }

    @ViewBuilder
    private func row<Content: View>(_ label: String, divider: Bool = true, @ViewBuilder content: () -> Content) -> some View {
        if labelled {
            VStack(alignment: .leading, spacing: 6) {
                CapsLabel(label)
                if label == "Notes" {
                    content()
                } else {
                    content()
                        .padding(.horizontal, 12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                }
            }
            .padding(.bottom, 12)
        } else {
            content()
            if divider { Divider() }
        }
    }
}

/// A row that opens a searchable popover list — Moxie workspaces can have hundreds of clients.
struct SearchPicker<Item: Identifiable & Hashable>: View {
    let icon: String
    let placeholder: String
    let selection: String?
    let items: [Item]
    let title: (Item) -> String
    var badge: (Item) -> String? = { _ in nil }
    var isLoading = false
    var disabled = false
    var onOpen: () async -> Void = {}
    var onRefresh: () async -> Void = {}
    let onSelect: (Item?) -> Void

    @State private var isOpen = false

    init(
        icon: String, placeholder: String, selection: String?, items: [Item],
        title: KeyPath<Item, String>, badge: @escaping (Item) -> String? = { _ in nil },
        isLoading: Bool = false, disabled: Bool = false,
        onOpen: @escaping () async -> Void = {}, onRefresh: @escaping () async -> Void = {},
        onSelect: @escaping (Item?) -> Void
    ) {
        self.icon = icon
        self.placeholder = placeholder
        self.selection = selection
        self.items = items
        self.title = { $0[keyPath: title] }
        self.badge = badge
        self.isLoading = isLoading
        self.disabled = disabled
        self.onOpen = onOpen
        self.onRefresh = onRefresh
        self.onSelect = onSelect
    }

    var body: some View {
        Button {
            isOpen = true
            Task { await onOpen() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 20)
                Text(selection ?? placeholder)
                    .font(.system(size: 13, weight: selection == nil ? .regular : .medium))
                    .foregroundStyle(selection == nil ? Theme.faint : Theme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            PickerList(
                placeholder: placeholder, items: items, title: title, badge: badge,
                selection: selection, isLoading: isLoading, onRefresh: onRefresh
            ) { item in
                onSelect(item)
                isOpen = false
            }
        }
    }
}

private struct PickerList<Item: Identifiable & Hashable>: View {
    let placeholder: String
    let items: [Item]
    let title: (Item) -> String
    let badge: (Item) -> String?
    let selection: String?
    let isLoading: Bool
    let onRefresh: () async -> Void
    let onSelect: (Item?) -> Void

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var filtered: [Item] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { title($0).localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search…", text: $query)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { if let first = filtered.first { onSelect(first) } }
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await onRefresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.muted)
                        .help("Reload from Moxie")
                }
            }
            .padding(10)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if selection != nil {
                        option(label: "Clear (\(placeholder.lowercased()))", badge: nil, isSelected: false, muted: true) { onSelect(nil) }
                    }
                    ForEach(filtered) { item in
                        option(label: title(item), badge: badge(item), isSelected: title(item) == selection) { onSelect(item) }
                    }
                    if filtered.isEmpty && !isLoading {
                        Text(items.isEmpty ? "Nothing found in Moxie" : "No matches")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.muted)
                            .padding(12)
                    }
                }
                .padding(4)
            }
            .frame(height: min(320, CGFloat(max(filtered.count, 1)) * 32 + 16))
        }
        .frame(width: 300)
        .onAppear { searchFocused = true }
    }

    private func option(label: String, badge: String?, isSelected: Bool, muted: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(label)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(muted ? Theme.muted : Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let badge, !badge.isEmpty {
                    Text(badge.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Theme.cream))
                }
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.navy)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(HoverRowStyle())
    }
}

struct HoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        HoverRow(configuration: configuration)
    }

    private struct HoverRow: View {
        let configuration: Configuration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cream.opacity(hovering || configuration.isPressed ? 1 : 0)))
                .onHover { hovering = $0 }
        }
    }
}

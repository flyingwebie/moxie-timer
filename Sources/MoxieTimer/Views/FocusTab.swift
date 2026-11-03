import SwiftUI

/// One-thing mode: choose a single task, give it a tiny first step, and focus in adaptive blocks.
struct FocusTab: View {
    @Environment(FocusStore.self) private var focus
    @Environment(AppSettings.self) private var settings
    @Environment(TaskInbox.self) private var inbox
    @Environment(AIService.self) private var ai
    @Environment(TimerStore.self) private var timer
    @Environment(Clock.self) private var clock
    @Environment(WidgetUI.self) private var ui
    @Environment(MoxieLiveTimer.self) private var live

    @State private var isPicking = false
    @State private var isSuggesting = false
    @State private var isAddingChecklist = false
    @State private var checklistAddedFor: String?
    @State private var chosenMinutes: Int?
    /// Picking other work while time is running (the running time is saved before switching).
    @State private var isSwitching = false

    var body: some View {
        @Bindable var focusBindable = focus
        return VStack(alignment: .leading, spacing: 14) {
            if let banner = focus.banner {
                CelebrationBanner(message: banner) { focus.banner = nil }
            }
            if let error = focus.lastError {
                ErrorBanner(message: error) { focus.lastError = nil }
            }

            if isSwitching {
                switchView
            } else if let block = focus.block, block.isWorking, let target = focus.target {
                activeView(block: block, target: target)
            } else if let session = timer.session {
                trackingView(session: session)
            } else if let target = focus.target {
                readyView(target: target)
            } else {
                chooseView
            }
        }
        .padding(16)
        .task { await inbox.refreshIfStale(mcp: live.isActive ? live.mcp : nil) }
        .onChange(of: focus.target) { isSwitching = false }
        .sheet(item: $focusBindable.pendingTicketNote) { draft in
            TicketNoteSheet(draft: draft)
        }
    }

    // MARK: Switch

    private var switchView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    CapsLabel("Switch to")
                    if timer.session != nil {
                        Text(timer.canSaveCurrent
                             ? "The running time is saved on “\(focus.target?.name ?? "current work")” first."
                             : "The running time has no client yet — it moves to Review first.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Back") { isSwitching = false }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.navy)
            }
            QuickStartComposer()
            upNext
        }
    }

    // MARK: Tracking (timer running, no focus block)

    /// Mirrors the Timer tab: same work, same clock, same stop & save.
    private func trackingView(session: TimerSession) -> some View {
        let now = clock.now
        let draft = timer.draft
        let target = focus.target
        let name = target?.name ?? "Current work"

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CapsLabel(session.isRunning ? "Now tracking" : "Paused")
                    Spacer()
                    Button("Change") { isSwitching = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.navy)
                        .help("Switch to another task — the running time is saved first")
                }
                Text(name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    let context = [draft.client?.name, draft.project?.name].compactMap { $0 }.joined(separator: " · ")
                    if !context.isEmpty {
                        Text(context).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if let due = target?.due.flatMap({ MoxieTask.dayFormatter.date(from: String($0.prefix(10))) }) {
                        DueBadge(date: due)
                    }
                    KindBadge(isTicket: draft.ticket != nil, isOwn: draft.task == nil && draft.ticket == nil)
                }
                if let ticket = draft.ticket, ticket.name != name {
                    Label(ticket.name, systemImage: "ticket")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }

            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(DurationFormat.clock(session.elapsed(at: now)))
                        .font(.system(size: 30, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    let start = session.start(at: now)
                    Text("Started at \(start.formatted(date: .omitted, time: .shortened)) · \(start.relativeDayName)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                CircleIconButton(
                    systemName: session.isRunning ? "pause.fill" : "play.fill",
                    size: 40,
                    help: session.isRunning ? "Pause" : "Resume"
                ) { timer.toggle() }
            }

            if draft.client == nil {
                Label(timer.canSaveCurrent
                      ? "No client yet — you can set it in the end-of-day review."
                      : "No client yet — set it in the Timer tab before the time is saved.",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onBreak)
            }
            if let error = timer.lastError {
                ErrorBanner(message: error) { timer.lastError = nil }
            }

            Button { focus.startFromTimer() } label: {
                Label("Focus on this · \(focus.suggestedMinutes) min block", systemImage: "scope").frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle())
            .help("Turn this timer into a focus block with a countdown and a break at the end")

            Button { Task { await focus.saveForLater() } } label: {
                HStack(spacing: 8) {
                    if timer.isSaving {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Image(systemName: "stop.fill").font(.system(size: 10))
                    }
                    Text(timer.isSaving ? "Saving…" : "Stop & save entry")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(timer.isSaving || focus.isFinishing)
            .help("Save the time and keep this as Up next")

            HStack(spacing: 8) {
                Button { ui.tab = .timer } label: {
                    Label("Edit in Timer", systemImage: "slider.horizontal.3").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                .help("Change client, project, task, ticket, notes or the start time")
                if let target {
                    Button { Task { await finish(target) } } label: {
                        Label(doneTitle(target), systemImage: "checkmark.circle").lineLimit(1).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(focus.isFinishing || timer.isSaving)
                    .help(doneHelp(target))
                }
            }
        }
    }

    // MARK: Choose

    private var chooseView: some View {
        VStack(alignment: .leading, spacing: 14) {
            TodayStrip()

            VStack(alignment: .leading, spacing: 3) {
                Text(greeting)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                Text("What's the one thing?")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
            }

            QuickStartComposer()

            upNext
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: clock.now)
        let part = hour < 12 ? "Good morning" : (hour < 18 ? "Good afternoon" : "Good evening")
        return "\(part) · \(clock.now.formatted(.dateTime.weekday(.wide).day().month(.wide)))"
    }

    private var upNext: some View {
        let all = inbox.visibleTasks
        let rows = Array(all.prefix(5))
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CapsLabel("Up next")
                if !all.isEmpty {
                    Text("\(all.count)")
                        .font(.system(size: 10, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Theme.cream))
                }
                Spacer()
                Button { Task { await pickForMe() } } label: {
                    HStack(spacing: 4) {
                        if isPicking { ProgressView().controlSize(.mini) } else { Image(systemName: "sparkles") }
                        Text(isPicking ? "Choosing…" : "Pick for me")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(Capsule().fill(Theme.navy.opacity(0.07)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isPicking || (all.isEmpty && !inbox.tasks.isEmpty))
                .help(ai.hasEnabledEngine ? "Let AI choose the best next task from this list" : "Choose the most urgent task from this list")
            }

            InboxFilterBar()

            if rows.isEmpty {
                if inbox.isLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading your tasks…").font(.system(size: 12)).foregroundStyle(Theme.muted)
                    }
                    .padding(.vertical, 10)
                } else if let error = inbox.lastError {
                    ErrorBanner(message: error) { inbox.lastError = nil }
                } else {
                    Text(inbox.isFiltered ? "Nothing open for this filter — add one above." : "No open tasks. Add one above.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 6)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { task in
                        TaskRow(task: task, isNew: inbox.justAdded.contains(task.id)) { Task { await focus.select(task); isSwitching = false } }
                    }
                }
                Button { ui.route = .tasks } label: {
                    HStack(spacing: 4) {
                        Text(all.count > rows.count ? "See all \(all.count) tasks" : "Open task list")
                        Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Theme.navy)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
        }
    }

    private func pickForMe() async {
        isPicking = true
        defer { isPicking = false }
        if inbox.tasks.isEmpty { await inbox.refresh(mcp: live.isActive ? live.mcp : nil) }
        let candidates = Array(inbox.visibleTasks.prefix(12))
        guard let fallback = candidates.first else {
            // A load error is already shown under the list; only explain the empty case here.
            if inbox.lastError == nil { focus.lastError = "No open tasks found in Moxie. Add one above." }
            return
        }
        var chosen = fallback
        // The rules fallback already ranks Moxie-flagged items first (TaskInbox.score); say so when that's why it won.
        var reason = inbox.moxieReason(for: fallback) ?? "Most urgent by due date and priority."
        if ai.hasEnabledEngine, candidates.count > 1 {
            do {
                let pick = try await ai.pick(from: candidates.map(describe))
                chosen = candidates[pick.index]
                reason = pick.reason.isEmpty ? "Suggested by \(ai.lastEngine?.title ?? "AI")." : pick.reason
            } catch {
                reason += " (AI unavailable, used rules.)"
            }
        }
        await focus.select(chosen)
        focus.pickReason = reason
    }

    private func describe(_ task: MoxieTask) -> String {
        var parts = [task.name]
        let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " / ")
        if !context.isEmpty { parts.append(context) }
        if let due = task.due { parts.append("due \(due.formatted(date: .abbreviated, time: .omitted))") }
        if let priority = task.taskPriority { parts.append("priority \(priority)") }
        if task.isTicket { parts.append("client support ticket") }
        if let reason = inbox.moxieReason(for: task) { parts.append("Moxie flagged this: \(reason)") }
        return parts.joined(separator: " — ")
    }

    // MARK: Ready

    private func readyView(target: FocusTarget) -> some View {
        @Bindable var focus = focus
        let minutes = chosenMinutes ?? focus.suggestedMinutes
        let options = Array(Set(FocusStore.presetMinutes + [focus.suggestedMinutes])).sorted()

        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    CapsLabel("Up next")
                    Spacer()
                    Button("Change") { focus.clearTarget() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.navy)
                }
                Text(target.name)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if !target.context.isEmpty {
                        Text(target.context).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    if let due = target.due.flatMap({ MoxieTask.dayFormatter.date(from: String($0.prefix(10))) }) {
                        DueBadge(date: due)
                    }
                    KindBadge(isTicket: target.ticketId != nil, isOwn: target.taskId == nil && target.ticketId == nil)
                }
                if let reason = focus.pickReason {
                    Label(reason, systemImage: "sparkles")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.navy.opacity(0.8))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                CapsLabel("Tiny first step")
                HStack(spacing: 6) {
                    FieldBox {
                        TextField("The 2-minute first action…", text: Binding(
                            get: { focus.target?.firstStep ?? "" },
                            set: { focus.target?.firstStep = $0 }
                        ))
                        .textFieldStyle(.plain)
                    }
                    Button { Task { await suggestStep(target) } } label: {
                        Group {
                            if isSuggesting { ProgressView().controlSize(.small) } else { Image(systemName: "sparkles") }
                        }
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .disabled(isSuggesting || !ai.hasEnabledEngine)
                    .help("Suggest a first step with AI")
                }
                if let taskId = target.taskId, live.isActive {
                    Button { Task { await addFirstStepToChecklist(taskId: taskId, step: target.firstStep) } } label: {
                        HStack(spacing: 6) {
                            if isAddingChecklist {
                                ProgressView().controlSize(.mini)
                            } else {
                                Image(systemName: checklistAddedFor == taskId ? "checkmark.circle.fill" : "checklist")
                            }
                            Text(checklistAddedFor == taskId ? "Added to Moxie checklist" : "Add to checklist in Moxie")
                        }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .disabled(isAddingChecklist || checklistAddedFor == taskId
                              || target.firstStep.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Appends this as a new item on the task's checklist in Moxie, keeping any existing items")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                CapsLabel("Focus block")
                HStack(spacing: 6) {
                    ForEach(options, id: \.self) { option in
                        Button { chosenMinutes = option } label: {
                            Text("\(option)m\(option == focus.suggestedMinutes ? " ★" : "")")
                                .font(.system(size: 12, weight: option == minutes ? .bold : .medium))
                                .foregroundStyle(option == minutes ? .white : Theme.ink.opacity(0.8))
                                .padding(.horizontal, 10)
                                .frame(height: 26)
                                .background(Capsule().fill(option == minutes ? Theme.navy : .white))
                                .overlay(Capsule().strokeBorder(option == minutes ? .clear : Theme.border))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle("Start with a 5-minute warm-up", isOn: $focus.warmupEnabled)
                    .toggleStyle(.switch)
                    .tint(Theme.navy)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                Text("★ adapts: longer after blocks you finish, shorter after ones you stop early.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
            }

            if timer.draft.client == nil {
                Label(timer.canSaveCurrent
                      ? "No client yet — you can set it in the end-of-day review."
                      : "No client yet — set it in the Timer tab before the time is saved.",
                      systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.onBreak)
            }

            Button {
                focus.startBlock(minutes: minutes)
                chosenMinutes = nil
            } label: {
                Label("Start focusing · \(minutes) min", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)

            Button { Task { await finish(target) } } label: {
                Label(doneTitle(target), systemImage: "checkmark.circle").frame(maxWidth: .infinity)
            }
            .buttonStyle(ChipButtonStyle())
            .disabled(focus.isFinishing)
            .help(doneHelp(target))
        }
    }

    /// Only when the user opted in, and only for real Moxie tasks/tickets.
    private func closesInMoxie(_ target: FocusTarget) -> Bool {
        settings.completeInMoxie && (target.taskId != nil || target.ticketId != nil)
    }

    private func doneTitle(_ target: FocusTarget) -> String {
        guard closesInMoxie(target) else { return "Finish" }
        return target.ticketId != nil ? "Finish & close ticket" : "Finish & complete"
    }

    private func doneHelp(_ target: FocusTarget) -> String {
        let time = timer.session != nil ? "Saves the running time and clears it from Up next. " : "Clears it from Up next. "
        guard closesInMoxie(target) else {
            return time + "The task stays open in Moxie — close it there when you're ready (or turn on closing in Settings → Focus)."
        }
        return time + (target.ticketId != nil ? "Also sets the ticket's status in Moxie." : "Also marks the task complete in Moxie.")
    }

    private func suggestStep(_ target: FocusTarget) async {
        isSuggesting = true
        defer { isSuggesting = false }
        do {
            let description = target.taskId.flatMap { id in inbox.tasks.first { $0.id == id }?.description } ?? ""
            let step = try await ai.firstStep(task: target.name, context: "\(target.context)\n\(description.prefix(600))")
            focus.target?.firstStep = step
        } catch {
            focus.lastError = error.localizedDescription
        }
    }

    /// Appends the tiny first step to the Moxie task's checklist, keeping every item already there.
    private func addFirstStepToChecklist(taskId: String, step: String) async {
        guard live.isActive else { return }
        isAddingChecklist = true
        defer { isAddingChecklist = false }
        do {
            try await live.mcp.appendChecklistItem(taskId: taskId, text: step)
            checklistAddedFor = taskId
        } catch {
            focus.lastError = error.localizedDescription
        }
    }

    /// Wraps `FocusStore.finish`: on a ticket with MCP active, drafts a private "what I did" note
    /// afterward (never posted without an explicit tap in its sheet).
    private func finish(_ target: FocusTarget) async {
        let ticketId = target.ticketId
        let firstStep = target.firstStep
        let notes = timer.draft.notes
        let duration = timer.session?.elapsed(at: .now) ?? 0
        await focus.finish(closeInMoxie: closesInMoxie(target))
        guard let ticketId, live.isActive, focus.lastError == nil else { return }
        let text = await ticketNoteDraft(ticket: target.name, firstStep: firstStep, notes: notes, duration: duration)
        focus.pendingTicketNote = TicketNoteDraft(ticketId: ticketId, ticketName: target.name, text: text)
    }

    /// AI-drafted note when an engine is enabled, otherwise a plain template — either way the user
    /// edits and confirms it in `TicketNoteSheet` before anything is posted.
    private func ticketNoteDraft(ticket: String, firstStep: String, notes: String, duration: TimeInterval) async -> String {
        if ai.hasEnabledEngine,
           let generated = try? await ai.ticketNote(ticket: ticket, firstStep: firstStep, notes: notes, duration: duration),
           !generated.isEmpty {
            return generated
        }
        var parts = ["Worked on this for \(DurationFormat.short(duration))."]
        let trimmedStep = firstStep.trimmingCharacters(in: .whitespaces)
        if !trimmedStep.isEmpty { parts.append("First step: \(trimmedStep).") }
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedNotes.isEmpty { parts.append(trimmedNotes) }
        return parts.joined(separator: " ")
    }

    // MARK: Active

    private func activeView(block: FocusBlock, target: FocusTarget) -> some View {
        let now = clock.now
        let remaining = Int(block.remaining(at: now).rounded(.up))
        let color = block.pausedAt != nil ? Theme.muted : (block.phase == .warmup ? Theme.warmup : Theme.running)

        return VStack(spacing: 14) {
            ZStack {
                Circle().stroke(Color.black.opacity(0.07), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: block.progress(at: now))
                    .stroke(color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                VStack(spacing: 2) {
                    Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                        .font(.system(size: 34, weight: .bold).monospacedDigit())
                        .foregroundStyle(Theme.ink)
                    Text(block.pausedAt != nil ? "Paused" : (block.phase == .warmup ? "Warm-up" : (block.snoozed ? "Snoozed" : "Focus")))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(color)
                }
            }
            .frame(width: 160, height: 160)
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text(target.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if !target.context.isEmpty {
                    Text(target.context).font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
            }

            if !target.firstStep.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill").foregroundStyle(Theme.navy)
                    Text(target.firstStep)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cream))
            }

            HStack(spacing: 8) {
                Button(block.pausedAt == nil ? "Pause" : "Resume") {
                    block.pausedAt == nil ? focus.pauseBlock() : focus.resumeBlock()
                }
                .buttonStyle(ChipButtonStyle())
                Button("Stop block") { focus.stopBlock() }
                    .buttonStyle(ChipButtonStyle())
                    .help("Stop focusing; the time stays in the Timer tab")
                Spacer()
                Button("Switch task") { isSwitching = true }
                    .buttonStyle(ChipButtonStyle())
                    .help("Work on something else — the time so far is saved first")
            }

            HStack(spacing: 8) {
                Button { Task { await focus.saveForLater() } } label: {
                    Label("Stop & save", systemImage: "stop.fill").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(ChipButtonStyle())
                .help("Save the time and keep this as Up next")
                Button { Task { await finish(target) } } label: {
                    Label(doneTitle(target), systemImage: "checkmark").lineLimit(1).frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle())
                .help(doneHelp(target))
            }
            .disabled(focus.isFinishing)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Shared pieces

struct TaskRow: View {
    let task: MoxieTask
    var isNew = false
    let action: () -> Void
    @Environment(FocusStore.self) private var focus
    @Environment(TaskInbox.self) private var inbox
    @Environment(MoxieLiveTimer.self) private var live
    @State private var hovering = false
    /// Ticked but not yet sent: Moxie is only updated after a short undo window, like Todoist.
    @State private var checked = false
    @State private var pending: Task<Void, Never>?
    @State private var showMakeTask = false

    static let undoWindow: Duration = .seconds(2.5)

    var body: some View {
        HStack(spacing: 10) {
            TodoCheckbox(color: ringColor, checked: checked) { toggle() }
                .padding(.leading, 8)
                .help(checked ? "Undo" : (task.isTicket ? "Close this ticket in Moxie" : "Complete this task in Moxie"))

            Button { checked ? toggle() : action() } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(task.name)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(checked ? Theme.faint : Theme.ink)
                                .strikethrough(checked, color: Theme.faint)
                                .lineLimit(1)
                            if isNew, !checked {
                                Text("NEW")
                                    .font(.system(size: 8.5, weight: .heavy))
                                    .tracking(0.5)
                                    .foregroundStyle(Theme.running)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1.5)
                                    .background(Capsule().fill(Theme.running.opacity(0.14)))
                            }
                        }
                        HStack(spacing: 5) {
                            KindBadge(isTicket: task.isTicket)
                            let context = [task.client?.name, task.project?.name].compactMap { $0 }.joined(separator: " · ")
                            if !context.isEmpty {
                                Text(context).font(.system(size: 11)).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                            if let reason = inbox.moxieReason(for: task) {
                                Label(reason, systemImage: "sparkles")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Theme.navy.opacity(0.8))
                                    .lineLimit(1)
                                    .help("Moxie flagged this as needing attention")
                            }
                        }
                        .opacity(checked ? 0.5 : 1)
                    }
                    Spacer(minLength: 4)
                    if checked {
                        Text("Undo")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.navy)
                    } else if hovering {
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Theme.navy))
                            .help("Focus on this")
                    } else if let due = task.due {
                        DueBadge(date: due)
                    }
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.cream.opacity(hovering && !checked ? 1 : 0)))
        .animation(.easeOut(duration: 0.15), value: checked)
        .onHover { hovering = $0 }
        .contextMenu {
            if task.isTicket, live.isActive {
                Button { showMakeTask = true } label: {
                    Label("Make a task from this ticket", systemImage: "checklist")
                }
            }
        }
        .sheet(isPresented: $showMakeTask) {
            MakeTaskFromTicketSheet(ticket: task)
        }
    }

    /// Tick: celebrate now, send to Moxie after the undo window. Tick again (or click the row) to undo.
    private func toggle() {
        if checked {
            pending?.cancel()
            pending = nil
            checked = false
            return
        }
        checked = true
        focus.celebrate()
        pending = Task {
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            await focus.complete(task)
            // Still on screen means Moxie refused it (the error shows in Focus); untick it.
            checked = false
            pending = nil
        }
    }

    /// Todoist colours: P1 red, P2 orange, P3 blue, otherwise grey. Tickets are teal-blue.
    private var ringColor: Color {
        if task.isTicket { return Theme.warmup }
        switch task.priorityRank {
        case 4: return Theme.danger
        case 3: return Theme.onBreak
        case 2: return Color(red: 0.25, green: 0.45, blue: 0.85)
        default: return Color.black.opacity(0.35)
        }
    }
}

struct DueBadge: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var days: Int {
        Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: .now), to: date).day ?? 0
    }

    private var label: String {
        switch days {
        case ..<0: return "\(-days)d overdue"
        case 0: return "Today"
        case 1: return "Tomorrow"
        case 2...6: return date.formatted(.dateTime.weekday(.abbreviated))
        default: return date.formatted(.dateTime.month(.abbreviated).day())
        }
    }

    private var color: Color {
        switch days {
        case ..<0: return Theme.danger
        case 0: return Theme.onBreak
        default: return Theme.muted
        }
    }
}

struct CelebrationBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("🎉")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.running.opacity(0.12)))
    }
}

/// "You were away" prompt from the idle monitor.
struct IdleBanner: View {
    @Environment(IdleMonitor.self) private var idle

    var body: some View {
        if let away = idle.pending {
            VStack(alignment: .leading, spacing: 8) {
                Label("You were away \(DurationFormat.short(away.duration)) (\(away.start.formatted(date: .omitted, time: .shortened))–\(away.end.formatted(date: .omitted, time: .shortened)))",
                      systemImage: "moon.zzz.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("The timer kept running. What should happen to that time?")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                HStack(spacing: 6) {
                    Button("Keep") { idle.keep() }.buttonStyle(ChipButtonStyle())
                    Button("Discard") { idle.discard(andPause: false) }.buttonStyle(ChipButtonStyle())
                    Button("Discard & pause") { idle.discard(andPause: true) }.buttonStyle(ChipButtonStyle())
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.warmup.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.warmup.opacity(0.3)))
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

/// Shown on top of the card while entries are held for review.
struct ReviewBanner: View {
    @Environment(HistoryStore.self) private var history
    @Environment(WidgetUI.self) private var ui

    var body: some View {
        let pending = history.pending
        if !pending.isEmpty {
            let olderThanToday = pending.contains { !Calendar.current.isDateInToday($0.start) }
            Button { ui.route = .review } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tray.full.fill").foregroundStyle(olderThanToday ? Theme.onBreak : Theme.navy)
                    Text(olderThanToday
                         ? "\(pending.count) held entries include earlier days — review & send"
                         : "\(pending.count) entries (\(DurationFormat.short(pending.reduce(0) { $0 + $1.duration }))) waiting for review")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill((olderThanToday ? Theme.onBreak : Theme.navy).opacity(0.07)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
        }
    }
}

/// "Looks like Client · Project" — one click applies the learned suggestion.
struct SuggestionChip: View {
    @Environment(ActivityWatcher.self) private var activity

    var body: some View {
        if let suggestion = activity.suggestion {
            Button { activity.applySuggestion() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Use \(suggestion.choice.label)").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(suggestion.reason).font(.system(size: 10)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Theme.navy)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(0.06)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// TASK / TICKET / OWN label so it's always clear what you're working on.
struct KindBadge: View {
    let isTicket: Bool
    var isOwn = false

    var body: some View {
        let (text, color): (String, Color) = isOwn ? ("OWN", Theme.muted) : (isTicket ? ("TICKET", Theme.warmup) : ("TASK", Theme.navy))
        Text(text)
            .font(.system(size: 8.5, weight: .heavy))
            .tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.12)))
            .help(isOwn ? "Something you typed — not a Moxie task" : (isTicket ? "Moxie ticket" : "Moxie task"))
    }
}

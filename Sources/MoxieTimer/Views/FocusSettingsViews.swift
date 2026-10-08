import ApplicationServices
import SwiftUI

struct FocusSettingsSection: View {
    @Environment(FocusStore.self) private var focus
    @Environment(IdleMonitor.self) private var idle

    var body: some View {
        @Bindable var focus = focus
        @Bindable var idle = idle

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Focus")
            Toggle("Start blocks with a 5-minute warm-up", isOn: $focus.warmupEnabled)
                .toggleStyle(.switch)
                .tint(Theme.navy)
                .controlSize(.small)
                .font(.system(size: 12))
            HStack {
                Text("Ask about time away after").font(.system(size: 12))
                Spacer()
                Picker("Idle threshold", selection: $idle.thresholdMinutes) {
                    Text("Off").tag(0)
                    ForEach([2, 5, 10, 15, 30], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            HStack {
                Text("Next block length").font(.system(size: 12))
                Spacer()
                Text("\(focus.suggestedMinutes) min (adaptive)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            Text("Capture a task from anywhere with \(HotKey.captureDescription).")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        }
    }
}

struct AISettingsSection: View {
    @Environment(AIService.self) private var ai
    @State private var results: [AIEngine: String] = [:]
    @State private var testing: Set<AIEngine> = []

    var body: some View {
        @Bindable var ai = ai

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("AI for first steps & “pick for me”")
            Text("Tried top to bottom; the first one that answers wins.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)

            ForEach(Array(ai.order.enumerated()), id: \.element) { index, engine in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Toggle(engine.title, isOn: Binding(
                            get: { ai.enabled.contains(engine) },
                            set: { ai.setEnabled(engine, $0) }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button { Task { await test(engine) } } label: {
                            if testing.contains(engine) { ProgressView().controlSize(.mini) } else { Text("Test") }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.navy)
                        .disabled(testing.contains(engine))
                        Button { ai.move(engine, by: -1) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.plain)
                            .disabled(index == 0)
                        Button { ai.move(engine, by: 1) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.plain)
                            .disabled(index == ai.order.count - 1)
                    }
                    Text(results[engine] ?? engine.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(results[engine]?.hasPrefix("✗") == true ? Theme.danger : Theme.faint)
                        .lineLimit(2)
                        .padding(.leading, 20)
                }
            }

            HStack {
                Text("Ollama model").font(.system(size: 12))
                FieldBox {
                    TextField("first installed", text: $ai.ollamaModel).textFieldStyle(.plain).font(.system(size: 12))
                }
            }
            Text("The CLI engines send the task name and description to their provider.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)
        }
    }

    private func test(_ engine: AIEngine) async {
        testing.insert(engine)
        results[engine] = await ai.test(engine)
        testing.remove(engine)
    }
}

struct ReviewSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ActivityWatcher.self) private var activity
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var forgot = false

    private let weekdays = [(2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S"), (1, "S")]

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Review & reminders")

            toggle("Hold entries for an end-of-day review", $settings.holdForReview)
            if settings.holdForReview {
                HStack {
                    Text("Review prompt at").font(.system(size: 12))
                    Spacer()
                    timePicker($settings.reviewMinutes)
                }
            }

            toggle("Remind me when I work without a timer", $settings.trackingReminders)
                .onChange(of: settings.trackingReminders) { _, on in if on { Notifier.shared.requestAuthorization() } }

            HStack {
                Text("Work hours").font(.system(size: 12))
                Spacer()
                timePicker($settings.workStartMinutes)
                Text("–").foregroundStyle(Theme.muted)
                timePicker($settings.workEndMinutes)
            }
            HStack(spacing: 4) {
                ForEach(weekdays, id: \.0) { day, letter in
                    let on = settings.workDays.contains(day)
                    Button {
                        if on { settings.workDays.remove(day) } else { settings.workDays.insert(day) }
                    } label: {
                        Text(letter)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(on ? .white : Theme.muted)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(on ? Theme.navy : Theme.cream))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            Text("Reminders and gap-finding only use these hours.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.faint)

            toggle("Use window titles for project suggestions", $settings.useWindowTitles)
                .onChange(of: settings.useWindowTitles) { _, on in
                    if on {
                        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
                    }
                }
            if settings.useWindowTitles && !accessibilityGranted {
                Text("Allow Moxie Timer in System Settings → Privacy & Security → Accessibility. Each app update may need it re-allowed.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.onBreak)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Text(forgot ? "Forgotten." : "Suggestions are learned locally while you track.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.faint)
                Spacer()
                Button("Forget learned apps") {
                    activity.learner.forgetAll()
                    forgot = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.navy)
            }
        }
        .onAppear { accessibilityGranted = AXIsProcessTrusted() }
    }

    private func toggle(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.switch)
            .tint(Theme.navy)
            .controlSize(.small)
            .font(.system(size: 12))
    }

    private func timePicker(_ minutes: Binding<Int>) -> some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(minutes.wrappedValue * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .datePickerStyle(.field)
        .frame(width: 80)
    }
}

struct DistractionSettingsSection: View {
    @Environment(AppSettings.self) private var settings
    @State private var newKeyword = ""

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            CapsLabel("Distractions & check-ins")

            Toggle("Nudge me when I drift while the timer runs", isOn: $settings.watchDistractions)
                .toggleStyle(.switch)
                .tint(Theme.navy)
                .controlSize(.small)
                .font(.system(size: 12))

            Text("Apps").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            FlowChips(
                items: settings.distractionApps.sorted { $0.value < $1.value }.map { ($0.key, $0.value) },
                onRemove: { settings.distractionApps.removeValue(forKey: $0) }
            )
            Menu("Add an app…") {
                ForEach(runningApps, id: \.bundleId) { app in
                    Button(app.name) { settings.distractionApps[app.bundleId] = app.name }
                }
            }
            .menuStyle(.borderlessButton)
            .font(.system(size: 12, weight: .semibold))
            .fixedSize()

            Text("Sites & words in window titles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            FlowChips(
                items: settings.distractionKeywords.map { ($0, $0) },
                onRemove: { keyword in settings.distractionKeywords.removeAll { $0 == keyword } }
            )
            HStack(spacing: 6) {
                FieldBox {
                    TextField("e.g. youtube", text: $newKeyword)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit(addKeyword)
                }
                Button("Add", action: addKeyword).buttonStyle(ChipButtonStyle())
            }
            if !settings.useWindowTitles {
                Text("Turn on “Use window titles” above so sites can be recognised in your browser.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.onBreak)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Text("“Still on it?” check-in every").font(.system(size: 12))
                Spacer()
                Picker("Check-in", selection: $settings.checkInMinutes) {
                    Text("Off").tag(0)
                    ForEach([10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) min").tag($0) }
                }
                .labelsHidden()
                .frame(width: 90)
            }
        }
    }

    private struct RunningApp {
        let bundleId: String
        let name: String
    }

    private var runningApps: [RunningApp] {
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningApp? in
                guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                      settings.distractionApps[id] == nil, seen.insert(id).inserted else { return nil }
                return RunningApp(bundleId: id, name: app.localizedName ?? id)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func addKeyword() {
        let word = newKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard word.count >= 2, !settings.distractionKeywords.contains(word) else { return }
        settings.distractionKeywords.append(word)
        newKeyword = ""
    }
}

/// Removable chips that wrap onto several lines.
private struct FlowChips: View {
    let items: [(id: String, label: String)]
    let onRemove: (String) -> Void

    var body: some View {
        if items.isEmpty {
            Text("None yet").font(.system(size: 11)).foregroundStyle(Theme.faint)
        } else {
            FlowLayout(spacing: 6) {
                ForEach(items, id: \.id) { item in
                    HStack(spacing: 4) {
                        Text(item.label).font(.system(size: 11, weight: .medium))
                        Button { onRemove(item.id) } label: { Image(systemName: "xmark").font(.system(size: 8, weight: .bold)) }
                            .buttonStyle(.plain)
                    }
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.cream))
                    .overlay(Capsule().strokeBorder(Theme.border))
                }
            }
        }
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

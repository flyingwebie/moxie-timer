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

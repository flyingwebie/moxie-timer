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

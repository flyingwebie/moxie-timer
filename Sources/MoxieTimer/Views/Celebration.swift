import SwiftUI

/// A short confetti burst. Change `trigger` to fire it; it draws nothing and ignores clicks when idle.
struct ConfettiView: View {
    let trigger: Int

    @State private var burst: Burst?

    private static let duration: TimeInterval = 2.4

    var body: some View {
        Group {
            if let burst {
                TimelineView(.animation) { context in
                    Canvas { canvas, size in
                        let t = context.date.timeIntervalSince(burst.started)
                        for piece in burst.pieces { draw(piece, at: t, in: &canvas, size: size) }
                    }
                }
            }
        }
        .allowsHitTesting(false)
        .onChange(of: trigger) {
            let started = Date.now
            burst = Burst(started: started, pieces: (0..<90).map { _ in Piece.random() })
            Task {
                try? await Task.sleep(for: .seconds(Self.duration))
                if burst?.started == started { burst = nil }
            }
        }
    }

    private func draw(_ piece: Piece, at t: TimeInterval, in canvas: inout GraphicsContext, size: CGSize) {
        let t = t - piece.delay
        guard t > 0 else { return }
        // Launched from just above the middle, with drag and gravity.
        let drag = exp(-1.6 * t)
        let x = size.width * 0.5 + piece.vx * (1 - drag) / 1.6
        let y = size.height * 0.32 + piece.vy * (1 - drag) / 1.6 + 260 * t * t * 0.5
        let fade = max(0, 1 - max(0, t - (Self.duration - 0.9)) / 0.7)
        guard fade > 0, y < size.height + 20 else { return }

        var piece2D = canvas
        piece2D.opacity = fade
        piece2D.translateBy(x: x, y: y)
        piece2D.rotate(by: .degrees(piece.spin * t * 360))
        // A flat strip seen tumbling: its height shrinks and grows as it flips.
        let flip = abs(cos(t * piece.flip))
        let rect = CGRect(x: -piece.size / 2, y: -piece.size * 0.3 * flip, width: piece.size, height: piece.size * 0.6 * flip + 0.6)
        let shape = piece.round ? Path(ellipseIn: rect) : Path(roundedRect: rect, cornerRadius: 1)
        piece2D.fill(shape, with: .color(piece.color))
    }

    private struct Burst {
        let started: Date
        let pieces: [Piece]
    }

    private struct Piece {
        let vx: Double
        let vy: Double
        let size: Double
        let spin: Double
        let flip: Double
        let delay: Double
        let round: Bool
        let color: Color

        static let palette: [Color] = [
            Color(red: 0.86, green: 0.30, blue: 0.25), // Todoist red
            Color(red: 0.98, green: 0.62, blue: 0.16),
            Color(red: 0.98, green: 0.82, blue: 0.25),
            Theme.running, Theme.warmup, Theme.navy,
            Color(red: 0.62, green: 0.40, blue: 0.86),
        ]

        static func random() -> Piece {
            let angle = Double.random(in: -.pi * 0.95 ... -.pi * 0.05)
            let speed = Double.random(in: 260...620)
            return Piece(
                vx: cos(angle) * speed, vy: sin(angle) * speed,
                size: .random(in: 6...10), spin: .random(in: -1.5...1.5), flip: .random(in: 4...11),
                delay: .random(in: 0...0.12), round: Bool.random() && Bool.random(),
                color: palette.randomElement()!
            )
        }
    }
}

/// Todoist-style round checkbox. The ring takes the priority colour; ticking it fills it with a check.
struct TodoCheckbox: View {
    let color: Color
    let checked: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(checked ? color : color.opacity(hovering ? 0.16 : 0.08))
                Circle()
                    .strokeBorder(color, lineWidth: 1.5)
                Image(systemName: "checkmark")
                    .font(.system(size: 8.5, weight: .heavy))
                    .foregroundStyle(checked ? .white : color)
                    .opacity(checked ? 1 : (hovering ? 0.9 : 0))
                    .scaleEffect(checked ? 1 : 0.85)
            }
            .frame(width: 18, height: 18)
            .scaleEffect(checked ? 1.08 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.55), value: checked)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

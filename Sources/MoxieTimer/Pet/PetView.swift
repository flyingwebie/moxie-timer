import SwiftUI

/// The animated blob, driven by the pet's live state.
struct PetView: View {
    @Environment(PetStore.self) private var pet
    var size: CGFloat = 38
    var expression: PetStore.Expression?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            PetBlob(
                expression: expression ?? pet.expression,
                mood: pet.mood,
                accessory: pet.accessory,
                time: context.date.timeIntervalSinceReferenceDate
            )
            .frame(width: size, height: size)
        }
    }
}

struct PetBlob: View {
    let expression: PetStore.Expression
    let mood: Double
    let accessory: PetAccessory
    let time: TimeInterval

    private var motion: (amplitude: Double, speed: Double) {
        switch expression {
        case .idle: return (0.04, 1.2)
        case .focused: return (0.025, 0.8)
        case .happy: return (0.06, 2.4)
        case .celebrating: return (0.08, 3.6)
        case .worried: return (0.05, 2.0)
        case .upset: return (0.07, 4.0)
        case .sleeping: return (0.02, 0.5)
        }
    }

    private var colors: [Color] {
        switch expression {
        case .worried: return [Color(red: 1.0, green: 0.78, blue: 0.45), Color(red: 0.95, green: 0.55, blue: 0.25)]
        case .upset: return [Color(red: 1.0, green: 0.62, blue: 0.45), Color(red: 0.88, green: 0.33, blue: 0.25)]
        case .sleeping: return [Color(red: 0.78, green: 0.75, blue: 0.95), Color(red: 0.55, green: 0.52, blue: 0.85)]
        default:
            if mood >= 70 { return [Color(red: 0.55, green: 0.95, blue: 0.8), Color(red: 0.15, green: 0.7, blue: 0.55)] }
            if mood >= 40 { return [Color(red: 0.6, green: 0.78, blue: 1.0), Color(red: 0.4, green: 0.45, blue: 0.95)] }
            return [Color(red: 0.75, green: 0.8, blue: 0.88), Color(red: 0.5, green: 0.55, blue: 0.68)]
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let breath = sin(time * motion.speed) * 0.04
            let bounce: Double = expression == .celebrating ? -abs(sin(time * 6)) * s * 0.12
                : (expression == .happy ? -abs(sin(time * 4)) * s * 0.06 : 0)
            let shake: Double = expression == .upset ? sin(time * 30) * s * 0.03 : 0

            ZStack {
                if accessory == .halo {
                    Ellipse()
                        .stroke(Color(red: 1, green: 0.84, blue: 0.3), lineWidth: s * 0.05)
                        .frame(width: s * 0.5, height: s * 0.14)
                        .offset(y: -s * 0.46)
                }

                BlobShape(time: time, amplitude: motion.amplitude, speed: motion.speed)
                    .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
                    .overlay(
                        BlobShape(time: time, amplitude: motion.amplitude, speed: motion.speed)
                            .stroke(.white.opacity(0.35), lineWidth: s * 0.02)
                    )
                    .shadow(color: colors[1].opacity(0.45), radius: s * 0.12, y: s * 0.04)

                // Shine
                Ellipse()
                    .fill(.white.opacity(0.45))
                    .frame(width: s * 0.18, height: s * 0.1)
                    .rotationEffect(.degrees(-25))
                    .offset(x: -s * 0.2, y: -s * 0.24)

                PetFace(expression: expression, time: time, size: s)
                    .offset(y: s * 0.04)

                accessoryView(size: s)

                if expression == .sleeping {
                    Text("z")
                        .font(.system(size: s * 0.28, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.navy.opacity(0.6))
                        .offset(x: s * 0.42, y: -s * 0.35 - (time.truncatingRemainder(dividingBy: 2)) * s * 0.08)
                        .opacity(1 - time.truncatingRemainder(dividingBy: 2) / 2)
                }
                if expression == .celebrating {
                    ForEach(0..<4, id: \.self) { index in
                        let angle = time * 2 + Double(index) * .pi / 2
                        Text("✦")
                            .font(.system(size: s * 0.2))
                            .foregroundStyle(Color(red: 1, green: 0.8, blue: 0.25))
                            .offset(x: cos(angle) * s * 0.62, y: sin(angle) * s * 0.55)
                    }
                }
            }
            .frame(width: s, height: s)
            .scaleEffect(x: 1 - breath, y: 1 + breath, anchor: .bottom)
            .offset(x: shake, y: bounce)
        }
    }

    @ViewBuilder
    private func accessoryView(size s: CGFloat) -> some View {
        switch accessory {
        case .none, .halo:
            EmptyView()
        case .sparkle:
            Text("✨").font(.system(size: s * 0.26)).offset(x: s * 0.36, y: -s * 0.36)
        case .bow:
            Text("🎀").font(.system(size: s * 0.3)).offset(x: s * 0.22, y: -s * 0.4)
        case .sprout:
            Text("🌱").font(.system(size: s * 0.3)).offset(y: -s * 0.5)
        case .beanie:
            VStack(spacing: -s * 0.03) {
                Circle().fill(.white).frame(width: s * 0.13)
                UnevenRoundedRectangle(topLeadingRadius: s * 0.28, topTrailingRadius: s * 0.28)
                    .fill(Color(red: 0.85, green: 0.3, blue: 0.35))
                    .frame(width: s * 0.58, height: s * 0.22)
                RoundedRectangle(cornerRadius: s * 0.04)
                    .fill(Color(red: 0.7, green: 0.2, blue: 0.27))
                    .frame(width: s * 0.64, height: s * 0.08)
            }
            .offset(y: -s * 0.33)
        case .scarf:
            Capsule()
                .fill(Color(red: 0.95, green: 0.45, blue: 0.3))
                .frame(width: s * 0.72, height: s * 0.12)
                .offset(y: s * 0.3)
        case .crown:
            Text("👑").font(.system(size: s * 0.32)).offset(y: -s * 0.48)
        }
    }
}

private struct PetFace: View {
    let expression: PetStore.Expression
    let time: TimeInterval
    let size: CGFloat

    var body: some View {
        let s = size
        let blinking = time.truncatingRemainder(dividingBy: 4.2) < 0.14
        VStack(spacing: s * 0.06) {
            HStack(spacing: s * 0.18) {
                eye(left: true, blinking: blinking)
                eye(left: false, blinking: blinking)
            }
            mouth
                .frame(width: s * 0.22, height: s * 0.1)
        }
        .overlay(alignment: .bottom) {
            if expression == .happy || expression == .celebrating {
                HStack(spacing: s * 0.4) {
                    Circle().fill(Color.pink.opacity(0.45)).frame(width: s * 0.1)
                    Circle().fill(Color.pink.opacity(0.45)).frame(width: s * 0.1)
                }
                .offset(y: -s * 0.08)
            }
        }
    }

    @ViewBuilder
    private func eye(left: Bool, blinking: Bool) -> some View {
        let s = size
        switch expression {
        case .sleeping:
            Arc(up: false).stroke(Theme.ink, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
                .frame(width: s * 0.12, height: s * 0.05)
        case .happy, .celebrating:
            Arc(up: true).stroke(Theme.ink, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                .frame(width: s * 0.12, height: s * 0.06)
        default:
            ZStack {
                Ellipse().fill(.white).frame(width: s * 0.15, height: blinking ? s * 0.02 : s * 0.18)
                if !blinking {
                    Circle().fill(Theme.ink).frame(width: s * 0.08)
                        .offset(x: expression == .focused ? 0 : sin(time * 0.7) * s * 0.02,
                                y: expression == .worried || expression == .upset ? s * 0.02 : 0)
                }
            }
            .overlay(alignment: .top) {
                if expression == .worried || expression == .upset {
                    Capsule()
                        .fill(Theme.ink)
                        .frame(width: s * 0.14, height: s * 0.035)
                        // Worried: inner ends up (pleading). Upset: inner ends down (stern).
                        .rotationEffect(.degrees((left ? 1 : -1) * (expression == .upset ? 22 : -18)))
                        .offset(y: -s * 0.07)
                }
            }
        }
    }

    @ViewBuilder
    private var mouth: some View {
        let s = size
        switch expression {
        case .celebrating:
            Ellipse().fill(Theme.ink).frame(width: s * 0.1, height: s * 0.09)
        case .happy, .idle:
            Arc(up: false).stroke(Theme.ink, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
        case .focused:
            Capsule().fill(Theme.ink).frame(width: s * 0.09, height: s * 0.035)
        case .worried, .upset:
            Arc(up: true).stroke(Theme.ink, style: StrokeStyle(lineWidth: s * 0.045, lineCap: .round))
        case .sleeping:
            Circle().fill(Theme.ink.opacity(0.7)).frame(width: s * 0.05)
        }
    }
}

/// A half-ellipse arc: `up` curves upward (∩), otherwise a smile (∪).
private struct Arc: Shape {
    let up: Bool
    func path(in rect: CGRect) -> Path {
        var path = Path()
        if up {
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY), control: CGPoint(x: rect.midX, y: rect.minY - rect.height))
        } else {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.midX, y: rect.maxY + rect.height))
        }
        return path
    }
}

/// A soft wobbling blob: a circle whose radius ripples over time.
struct BlobShape: Shape {
    let time: TimeInterval
    let amplitude: Double
    let speed: Double

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY + rect.height * 0.04)
        let radius = min(rect.width, rect.height) * 0.42
        let count = 10
        let points: [CGPoint] = (0..<count).map { index in
            let angle = Double(index) / Double(count) * 2 * .pi
            let ripple = amplitude * (sin(3 * angle + time * speed) + 0.6 * sin(2 * angle - time * speed * 1.3))
            // Slightly flatter bottom so it "sits".
            let squash = sin(angle) > 0 ? 0.92 : 1.0
            let r = radius * (1 + ripple)
            return CGPoint(x: center.x + cos(angle) * r, y: center.y + sin(angle) * r * squash)
        }
        var path = Path()
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2) }
        path.move(to: mid(points[count - 1], points[0]))
        for index in 0..<count {
            let next = points[(index + 1) % count]
            path.addQuadCurve(to: mid(points[index], next), control: points[index])
        }
        path.closeSubpath()
        return path
    }
}

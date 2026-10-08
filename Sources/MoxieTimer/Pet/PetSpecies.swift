import SwiftUI

/// Cat, dog, plant, ghost and robot. Each reuses the shared face, and shows its state through its own body
/// language (ears, leaves, antenna…) plus a coloured aura: green focused/happy, orange worried, red stern, purple asleep.
struct PetCritter: View {
    let species: PetSpecies
    let expression: PetStore.Expression
    let mood: Double
    let accessory: PetAccessory
    let time: TimeInterval
    let level: Int

    private var drifting: Bool { expression == .worried || expression == .upset }
    private var cheerful: Bool { expression == .happy || expression == .celebrating }

    private var aura: Color {
        switch expression {
        case .worried: return Color(red: 0.98, green: 0.6, blue: 0.2)
        case .upset: return Color(red: 0.9, green: 0.3, blue: 0.25)
        case .sleeping: return Color(red: 0.55, green: 0.5, blue: 0.9)
        case .happy, .celebrating: return Color(red: 0.2, green: 0.8, blue: 0.55)
        case .focused: return Color(red: 0.25, green: 0.65, blue: 0.95)
        case .idle: return .black.opacity(0.25)
        }
    }

    private var speed: Double {
        switch expression {
        case .celebrating: return 3.6
        case .happy: return 2.4
        case .upset: return 4
        case .worried: return 2
        case .sleeping: return 0.5
        default: return 1
        }
    }

    /// Accessories sit higher on pets with ears, leaves or antennas.
    private var lift: CGFloat {
        switch species {
        case .cat: return 0.08
        case .robot: return 0.1
        case .plant: return 0.14
        case .dog, .ghost, .blob: return 0.02
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let s = min(proxy.size.width, proxy.size.height)
            let bounce: Double = expression == .celebrating ? -abs(sin(time * 6)) * s * 0.1
                : (expression == .happy ? -abs(sin(time * 4)) * s * 0.05 : 0)
            let shake: Double = expression == .upset ? sin(time * 30) * s * 0.025 : 0
            let float: Double = species == .ghost ? sin(time * 1.6) * s * 0.05 : 0

            ZStack {
                if accessory == .halo {
                    Ellipse()
                        .stroke(Color(red: 1, green: 0.84, blue: 0.3), lineWidth: s * 0.05)
                        .frame(width: s * 0.5, height: s * 0.14)
                        .offset(y: -s * (0.48 + lift))
                }
                creature(s)
                    .shadow(color: aura.opacity(expression == .idle ? 0.35 : 0.6), radius: s * 0.12, y: s * 0.03)
                PetAccessoryView(accessory: accessory, size: s, lift: lift)

                if expression == .sleeping {
                    Text("z")
                        .font(.system(size: s * 0.26, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.navy.opacity(0.6))
                        .offset(x: s * 0.42, y: -s * 0.35 - time.truncatingRemainder(dividingBy: 2) * s * 0.08)
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
            .scaleEffect(x: 1 - sin(time * speed) * 0.03, y: 1 + sin(time * speed) * 0.03, anchor: .bottom)
            .offset(x: shake, y: bounce + float)
        }
    }

    @ViewBuilder
    private func creature(_ s: CGFloat) -> some View {
        switch species {
        case .cat: cat(s)
        case .dog: dog(s)
        case .plant: plant(s)
        case .ghost: ghost(s)
        case .robot: robot(s)
        case .blob: EmptyView()
        }
    }

    // MARK: Cat

    private func cat(_ s: CGFloat) -> some View {
        let fur = mood >= 40 ? Color(red: 0.98, green: 0.7, blue: 0.4) : Color(red: 0.75, green: 0.7, blue: 0.68)
        let furDark = mood >= 40 ? Color(red: 0.9, green: 0.5, blue: 0.25) : Color(red: 0.55, green: 0.5, blue: 0.5)
        // Ears flatten sideways when drifting, perk up when cheerful.
        let earAngle: Double = drifting ? 38 : (cheerful ? -6 : 8)
        let tailSwish = sin(time * (drifting ? 6 : 1.8)) * (drifting ? 22 : 12)
        return ZStack {
            Capsule()
                .fill(furDark)
                .frame(width: s * 0.1, height: s * 0.42)
                .rotationEffect(.degrees(35 + tailSwish), anchor: .bottom)
                .offset(x: s * 0.32, y: s * 0.08)
            ForEach([-1.0, 1.0], id: \.self) { side in
                ZStack {
                    Triangle().fill(fur)
                    Triangle().fill(Color.pink.opacity(0.55)).scaleEffect(0.5, anchor: .bottom)
                }
                .frame(width: s * 0.26, height: s * 0.26)
                .rotationEffect(.degrees(side * earAngle), anchor: .bottom)
                .offset(x: side * s * 0.22, y: -s * 0.3)
            }
            Ellipse()
                .fill(LinearGradient(colors: [fur, furDark], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.78, height: s * 0.68)
                .offset(y: s * 0.06)
            // Whiskers
            ForEach([-1.0, 1.0], id: \.self) { side in
                VStack(spacing: s * 0.035) {
                    ForEach(0..<2, id: \.self) { _ in
                        Capsule().fill(Theme.ink.opacity(0.35)).frame(width: s * 0.16, height: s * 0.015)
                    }
                }
                .offset(x: side * s * 0.36, y: s * 0.14)
            }
            PetFace(expression: expression, time: time, size: s * 0.95).offset(y: s * 0.06)
        }
    }

    // MARK: Dog

    private func dog(_ s: CGFloat) -> some View {
        let fur = Color(red: 0.86, green: 0.7, blue: 0.5)
        let ear = Color(red: 0.55, green: 0.38, blue: 0.25)
        let droop: Double = drifting ? 28 : (cheerful ? -12 + sin(time * 8) * 8 : 0)
        return ZStack {
            ForEach([-1.0, 1.0], id: \.self) { side in
                Ellipse()
                    .fill(ear)
                    .frame(width: s * 0.22, height: s * 0.42)
                    .rotationEffect(.degrees(side * (20 + droop)), anchor: .top)
                    .offset(x: side * s * 0.33, y: -s * 0.02)
            }
            Ellipse()
                .fill(LinearGradient(colors: [fur.opacity(0.95), fur], startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.72, height: s * 0.7)
                .offset(y: s * 0.04)
            Ellipse().fill(.white.opacity(0.75)).frame(width: s * 0.4, height: s * 0.26).offset(y: s * 0.2)
            PetFace(expression: expression, time: time, size: s * 0.9).offset(y: -s * 0.0)
            Ellipse().fill(Theme.ink).frame(width: s * 0.12, height: s * 0.08).offset(y: s * 0.12)
            if cheerful {
                Capsule()
                    .fill(Color(red: 0.95, green: 0.45, blue: 0.5))
                    .frame(width: s * 0.09, height: s * 0.12 + abs(sin(time * 8)) * s * 0.03)
                    .offset(y: s * 0.27)
            }
        }
    }

    // MARK: Plant

    private func plant(_ s: CGFloat) -> some View {
        let leafCount = min(2 + level / 2, 7)
        let healthy = Color(red: 0.3, green: 0.72, blue: 0.4)
        let wilted = Color(red: 0.72, green: 0.7, blue: 0.3)
        let leafColor = drifting ? wilted : (expression == .sleeping ? healthy.opacity(0.7) : healthy)
        let droop: Double = drifting ? (expression == .upset ? 55 : 35) : 0
        let sway = sin(time * speed) * 6
        return ZStack {
            // Stem and leaves
            Capsule().fill(leafColor).frame(width: s * 0.05, height: s * 0.34).offset(y: -s * 0.16)
            ForEach(0..<leafCount, id: \.self) { index in
                let side: Double = index % 2 == 0 ? -1 : 1
                let height = Double(index / 2) * 0.09
                Ellipse()
                    .fill(leafColor)
                    .frame(width: s * 0.24, height: s * 0.1)
                    .rotationEffect(.degrees(side * (-25 + droop) + sway), anchor: side < 0 ? .trailing : .leading)
                    .offset(x: side * s * 0.12, y: -s * (0.12 + height))
            }
            if cheerful {
                Text("🌸").font(.system(size: s * 0.26)).offset(y: -s * 0.4)
            }
            // Pot with the face
            PotShape()
                .fill(LinearGradient(colors: [Color(red: 0.88, green: 0.5, blue: 0.35), Color(red: 0.72, green: 0.35, blue: 0.25)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.62, height: s * 0.46)
                .offset(y: s * 0.24)
            Capsule().fill(Color(red: 0.62, green: 0.3, blue: 0.22)).frame(width: s * 0.7, height: s * 0.09).offset(y: s * 0.03)
            PetFace(expression: expression, time: time, size: s * 0.72, ink: .white).offset(y: s * 0.24)
        }
    }

    // MARK: Ghost

    private func ghost(_ s: CGFloat) -> some View {
        let tint: Color = drifting ? Color(red: 1, green: 0.85, blue: 0.75) : (mood >= 60 ? Color(red: 0.92, green: 0.97, blue: 1) : Color(red: 0.88, green: 0.88, blue: 0.95))
        return ZStack {
            GhostShape(time: time)
                .fill(LinearGradient(colors: [.white, tint], startPoint: .top, endPoint: .bottom))
                .overlay(GhostShape(time: time).stroke(Theme.ink.opacity(0.15), lineWidth: s * 0.02))
                .frame(width: s * 0.72, height: s * 0.82)
            PetFace(expression: expression, time: time, size: s * 0.95).offset(y: -s * 0.06)
        }
    }

    // MARK: Robot

    private func robot(_ s: CGFloat) -> some View {
        let light: Color = {
            switch expression {
            case .worried: return .orange
            case .upset: return .red
            case .sleeping: return .purple
            case .happy, .celebrating, .focused: return .green
            case .idle: return Color(red: 0.4, green: 0.75, blue: 1)
            }
        }()
        let blink = expression == .upset ? (sin(time * 12) > 0 ? 1.0 : 0.3) : 1.0
        return ZStack {
            Capsule().fill(Color(red: 0.55, green: 0.6, blue: 0.68)).frame(width: s * 0.04, height: s * 0.18).offset(y: -s * 0.38)
            Circle().fill(light).frame(width: s * 0.12).opacity(blink).offset(y: -s * 0.48)
                .shadow(color: light, radius: s * 0.08)
            RoundedRectangle(cornerRadius: s * 0.16)
                .fill(LinearGradient(colors: [Color(red: 0.78, green: 0.82, blue: 0.88), Color(red: 0.58, green: 0.63, blue: 0.72)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(width: s * 0.8, height: s * 0.64)
                .offset(y: s * 0.04)
            RoundedRectangle(cornerRadius: s * 0.1)
                .fill(Color(red: 0.12, green: 0.15, blue: 0.22))
                .frame(width: s * 0.62, height: s * 0.44)
                .offset(y: s * 0.04)
            PetFace(expression: expression, time: time, size: s * 0.85, ink: Color(red: 0.45, green: 0.95, blue: 1))
                .offset(y: s * 0.04)
            ForEach([-1.0, 1.0], id: \.self) { side in
                Capsule().fill(Color(red: 0.5, green: 0.55, blue: 0.62)).frame(width: s * 0.06, height: s * 0.2)
                    .offset(x: side * s * 0.43, y: s * 0.04)
            }
        }
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct PotShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let inset = rect.width * 0.14
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + inset, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// Round head with a wavy, moving hem.
private struct GhostShape: Shape {
    let time: TimeInterval

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.width / 2
        let hemY = rect.maxY - rect.height * 0.1
        path.move(to: CGPoint(x: rect.minX, y: hemY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(center: CGPoint(x: rect.midX, y: rect.minY + radius), radius: radius,
                    startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
        path.addLine(to: CGPoint(x: rect.maxX, y: hemY))
        let waves = 4
        let width = rect.width / CGFloat(waves)
        for index in 0..<waves {
            let x0 = rect.maxX - CGFloat(index) * width
            let lift = CGFloat(sin(time * 3 + Double(index))) * rect.height * 0.05
            path.addQuadCurve(to: CGPoint(x: x0 - width, y: hemY),
                              control: CGPoint(x: x0 - width / 2, y: hemY + rect.height * 0.12 + lift))
        }
        path.closeSubpath()
        return path
    }
}

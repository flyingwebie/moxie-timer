import SwiftUI

enum Theme {
    static let navy = Color(red: 0.157, green: 0.192, blue: 0.369)
    static let ink = Color(red: 0.10, green: 0.11, blue: 0.16)
    static let cream = Color(red: 0.969, green: 0.961, blue: 0.945)
    static let pill = Color(red: 0.925, green: 0.929, blue: 0.945)
    static let border = Color.black.opacity(0.09)
    static let muted = Color.black.opacity(0.45)
    static let faint = Color.black.opacity(0.30)
    static let danger = Color(red: 0.74, green: 0.25, blue: 0.20)
    static let running = Color(red: 0.20, green: 0.68, blue: 0.42)
    static let warmup = Color(red: 0.20, green: 0.62, blue: 0.85)
    static let onBreak = Color(red: 0.93, green: 0.55, blue: 0.20)

    static let avatarPalette: [Color] = [
        Color(red: 0.36, green: 0.45, blue: 0.80), Color(red: 0.85, green: 0.47, blue: 0.30),
        Color(red: 0.30, green: 0.62, blue: 0.55), Color(red: 0.62, green: 0.40, blue: 0.74),
        Color(red: 0.80, green: 0.36, blue: 0.48), Color(red: 0.42, green: 0.60, blue: 0.80),
    ]
}

/// Small uppercase section label: `STARTED`, `DURATION`, `TODAY`…
struct CapsLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(Theme.ink.opacity(0.8))
    }
}

/// White rounded field container used for time/duration inputs.
struct FieldBox<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.navy.opacity(isEnabled ? 1 : 0.5)))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .contentShape(Rectangle())
    }
}

struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink.opacity(0.8))
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(Capsule().fill(configuration.isPressed ? Theme.pill : .white))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
    }
}

/// Circular icon button (pause/play in the header and pill).
struct CircleIconButton: View {
    let systemName: String
    var size: CGFloat = 40
    var filled = false
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size * 0.34, weight: .bold))
                .foregroundStyle(filled ? .white : Theme.ink)
                .frame(width: size, height: size)
                .background(Circle().fill(filled ? Theme.navy : Theme.cream))
                .overlay(Circle().strokeBorder(filled ? .clear : Theme.border))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Initials badge standing in for client logos (the API doesn't expose them on clients/list).
struct ClientAvatar: View {
    let name: String
    var size: CGFloat = 30

    private var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" }).prefix(2)
        let letters = words.compactMap(\.first).map(String.init).joined()
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    private var color: Color {
        let hash = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fffffff }
        return Theme.avatarPalette[hash % Theme.avatarPalette.count]
    }

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.38, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(color))
    }
}

struct ErrorBanner: View {
    let message: String
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onDismiss {
                Button(action: onDismiss) { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.danger)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.danger.opacity(0.08)))
    }
}

extension Date {
    /// `today`, `yesterday`, or `Oct 5`
    var relativeDayName: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(self) { return "today" }
        if calendar.isDateInYesterday(self) { return "yesterday" }
        return formatted(.dateTime.month(.abbreviated).day())
    }
}

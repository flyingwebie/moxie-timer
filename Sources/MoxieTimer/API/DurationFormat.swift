import Foundation

enum DurationFormat {
    /// `2:31:44`
    static func clock(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
    }

    /// `2h 32m`, `15m`, `0m`
    static func short(_ interval: TimeInterval) -> String {
        let minutes = max(0, Int((interval / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private static let tokenRegex = try! Regex(#"(\d+(?:\.\d+)?)\s*([a-z]*)"#)

    /// Parses `45m`, `1.5h`, `1h 30m`, `1:30` (h:mm), `1:30:15`, or a bare number of minutes.
    static func parse(_ input: String) -> TimeInterval? {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: ",", with: ".")
        guard !text.isEmpty else { return nil }

        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false).map { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard parts.allSatisfy({ $0 != nil }) else { return nil }
            let values = parts.compactMap { $0 }
            switch values.count {
            case 2: return values[0] * 3600 + values[1] * 60
            case 3: return values[0] * 3600 + values[1] * 60 + values[2]
            default: return nil
            }
        }

        var total: TimeInterval = 0
        var matched = false
        for match in text.matches(of: tokenRegex) {
            guard let numberText = match.output[1].substring, let number = Double(numberText) else { continue }
            let unit = match.output[2].substring.map(String.init) ?? ""
            switch unit {
            case "h", "hr", "hrs", "hour", "hours": total += number * 3600
            case "", "m", "min", "mins", "minute", "minutes": total += number * 60
            case "s", "sec", "secs", "second", "seconds": total += number
            default: return nil
            }
            matched = true
        }
        return matched ? total : nil
    }
}

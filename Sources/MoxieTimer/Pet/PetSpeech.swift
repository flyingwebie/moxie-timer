import Foundation

/// Expression markup in pet lines, in KittenTTS 2's syntax:
/// a leading `[emotion]`, inline `<event>` beats and `(((emphasis)))`.
/// The bubble shows the line without markup; voices use it to colour the delivery.
enum PetSpeech {
    static let emotions = ["angry", "contemplative", "excited", "joyful", "mundane", "nervous", "sad", "stern", "surprised", "tender"]
    static let events = ["gasp", "giggle", "growl", "gulp", "laugh", "pause", "scoff", "sigh", "sob", "um"]

    private static let emotionPattern = try! NSRegularExpression(pattern: "\\[(\(emotions.joined(separator: "|")))\\]\\s*", options: .caseInsensitive)
    private static let eventPattern = try! NSRegularExpression(pattern: "\\s*<(\(events.joined(separator: "|")))>\\s*", options: .caseInsensitive)
    private static let emphasisPattern = try! NSRegularExpression(pattern: "\\(\\(\\((.+?)\\)\\)\\)")

    /// The line as shown in the bubble.
    static func display(_ text: String) -> String {
        var result = replace(emotionPattern, in: text, with: "")
        result = replace(eventPattern, in: result, with: " ")
        result = replace(emphasisPattern, in: result, with: "$1")
        return tidy(result)
    }

    /// Whether there's anything to say out loud (quiet-tone lines are just emoji).
    static func hasWords(_ text: String) -> Bool {
        display(text).unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }

    /// The leading emotion, if any.
    static func emotion(of text: String) -> String? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = emotionPattern.firstMatch(in: text, range: range),
              let tag = Range(match.range(at: 1), in: text) else { return nil }
        return text[tag].lowercased()
    }

    /// For voices without expression support: the line split at `<pause>` beats, with the other
    /// beats turned into sounds a normal voice can say ("ha ha!", "hmm.").
    static func plainSegments(_ text: String) -> [String] {
        var result = replace(emotionPattern, in: text, with: "")
        result = replace(emphasisPattern, in: result, with: "$1")
        let spoken: [String: String] = [
            "laugh": "ha ha!", "giggle": "hee hee!", "sigh": "hmm.", "gasp": "oh!", "um": "um,",
            "scoff": "pff.", "growl": "grr.", "gulp": "", "sob": "", "pause": "\u{1}",
        ]
        let range = NSRange(result.startIndex..., in: result)
        for match in eventPattern.matches(in: result, range: range).reversed() {
            guard let whole = Range(match.range, in: result), let tag = Range(match.range(at: 1), in: result) else { continue }
            let word = spoken[result[tag].lowercased()] ?? ""
            result.replaceSubrange(whole, with: word.isEmpty ? " " : " \(word) ")
        }
        return result.split(separator: "\u{1}").map { tidy(String($0)) }.filter { !$0.isEmpty }
    }

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ([,.!?…])", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

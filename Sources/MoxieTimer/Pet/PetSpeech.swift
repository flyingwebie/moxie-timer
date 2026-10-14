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

    /// The emotion a line gets when it arrives without one, so every line is acted out.
    static func defaultEmotion(for event: PetEvent) -> String {
        switch event {
        case .hello, .welcomeBack, .breakOver, .cameBack: return "joyful"
        case .warmupDone, .blockDone, .taskDone, .levelUp, .newPet: return "excited"
        case .focusMilestone, .checkInYes, .breakStart: return "tender"
        case .driftStart: return "surprised"
        case .driftFirm, .driftPrompt, .notTracking: return "stern"
        }
    }

    /// Makes sure a line starts with an emotion tag.
    static func withEmotion(_ text: String, default emotion: String) -> String {
        guard hasWords(text), self.emotion(of: text) == nil else { return text }
        return "[\(emotion)] \(text)"
    }

    /// Tidies a line written by AI: markdown labels like "**Angry**" or "Nervous:" become tags,
    /// (gasp) becomes <gasp>, the emotion moves to the front, and only one emoji stays.
    static func normalize(_ text: String, defaultEmotion: String?) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        line = replace(boldEmotion, in: line, with: "[$1]")
        line = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        line = replace(labelledEmotion, in: line, with: "$1[$2$3] ")
        line = replace(parenthesisedEvent, in: line, with: "<$1>")

        // KittenTTS reads one leading emotion: keep the first one found and put it in front.
        let range = NSRange(line.startIndex..., in: line)
        let found = emotionPattern.firstMatch(in: line, range: range)
            .flatMap { Range($0.range(at: 1), in: line) }
            .map { line[$0].lowercased() }
        line = replace(emotionPattern, in: line, with: "")

        var keptEmoji = false
        line = String(line.filter { character in
            guard character.isEmoji else { return true }
            defer { keptEmoji = true }
            return !keptEmoji
        })
        line = tidy(line.trimmingCharacters(in: CharacterSet(charactersIn: "\"“” ")))
        guard let emotion = found ?? defaultEmotion, hasWords(line) else { return line }
        return "[\(emotion)] \(line)"
    }

    /// The line as sent to a voice: emoji removed (Mac voices read their names out loud).
    static func spoken(_ text: String) -> String {
        tidy(String(text.filter { !$0.isEmoji }))
    }

    private static let boldEmotion = try! NSRegularExpression(
        pattern: "[*_]{1,2}\\s*(\(emotions.joined(separator: "|")))\\s*[*_]{1,2}", options: .caseInsensitive)

    /// "Nervous: Oh no…" or "(nervous) Oh no…" at the start, after any emoji.
    private static let labelledEmotion = try! NSRegularExpression(
        pattern: "^([^\\p{L}\\[(<]*)(?:[(]?(\(emotions.joined(separator: "|")))[)]?\\s*:|\\((\(emotions.joined(separator: "|")))\\))\\s*",
        options: .caseInsensitive)

    private static let parenthesisedEvent = try! NSRegularExpression(
        pattern: "(?<!\\()\\((\(events.joined(separator: "|")))\\)(?!\\))", options: .caseInsensitive)

    private static func replace(_ pattern: NSRegularExpression, in text: String, with template: String) -> String {
        pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    private static func tidy(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.replacingOccurrences(of: " ([,.!?…])", with: "$1", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    /// Pictographs like 🎉 or ⏱ (digits and # are emoji-capable too, so they need emoji presentation or a high code point).
    var isEmoji: Bool {
        guard let scalar = unicodeScalars.first, scalar.properties.isEmoji else { return false }
        return scalar.properties.isEmojiPresentation || scalar.value > 0x238C || unicodeScalars.count > 1 && scalar.value > 0x7F
    }
}

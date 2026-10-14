import Foundation

/// Expression markup in pet lines. People write one format, all in square brackets: `[joyful]` (emotion, at the start),
/// `[laugh]` (sound, anywhere) and `[stress: word]`. Internally lines use KittenTTS 2's own syntax —
/// `[emotion]`, `<event>`, `(((emphasis)))` — and `repair` converts to it.
/// The bubble shows the line without markup; voices use it to colour the delivery.
enum PetSpeech {
    static let emotions = ["angry", "contemplative", "excited", "joyful", "mundane", "nervous", "sad", "stern", "surprised", "tender"]
    static let events = ["gasp", "giggle", "growl", "gulp", "laugh", "pause", "scoff", "sigh", "sob", "um"]

    private static let emotionPattern = try! NSRegularExpression(pattern: "\\[(\(emotions.joined(separator: "|")))\\]\\s*", options: .caseInsensitive)
    private static let eventPattern = try! NSRegularExpression(pattern: "\\s*<(\(events.joined(separator: "|")))>\\s*", options: .caseInsensitive)
    private static let emphasisPattern = try! NSRegularExpression(pattern: "\\(\\(\\((.+?)\\)\\)\\)")

    /// The line as shown in the bubble.
    static func display(_ text: String) -> String {
        var result = replace(emotionPattern, in: repair(text), with: "")
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
        let text = repair(text)
        let range = NSRange(text.startIndex..., in: text)
        guard let match = emotionPattern.firstMatch(in: text, range: range),
              let tag = Range(match.range(at: 1), in: text) else { return nil }
        return text[tag].lowercased()
    }

    /// For voices without expression support: the line split at `<pause>` beats, with the other
    /// beats turned into sounds a normal voice can say ("ha ha!", "hmm.").
    static func plainSegments(_ text: String) -> [String] {
        var result = replace(emotionPattern, in: repair(text), with: "")
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
    /// Makes sure a line starts with an emotion tag: KittenTTS only reads one at the very start.
    static func withEmotion(_ text: String, default emotion: String) -> String {
        guard hasWords(text) else { return text }
        let repaired = repair(text)
        let found = self.emotion(of: repaired)
        let body = tidy(replace(emotionPattern, in: repaired, with: ""))
        return "[\(found ?? emotion)] \(body)"
    }

    /// Tidies a line written by AI: markdown labels like "**Angry**" or "Nervous:" become tags,
    /// (gasp) becomes <gasp>, the emotion moves to the front, and only one emoji stays.
    static func normalize(_ text: String, defaultEmotion: String?) -> String {
        var line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'"))
        line = replace(boldEmotion, in: line, with: "[$1]")
        line = repair(line)
        line = line.replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
        line = replace(labelledEmotion, in: line, with: "$1[$2$3] ")
        line = repair(line)

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
        tidy(String(repair(text).filter { !$0.isEmoji }))
    }

    /// Fixes tags in the wrong brackets, as people type them: [laugh], (laugh) or *laugh* → <laugh>,
    /// and <excited> → [excited]. Otherwise the voice reads the word out loud.
    static func repair(_ text: String) -> String {
        var result = replace(stressTag, in: text, with: "((($1)))")
        result = replace(misbracketedEvent, in: result, with: "<$1>")
        result = replace(parenthesisedEvent, in: result, with: "<$1>")
        return replace(misbracketedEmotion, in: result, with: "[$1]")
    }

    /// The format people write, for examples and the AI prompts.
    static let tagFormatHelp = """
    All tags go in square brackets. Emotion, once at the start: \(emotions.map { "[\($0)]" }.joined(separator: " ")). \
    Sound, anywhere: \(events.map { "[\($0)]" }.joined(separator: " ")). Stress one word: [stress: word].
    """

    /// Starts a line with a call to get the user's attention ("David, listen up!"), keeping its emotion in front.
    /// A name the line already opens with is dropped, so it isn't said twice.
    static func calling(_ text: String, name: String, word: String) -> String {
        let name = name.trimmingCharacters(in: .whitespaces)
        let word = word.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "!.,"))
        guard hasWords(text), !(name.isEmpty && word.isEmpty) else { return text }
        let repaired = repair(text)
        let emotion = self.emotion(of: repaired)
        var body = tidy(replace(emotionPattern, in: repaired, with: ""))
        if !name.isEmpty {
            let leadingName = try! NSRegularExpression(
                pattern: "^((?:<\\w+>\\s*)*)\(NSRegularExpression.escapedPattern(for: name))\\b[\\s,!.:;—-]*", options: .caseInsensitive)
            body = replace(leadingName, in: body, with: "$1")
            // Capitalise the first word after any leading sounds ("<scoff> back to…" → "<scoff> Back to…").
            let tags = try! NSRegularExpression(pattern: "^(?:\\s*<\\w+>)*\\s*")
            let skip = tags.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)).flatMap { Range($0.range, in: body) }
            let start = skip?.upperBound ?? body.startIndex
            if start < body.endIndex, body[start].isLetter {
                body.replaceSubrange(start...start, with: body[start].uppercased())
            }
        }
        var call = [name, word].filter { !$0.isEmpty }.joined(separator: ", ")
        call = call.prefix(1).uppercased() + call.dropFirst() + "!"
        return [emotion.map { "[\($0)]" }, call, body].compactMap { $0 }.joined(separator: " ")
    }

    private static let stressTag = try! NSRegularExpression(pattern: "\\[\\s*(?:stress|emphasis)\\s*:\\s*([^\\]]+?)\\s*\\]", options: .caseInsensitive)

    private static let misbracketedEvent = try! NSRegularExpression(
        pattern: "(?:\\[|\\*)(\(events.joined(separator: "|")))(?:\\]|\\*)", options: .caseInsensitive)

    private static let misbracketedEmotion = try! NSRegularExpression(
        pattern: "<(\(emotions.joined(separator: "|")))>", options: .caseInsensitive)

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

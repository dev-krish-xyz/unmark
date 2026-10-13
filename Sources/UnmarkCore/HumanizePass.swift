import Foundation

/// Deterministic cleanup applied after a "Natural" reword.
///
/// Port of watermarks-remover's `humanize_pass.py`: only edits that are always correct without
/// reading the text. Straight quotes, no em/en dashes or prose double hyphens, a few filler
/// phrase collapses and the `utilize` → `use` swap. Anything that needs judgment stays in the
/// rewrite prompt.
public enum HumanizePass {
    public static func apply(_ text: String) -> String {
        var text = straightenQuotes(text)
        text = replaceDashes(text)
        text = collapsePhrases(text)
        return swapWords(text)
    }

    private static let phraseSwaps: [(NSRegularExpression, String)] = [
        ("in order to", "to"),
        ("due to the fact that", "because"),
        ("at this point in time", "now"),
        ("in the event that", "if"),
        ("has the ability to", "can"),
        ("have the ability to", "can"),
        ("it is important to note that", "note that"),
        ("it is worth noting that", "note that"),
        ("delve into", "explore"),
        ("delves into", "explores"),
        ("delved into", "explored"),
        ("delving into", "exploring"),
    ].map { phrase, replacement in
        (regex("\\b\(phrase)\\b", options: .caseInsensitive), replacement)
    }

    private static let wordSwaps = ["utilize": "use", "utilizes": "uses", "utilized": "used", "utilizing": "using"]
    private static let wordPattern = regex("\\b(?:utilize|utilizes|utilized|utilizing)\\b", options: .caseInsensitive)
    private static let dashPattern = regex("\\s*[\\u2014\\u2013]\\s*")
    private static let doubleHyphenPattern = regex("(\\s*)--(\\s*)")
    private static let doubleCommaPattern = regex(",\\s*,\\s*")
    private static let commaBeforeStopPattern = regex("\\s*,\\s*([.!?])")

    static func straightenQuotes(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
    }

    static func replaceDashes(_ text: String) -> String {
        let source = text as NSString
        var result = substitute(dashPattern, in: text) { match in
            // Both neighbors beyond the matched spaces are digits: a numeric range, kept.
            let left = match.range.location > 0 ? source.character(at: match.range.location - 1) : 0
            let right = NSMaxRange(match.range) < source.length ? source.character(at: NSMaxRange(match.range)) : 0
            if isDigit(left) && isDigit(right) { return nil }
            return ", "
        }
        let afterDashes = result as NSString
        result = substitute(doubleHyphenPattern, in: result) { match in
            let start = match.range(at: 1).upperBound
            let end = match.range(at: 2).location
            let before = start > 0 ? afterDashes.character(at: start - 1) : 0
            let after = end < afterDashes.length ? afterDashes.character(at: end) : 0
            // `--word` after a delimiter is a command-line option, not a dash.
            if isAlphanumeric(after) && !isAlphanumeric(before) { return nil }
            return ", "
        }
        result = doubleCommaPattern.stringByReplacingMatches(
            in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: ", ")
        return commaBeforeStopPattern.stringByReplacingMatches(
            in: result, range: NSRange(location: 0, length: (result as NSString).length), withTemplate: "$1")
    }

    static func collapsePhrases(_ text: String) -> String {
        phraseSwaps.reduce(text) { text, swap in
            substitute(swap.0, in: text) { match in
                capitalize(like: (text as NSString).substring(with: match.range), swap.1)
            }
        }
    }

    static func swapWords(_ text: String) -> String {
        substitute(wordPattern, in: text) { match in
            let word = (text as NSString).substring(with: match.range)
            return wordSwaps[word.lowercased()].map { capitalize(like: word, $0) }
        }
    }

    // MARK: Helpers

    private static func regex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are literals; a failure here is a programming error.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Replaces each match with the closure's result; nil keeps the match unchanged.
    private static func substitute(
        _ regex: NSRegularExpression, in text: String, _ replacement: (NSTextCheckingResult) -> String?
    ) -> String {
        let source = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            guard let value = replacement(match) else { continue }
            result += source.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            result += value
            cursor = NSMaxRange(match.range)
        }
        return result + source.substring(from: cursor)
    }

    private static func capitalize(like matched: String, _ replacement: String) -> String {
        if matched == matched.uppercased() && matched != matched.lowercased() { return replacement.uppercased() }
        guard let first = matched.first, first.isUppercase else { return replacement }
        return replacement.prefix(1).uppercased() + replacement.dropFirst()
    }

    private static func isDigit(_ unit: unichar) -> Bool { (0x30...0x39).contains(unit) }

    private static func isAlphanumeric(_ unit: unichar) -> Bool {
        guard unit != 0, let scalar = Unicode.Scalar(unit) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }
}

import Foundation

/// Category of a removed or replaced code point.
public enum MarkKind: String, Sendable, CaseIterable {
    case zeroWidth, bidi, tagCharacter, variationSelector, noncharacter,
         reservedIgnorable, privateUse, otherFormat, invisible, space, confusable
}

public struct CleaningOptions: Sendable, Equatable {
    /// Rewrite exotic spaces (NBSP, narrow NBSP, em space, ...) to U+0020.
    public var normalizeSpaces = true
    /// Keep U+00A0 even when normalizing spaces. Used for HTML, where NBSP is layout.
    public var keepNoBreakSpace = false
    /// Also strip legitimate RTL/LTR marks, isolates and paired embeddings.
    public var stripBidi = false
    /// Paranoid: strip load-bearing invisibles too (emoji glue, script joiners, flag tags, ...).
    public var stripLoadBearing = false
    /// Map Cyrillic/fullwidth Latin lookalikes to ASCII Latin.
    public var aggressiveHomoglyphs = false
    /// Strip Private Use Area code points. Off by default: the Apple logo (U+F8FF),
    /// SF Symbols and Nerd Font glyphs live there.
    public var stripPrivateUse = false

    public init() {}
}

/// One change to the input, addressed in UTF-16 units so it applies to `NSAttributedString` too.
public struct CleaningEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    public var kind: MarkKind
    public var scalar: UInt32
}

public struct CleaningResult: Sendable, Equatable {
    public var text: String
    public var edits: [CleaningEdit]

    public var changed: Bool { !edits.isEmpty }
    public var removedCount: Int { edits.lazy.filter { $0.replacement.isEmpty }.count }
    public var replacedCount: Int { edits.count - removedCount }
}

/// Deterministic remover for invisible Unicode carriers and space homoglyphs.
///
/// Behavior follows watermarks-remover's `text_unicode.clean_text` (Layer A), operating on
/// Unicode scalars exactly as the Python original operates on code points, with two deliberate
/// differences: Private Use Area is preserved by default, and left-hand context is taken only
/// from characters that survive, which makes cleaning idempotent.
public enum TextCleaner {
    public static func clean(_ text: String, options: CleaningOptions = CleaningOptions()) -> CleaningResult {
        let edits = edits(in: text, options: options)
        return CleaningResult(text: apply(edits, to: text), edits: edits)
    }

    public static func edits(in text: String, options: CleaningOptions = CleaningOptions()) -> [CleaningEdit] {
        let scalars = Array(text.unicodeScalars)
        guard scalars.contains(where: { isCandidate($0.value) }) else { return [] }

        let validFlagTags = validFlagTagIndices(scalars)
        let validEmbeddings = validBidiEmbeddingIndices(scalars)
        var edits: [CleaningEdit] = []
        var prevKept: Unicode.Scalar?
        var previousSurvived = false
        var offset = 0

        for (index, scalar) in scalars.enumerated() {
            let width = scalar.utf16.count
            defer { offset += width }
            if !isCandidate(scalar.value) {
                prevKept = scalar
                previousSurvived = true
                continue
            }
            let prev = index > 0 && previousSurvived ? scalars[index - 1] : nil
            let next = index + 1 < scalars.count ? scalars[index + 1] : nil
            let decision = decide(
                scalar, prevKept: prevKept, prev: prev, next: next,
                validFlagTag: validFlagTags.contains(index),
                validEmbedding: validEmbeddings.contains(index),
                options: options
            )
            switch decision {
            case .keep:
                if !UnicodeTables.isGlue(scalar.value) { prevKept = scalar }
                previousSurvived = true
            case let .replace(with, kind):
                edits.append(CleaningEdit(range: NSRange(location: offset, length: width),
                                          replacement: String(with), kind: kind, scalar: scalar.value))
                prevKept = with.unicodeScalars.first
                previousSurvived = true
            case let .strip(kind):
                edits.append(CleaningEdit(range: NSRange(location: offset, length: width),
                                          replacement: "", kind: kind, scalar: scalar.value))
                previousSurvived = false
            }
        }
        return edits
    }

    /// Applies edits produced for `text` (or for an attributed string with the same characters).
    public static func apply(_ edits: [CleaningEdit], to text: String) -> String {
        guard !edits.isEmpty else { return text }
        let source = text as NSString
        var result = ""
        result.reserveCapacity(source.length)
        var cursor = 0
        for edit in edits {
            result += source.substring(with: NSRange(location: cursor, length: edit.range.location - cursor))
            result += edit.replacement
            cursor = NSMaxRange(edit.range)
        }
        result += source.substring(from: cursor)
        return result
    }

    public static func apply(_ edits: [CleaningEdit], to text: NSMutableAttributedString) {
        for edit in edits.reversed() {
            text.replaceCharacters(in: edit.range, with: edit.replacement)
        }
    }

    // MARK: - Decision

    private enum Decision {
        case keep
        case replace(Character, MarkKind)
        case strip(MarkKind)
    }

    private static func decide(
        _ scalar: Unicode.Scalar,
        prevKept: Unicode.Scalar?,
        prev: Unicode.Scalar?,
        next: Unicode.Scalar?,
        validFlagTag: Bool,
        validEmbedding: Bool,
        options: CleaningOptions
    ) -> Decision {
        let cp = scalar.value
        let T = UnicodeTables.self

        if !options.stripBidi && (validEmbedding || T.preservableBidi.contains(cp)) {
            return .keep
        }
        if !options.stripLoadBearing {
            if let prev {
                let p = prev.value
                if T.variationSelectorSupplement.contains(cp) && T.isCJKIdeograph(p) { return .keep }
                if T.mongolianFVS.contains(cp) && T.isMongolianBlock(p) { return .keep }
                if (0xFE00...0xFE0D).contains(cp) && T.isCJKIdeograph(p) { return .keep }
            }
            if (cp == 0xFE0E || cp == 0xFE0F), let prev, T.isEmojiBase(prev.value) {
                return .keep
            }
            if cp == 0x200D, let prevKept, let next, T.isEmojiBase(prevKept.value), T.isEmojiBase(next.value) {
                return .keep
            }
            if T.scriptJoiners.contains(cp), let prev, let next,
               let script = T.joiningScript(prev), script == T.joiningScript(next) {
                return .keep
            }
            if T.flagTags.contains(cp) && validFlagTag { return .keep }
            if let prevKept {
                if T.mongolianFVS.contains(cp) && T.isMongolianBlock(prevKept.value) && T.isLetter(prevKept) { return .keep }
                if T.khmerVowels.contains(cp) && (0x1780...0x17FF).contains(prevKept.value) && T.isLetter(prevKept) { return .keep }
                if T.hangulFillers.contains(cp) && T.isHangulJamo(prevKept.value) { return .keep }
            }
            if T.orthographicFormat.contains(cp) { return .keep }
            if let layout = T.layoutControls.first(where: { $0.controls.contains(cp) }),
               (prev.map { layout.script.contains($0.value) } ?? false)
                || (next.map { layout.script.contains($0.value) } ?? false) {
                return .keep
            }
        }
        if let kind = stripKind(cp, options: options) {
            return .strip(kind)
        }
        if options.normalizeSpaces && T.spaceHomoglyphs.contains(cp) && !(options.keepNoBreakSpace && cp == 0x00A0) {
            return .replace(" ", .space)
        }
        if options.aggressiveHomoglyphs, let latin = T.latinConfusables[cp] {
            return .replace(latin, .confusable)
        }
        if scalar.properties.generalCategory == .format && !T.spaceHomoglyphs.contains(cp) {
            return .strip(.otherFormat)
        }
        return .keep
    }

    private static func stripKind(_ cp: UInt32, options: CleaningOptions) -> MarkKind? {
        let T = UnicodeTables.self
        if T.tagCharacters.contains(cp) { return .tagCharacter }
        if T.isNoncharacter(cp) { return .noncharacter }
        if T.isReservedIgnorable(cp) { return .reservedIgnorable }
        if T.isPrivateUse(cp) { return options.stripPrivateUse ? .privateUse : nil }
        guard T.strip.contains(cp) || T.variationSelectorSupplement.contains(cp) else { return nil }
        if T.isVariationSelector(cp) { return .variationSelector }
        if T.bidi.contains(cp) { return .bidi }
        if T.zeroWidthFamily.contains(cp) { return .zeroWidth }
        return .invisible
    }

    /// Cheap prefilter: false means the scalar is kept under every option set and is not glue.
    private static func isCandidate(_ cp: UInt32) -> Bool {
        if cp < 0xA0 { return false }
        if (0x4E00...0x9FFF).contains(cp) || (0xAC00...0xD7A3).contains(cp) { return false }
        return true
    }

    // MARK: - Sequence context

    /// Indices of tag characters in complete subdivision-flag sequences (🏴 + tags + U+E007F).
    private static func validFlagTagIndices(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        var valid = Set<Int>()
        var i = 0
        while i < scalars.count {
            guard scalars[i].value == 0x1F3F4 else { i += 1; continue }
            var j = i + 1
            while j < scalars.count, (0xE0020...0xE007E).contains(scalars[j].value) { j += 1 }
            if j > i + 1, j < scalars.count, scalars[j].value == 0xE007F {
                valid.formUnion(i + 1...j)
                i = j + 1
            } else {
                i += 1
            }
        }
        return valid
    }

    /// Indices of complete LRE/RLE ... PDF pairs. Overrides are never preserved.
    private static func validBidiEmbeddingIndices(_ scalars: [Unicode.Scalar]) -> Set<Int> {
        var valid = Set<Int>()
        var stack: [(cp: UInt32, index: Int)] = []
        for (index, scalar) in scalars.enumerated() {
            switch scalar.value {
            case 0x202A, 0x202B, 0x202D, 0x202E:
                stack.append((scalar.value, index))
            case 0x202C:
                guard let opener = stack.popLast() else { continue }
                if opener.cp == 0x202A || opener.cp == 0x202B {
                    valid.insert(opener.index)
                    valid.insert(index)
                }
            default:
                break
            }
        }
        return valid
    }
}

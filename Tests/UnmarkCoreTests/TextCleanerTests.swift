import AppKit
import Testing
@testable import UnmarkCore

/// Swift `String ==` uses canonical equivalence; cleaning must be compared code point by code point.
private func scalars(_ text: String) -> [UInt32] { text.unicodeScalars.map(\.value) }

private func clean(_ text: String, _ configure: (inout CleaningOptions) -> Void = { _ in }) -> CleaningResult {
    var options = CleaningOptions()
    configure(&options)
    return TextCleaner.clean(text, options: options)
}

private func expectClean(_ raw: String, _ expected: String, removed: Int? = nil,
                         sourceLocation: SourceLocation = #_sourceLocation,
                         _ configure: (inout CleaningOptions) -> Void = { _ in }) {
    let result = clean(raw, configure)
    #expect(scalars(result.text) == scalars(expected), sourceLocation: sourceLocation)
    if let removed {
        #expect(result.removedCount == removed, sourceLocation: sourceLocation)
    }
}

private func expectUnchanged(_ raw: String, sourceLocation: SourceLocation = #_sourceLocation) {
    let result = clean(raw)
    #expect(!result.changed, "\(raw.unicodeScalars.map { String($0.value, radix: 16) })", sourceLocation: sourceLocation)
    #expect(scalars(result.text) == scalars(raw), sourceLocation: sourceLocation)
}

private func string(_ codePoints: UInt32...) -> String {
    String(String.UnicodeScalarView(codePoints.map { Unicode.Scalar($0)! }))
}

// MARK: - Reference vectors (watermarks-remover tests/test_clean_text.py)

@Suite struct ReferenceVectors {
    @Test func stripsZeroWidthAndSoftHyphen() {
        expectClean("Hello\u{200B}World\u{00AD}!", "HelloWorld!", removed: 2)
    }

    @Test func normalizesExoticSpaces() {
        let result = clean("a\u{2003}b\u{3000}c")
        #expect(scalars(result.text) == scalars("a b c"))
        #expect(result.replacedCount == 2)
    }

    @Test func tagCharacters() {
        let result = clean("hi\u{E0041}there")
        #expect(result.text == "hithere")
        #expect(result.edits.map(\.kind) == [.tagCharacter])
    }

    @Test func stripsOverride() {
        expectClean("ab\u{202E}ef", "abef")
        expectClean("abc\u{202E}def\u{202C}", "abcdef", removed: 2)
    }

    @Test func preservesBidiMarksAndIsolatesByDefault() {
        let raw = "السعر \u{2066}123 USD\u{2069}\u{200F}"
        expectUnchanged(raw)
        expectClean(raw, "السعر 123 USD") { $0.stripBidi = true }
    }

    @Test func preservesPairedEmbeddings() {
        let raw = "English \u{202B}العربية\u{202C} end"
        expectUnchanged(raw)
        expectClean(raw, "English العربية end") { $0.stripBidi = true }
    }

    @Test func stripsOrphanedEmbeddingControls() {
        expectClean("abc\u{202C}", "abc")
        expectClean("abc\u{202B}def", "abcdef")
    }

    @Test func preservesNormalText() {
        expectUnchanged("Normal ASCII and café — fine.")
    }

    @Test func aggressiveConfusables() {
        expectClean("p\u{0430}y", "pay") { $0.aggressiveHomoglyphs = true }
        expectUnchanged("p\u{0430}y")
    }

    @Test func preservesEmojiPresentationSelectors() {
        expectUnchanged("Balance returns. \u{2696}\u{FE0F}")
        expectUnchanged("Move \u{2194}\u{FE0F}")
        for base in ["\u{203C}", "\u{2049}", "\u{2139}", "\u{2934}", "\u{2935}"] {
            expectUnchanged("note \(base)\u{FE0F} end")
        }
        expectUnchanged("\u{2139}\u{FE0F}\u{200D}\u{1F4A1}")
    }

    @Test func cjkIdeographicVariationSelectors() {
        expectUnchanged("\u{845B}\u{E0100}")
        expectClean("\u{845B}\u{E0100}\u{E0101}", "\u{845B}\u{E0100}", removed: 1)
    }

    @Test func emojiZWJSequences() {
        expectUnchanged("Family time: \u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}")
        expectUnchanged("\u{2764}\u{FE0F}\u{200D}\u{1F525}")
    }

    @Test func stripsFloatingEmojiGlue() {
        expectClean("a\u{200D}b\u{FE0F}", "ab", removed: 2)
    }

    @Test func paranoidModeStripsGlue() {
        expectClean("\u{2696}\u{FE0F}", "\u{2696}", removed: 1) { $0.stripLoadBearing = true }
        let persian = "\u{0645}\u{06CC}\u{200C}\u{0631}"
        #expect(!clean(persian) { $0.stripLoadBearing = true }.text.unicodeScalars.contains("\u{200C}"))
        expectClean("x\u{0600}y", "xy") { $0.stripLoadBearing = true }
        for raw in ["\u{1820}\u{180B}\u{1821}", "\u{1780}\u{17B4}\u{1781}", "\u{1100}\u{115F}\u{1161}",
                    "\u{13079}\u{13430}\u{130A7}"] {
            #expect(clean(raw) { $0.stripLoadBearing = true }.removedCount == 1)
        }
    }

    @Test func preservesScriptJoiners() {
        expectUnchanged("\u{0645}\u{06CC}\u{200C}\u{0631}\u{0648}\u{0645}") // Persian mi-ravam
        expectUnchanged("\u{0915}\u{094D}\u{200D}\u{0937}")                // Devanagari conjunct
    }

    @Test func stripsJoinersOutsideTheirScript() {
        expectClean("\u{845B}\u{200C}A", "\u{845B}A", removed: 1)
        for raw in ["a\u{200D}b", "a\u{200C}b", "ab\u{200C}"] {
            #expect(clean(raw).removedCount == 1)
        }
    }

    @Test func flagTagSequences() {
        expectUnchanged("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}")
        expectClean("\u{1F3F4}\u{E0067}\u{E0062}", "\u{1F3F4}", removed: 2)
    }

    @Test func preservesOrthographicArabicFormat() {
        expectUnchanged("x\u{0600}y\u{06DD}z")
    }

    @Test func mongolianVariationSelectors() {
        expectUnchanged("\u{1820}\u{180B}")
        for raw in ["\u{1820}\u{180B}\u{1821}", "\u{1820}\u{180C}\u{1821}", "\u{1820}\u{180D}\u{1821}",
                    "\u{1820}\u{180B}\u{180C}\u{1821}", "\u{1820}\u{180F}\u{1821}"] {
            expectUnchanged(raw)
        }
    }

    @Test func stripsMissedDefaultIgnorableCarriers() {
        for cp: UInt32 in [0x180F, 0x3164, 0xFFA0] {
            expectClean("word" + string(cp) + "word", "wordword", removed: 1)
        }
    }

    @Test func reservedDefaultIgnorables() {
        var codePoints: [UInt32] = [0x2065, 0xE0000]
        codePoints += Array(UInt32(0xFFF0)...UInt32(0xFFF8))
        codePoints += Array(UInt32(0xE0080)...UInt32(0xE00FF))
        codePoints += Array(UInt32(0xE01F0)...UInt32(0xE0FFF))
        for cp in codePoints {
            let result = clean("word" + string(cp) + "word")
            #expect(result.text == "wordword", "U+\(String(cp, radix: 16))")
            #expect(result.edits.map(\.kind) == [.reservedIgnorable], "U+\(String(cp, radix: 16))")
        }
        for cp: UInt32 in [0x2064, 0xFFF9, 0xE0001, 0xE0100] {
            #expect(!clean("word" + string(cp) + "word").edits.contains { $0.kind == .reservedIgnorable })
        }
    }

    @Test func khmerInherentVowels() {
        expectUnchanged("\u{1780}\u{17B4}\u{1781}")
        expectUnchanged("\u{1780}\u{17B5}\u{1781}")
    }

    @Test func hangulFillers() {
        for raw in ["\u{1100}\u{115F}\u{1161}", "\u{1100}\u{1160}\u{1161}",
                    "\u{3131}\u{3164}\u{314F}", "\u{FFA1}\u{FFA0}\u{FFC2}"] {
            expectUnchanged(raw)
        }
        for raw in ["a\u{3164}b", "a\u{FFA0}b", "\u{3164}", "\u{FFA0}"] {
            #expect(clean(raw).removedCount == 1)
        }
    }

    @Test func stripsFloatingScriptGlue() {
        expectClean("a\u{180B}b", "ab")
        expectClean("a\u{17B4}b", "ab")
        expectClean("a\u{115F}b", "ab")
        expectClean("\u{180B}", "")
        expectClean("\u{1160}", "")
    }

    @Test func noncharacters() {
        var codePoints = Array(UInt32(0xFDD0)...UInt32(0xFDEF))
        for plane in UInt32(0)...UInt32(0x10) {
            codePoints.append(plane << 16 | 0xFFFE)
            codePoints.append(plane << 16 | 0xFFFF)
        }
        #expect(codePoints.count == 66)
        for cp in codePoints {
            let result = clean("word" + string(cp) + "word")
            #expect(result.text == "wordword", "U+\(String(cp, radix: 16))")
            #expect(result.edits.map(\.kind) == [.noncharacter])
        }
        expectUnchanged("word\u{FDF0}word")
        expectUnchanged("word\u{FFFD}word")
    }

    @Test func layoutFormatControlsInContext() {
        expectUnchanged("\u{13079}\u{13430}\u{130A7}")
        expectUnchanged("\u{13437}\u{13079}\u{130A7}\u{13438}")
        expectUnchanged("\u{1BC02}\u{1BCA0}\u{1BC03}")
        expectUnchanged("\u{1BC02}\u{1BCA3}")
        expectUnchanged("\u{1D158}\u{1D165}\u{1D173}\u{1D158}\u{1D165}\u{1D174}")
    }

    @Test func floatingLayoutFormatControls() {
        for cp: UInt32 in [0x13430, 0x13438, 0x1BCA0, 0x1BCA3, 0x1D173, 0x1D17A] {
            expectClean("word" + string(cp) + "word", "wordword", removed: 1)
        }
    }
}

// MARK: - Unmark-specific behavior

@Suite struct CleanerBehavior {
    @Test func emptyInput() {
        let result = clean("")
        #expect(result.text.isEmpty && !result.changed)
    }

    @Test func onlyInvisibles() {
        expectClean("\u{200B}\u{200B}\u{FEFF}", "", removed: 3)
    }

    @Test func narrowNoBreakSpaceFromModelOutput() {
        expectClean("It\u{202F}is\u{202F}done.", "It is done.")
    }

    @Test func spacesCanBeLeftAlone() {
        expectClean("a\u{00A0}b\u{200B}", "a\u{00A0}b") { $0.normalizeSpaces = false }
        expectClean("a\u{00A0}b\u{2009}c", "a\u{00A0}b c") { $0.keepNoBreakSpace = true }
    }

    @Test func preservesPrivateUseByDefault() {
        expectUnchanged("\u{F8FF} Apple, \u{E0B0} powerline, \u{100000} SF Symbol")
        expectClean("a\u{E000}b\u{F0000}c\u{10FFFD}", "abc", removed: 3) { $0.stripPrivateUse = true }
    }

    @Test func multilingualTextIsUntouched() {
        let samples = [
            "The quick brown fox jumps over the lazy dog.",
            "Ça va? Größe, naïve, Ærøskøbing, İstanbul, ½ ⅔ ™",
            "Привет, как дела? Ελληνικά κείμενα.",
            "مرحبا بالعالم، هذا نص عربي.",
            "שלום עולם, זה טקסט בעברית.",
            "नमस्ते दुनिया, यह हिंदी पाठ है। क्षत्रिय",
            "সবাইকে শুভেচ্ছা। தமிழ் உரை. ಕನ್ನಡ",
            "你好，世界！这是中文文本。",
            "こんにちは世界。カタカナとひらがな。",
            "안녕하세요 세계. 한국어 텍스트입니다.",
            "สวัสดีชาวโลก นี่คือข้อความภาษาไทย",
            "Emoji: 👍🏽 🇯🇵 🏳️‍🌈 👩‍💻 ❤️ 1️⃣ #️⃣ ©️",
            "Code: let x = \"\\u200B\"; // escaped, not literal\n\tindented\r\n",
            "Combining: e\u{0301} a\u{0308} Z\u{0335}\u{0321}",
        ]
        for sample in samples { expectUnchanged(sample) }
    }

    @Test func editsAddressUTF16() {
        let raw = "😀\u{200B}x\u{E0041}"
        let edits = TextCleaner.edits(in: raw)
        #expect(edits.map(\.range) == [NSRange(location: 2, length: 1), NSRange(location: 4, length: 2)])
    }

    @Test func attributedStringKeepsAttributes() {
        let text = NSMutableAttributedString(string: "Bold\u{200B}text", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        text.addAttribute(.link, value: URL(string: "https://example.com")!, range: NSRange(location: 5, length: 4))
        let edits = TextCleaner.edits(in: text.string)
        TextCleaner.apply(edits, to: text)
        #expect(text.string == "Boldtext")
        #expect(text.attribute(.link, at: 4, effectiveRange: nil) != nil)
        #expect((text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func repeatedCleaningIsStable() {
        let inputs = [
            "Hello\u{200B}world\u{00AD}with\u{200B}marks and\u{3000}spaces.",
            "a\u{180E}\u{180B}", "a\u{17B4}\u{200C}\u{1780}", "\u{2696}\u{200B}\u{FE0F}",
            "\u{1F468}\u{200D}\u{200D}\u{1F469}", "\u{202A}\u{202E}x\u{202C}",
        ]
        for input in inputs {
            let once = clean(input).text
            let twice = clean(once)
            #expect(!twice.changed, "\(input.unicodeScalars.map { String($0.value, radix: 16) })")
        }
    }

    /// Random soup of the code points the rules care about; cleaning must reach a fixed point in one pass.
    @Test func idempotentOnRandomInput() {
        let pool: [UInt32] = [
            0x61, 0x20, 0x845B, 0x1820, 0x1780, 0x1100, 0x3131, 0xFFA1, 0x0645, 0x0915, 0x094D,
            0x1F468, 0x2764, 0x2696, 0x1F3F4, 0x13079, 0x1BC02, 0x1D158, 0x0600,
            0x200B, 0x200C, 0x200D, 0xFE0F, 0xFE0E, 0xFE00, 0xE0100, 0x180B, 0x180E, 0x180F,
            0x17B4, 0x115F, 0x3164, 0xFFA0, 0xE0067, 0xE007F, 0xE0041, 0x202A, 0x202B,
            0x202C, 0x202E, 0x200F, 0x2066, 0x2069, 0x13430, 0x1BCA0, 0x1D173, 0x00A0, 0x202F,
            0x00AD, 0xFEFF, 0xFDD0, 0xE000,
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<5_000 {
            let length = Int.random(in: 0...12, using: &generator)
            let input = String(String.UnicodeScalarView((0..<length).map { _ in
                Unicode.Scalar(pool.randomElement(using: &generator)!)!
            }))
            for configure: (inout CleaningOptions) -> Void in [{ _ in }, { $0.stripBidi = true }, { $0.stripLoadBearing = true }] {
                let once = clean(input, configure).text
                let again = clean(once, configure)
                #expect(!again.changed, "not idempotent: \(input.unicodeScalars.map { String($0.value, radix: 16) })")
            }
        }
    }

    @Test func largeInputPerformance() {
        let paragraph = String(repeating: "Lorem ipsum dolor sit amet, consectetur\u{200B} adipiscing elit. ", count: 20_000)
        let clock = ContinuousClock()
        let elapsed = clock.measure { _ = TextCleaner.clean(paragraph) }
        #expect(clean(paragraph).removedCount == 20_000)
        // Guards against non-linear behavior; generous because tests run unoptimized on shared CI.
        #expect(elapsed < .seconds(5))
    }
}

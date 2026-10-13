// Code point tables ported from watermarks-remover `service/scripts/text_unicode.py`
// (MIT, Copyright (c) 2026 Guillaume Meyer and contributors). See THIRD_PARTY_NOTICES.md.

enum UnicodeTables {
    /// Format / invisible controls commonly used for steganography or broken pastes.
    static let strip: Set<UInt32> = [
        0x00AD,                 // soft hyphen
        0x034F,                 // combining grapheme joiner
        0x061C,                 // Arabic letter mark
        0x115F, 0x1160,         // Hangul choseong / jungseong filler
        0x17B4, 0x17B5,         // Khmer inherent vowels
        0x180B, 0x180C, 0x180D, // Mongolian free variation selectors 1-3
        0x180E,                 // Mongolian vowel separator
        0x180F,                 // Mongolian free variation selector 4
        0x200B, 0x200C, 0x200D, // zero width space / non-joiner / joiner
        0x200E, 0x200F,         // LRM, RLM
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E, // LRE, RLE, PDF, LRO, RLO
        0x2060, 0x2061, 0x2062, 0x2063, 0x2064, // word joiner, invisible operators
        0x2066, 0x2067, 0x2068, 0x2069,         // LRI, RLI, FSI, PDI
        0x206A, 0x206B, 0x206C, 0x206D, 0x206E, 0x206F, // deprecated format controls
        0xFEFF,                 // BOM / ZWNBSP
        0xFE00, 0xFE01, 0xFE02, 0xFE03, 0xFE04, 0xFE05, 0xFE06, 0xFE07,
        0xFE08, 0xFE09, 0xFE0A, 0xFE0B, 0xFE0C, 0xFE0D, 0xFE0E, 0xFE0F, // VS1-VS16
        0x3164,                 // Hangul filler
        0xFFA0,                 // halfwidth Hangul filler
        0xFFF9, 0xFFFA, 0xFFFB, // interlinear annotation
    ]

    /// Spaces that look like (or substitute for) U+0020.
    static let spaceHomoglyphs: Set<UInt32> = [
        0x00A0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003, 0x2004, 0x2005,
        0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x202F, 0x205F, 0x3000,
    ]

    /// Cyrillic and fullwidth Latin lookalikes (aggressive mode only).
    static let latinConfusables: [UInt32: Character] = {
        var map: [UInt32: Character] = [
            0x0410: "A", 0x0412: "B", 0x0415: "E", 0x041A: "K", 0x041C: "M",
            0x041D: "H", 0x041E: "O", 0x0420: "P", 0x0421: "C", 0x0422: "T",
            0x0425: "X", 0x0430: "a", 0x0435: "e", 0x043E: "o", 0x0440: "p",
            0x0441: "c", 0x0443: "y", 0x0445: "x", 0x0456: "i",
        ]
        for offset in 0..<26 {
            map[0xFF21 + UInt32(offset)] = Character(Unicode.Scalar(0x41 + UInt8(offset)))
            map[0xFF41 + UInt32(offset)] = Character(Unicode.Scalar(0x61 + UInt8(offset)))
        }
        return map
    }()

    /// Bidi format controls. Marks and isolates are legitimate in mixed RTL/LTR prose.
    static let preservableBidi: Set<UInt32> = [0x061C, 0x200E, 0x200F, 0x2066, 0x2067, 0x2068, 0x2069]
    static let bidi: Set<UInt32> = preservableBidi.union([0x202A, 0x202B, 0x202C, 0x202D, 0x202E])

    static let zeroWidthFamily: Set<UInt32> = [0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x180E]
    static let emojiGlue: Set<UInt32> = [0x200D, 0xFE0E, 0xFE0F]
    static let scriptJoiners: Set<UInt32> = [0x200C, 0x200D]
    static let mongolianFVS: Set<UInt32> = [0x180B, 0x180C, 0x180D, 0x180F]
    static let khmerVowels: Set<UInt32> = [0x17B4, 0x17B5]
    static let hangulFillers: Set<UInt32> = [0x115F, 0x1160, 0x3164, 0xFFA0]
    /// Cf code points that are normal Arabic/Syriac/Kaithi orthography.
    static let orthographicFormat: Set<UInt32> = [
        0x0600, 0x0601, 0x0602, 0x0603, 0x0604, 0x0605, 0x06DD, 0x070F, 0x08E2, 0x110BD, 0x110CD,
    ]

    static let variationSelectorSupplement: ClosedRange<UInt32> = 0xE0100...0xE01EF
    static let tagCharacters: ClosedRange<UInt32> = 0xE0001...0xE007F
    static let flagTags: ClosedRange<UInt32> = 0xE0020...0xE007F

    /// Visible-layout format controls paired with the script block they govern.
    static let layoutControls: [(controls: ClosedRange<UInt32>, script: ClosedRange<UInt32>)] = [
        (0x13430...0x1343F, 0x13000...0x143FF), // Egyptian hieroglyphs
        (0x1BCA0...0x1BCA3, 0x1BC00...0x1BCA3), // Duployan shorthand
        (0x1D173...0x1D17A, 0x1D100...0x1D1FF), // musical symbols
    ]

    /// Unassigned Other_Default_Ignorable_Code_Point code points (render invisibly).
    static func isReservedIgnorable(_ cp: UInt32) -> Bool {
        cp == 0x2065 || cp == 0xE0000
            || (0xFFF0...0xFFF8).contains(cp)
            || (0xE0080...0xE00FF).contains(cp)
            || (0xE01F0...0xE0FFF).contains(cp)
    }

    /// The 66 Unicode noncharacters.
    static func isNoncharacter(_ cp: UInt32) -> Bool {
        (0xFDD0...0xFDEF).contains(cp) || cp & 0xFFFE == 0xFFFE
    }

    static func isPrivateUse(_ cp: UInt32) -> Bool {
        (0xE000...0xF8FF).contains(cp) || (0xF0000...0xFFFFD).contains(cp) || (0x100000...0x10FFFD).contains(cp)
    }

    static func isVariationSelector(_ cp: UInt32) -> Bool {
        variationSelectorSupplement.contains(cp) || (0xFE00...0xFE0F).contains(cp) || mongolianFVS.contains(cp)
    }

    static func isEmojiBase(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x1F000...0x1FAFF, 0x2190...0x25FF, 0x2600...0x27BF, 0x2B00...0x2BFF:
            return true
        case 0x203C, 0x2049, 0x2139, 0x2934, 0x2935,
             0x00A9, 0x00AE, 0x2122, 0x3030, 0x303D, 0x3297, 0x3299,
             0x0023, 0x002A, 0x0030...0x0039:
            return true
        default:
            return false
        }
    }

    static func isCJKIdeograph(_ cp: UInt32) -> Bool {
        (0x3400...0x4DBF).contains(cp) || (0x4E00...0x9FFF).contains(cp)
            || (0xF900...0xFAFF).contains(cp) || (0x20000...0x323AF).contains(cp)
    }

    static func isMongolianBlock(_ cp: UInt32) -> Bool { (0x1800...0x18AF).contains(cp) }

    static func isHangulJamo(_ cp: UInt32) -> Bool {
        (0x1100...0x11FF).contains(cp) || (0xA960...0xA97C).contains(cp)
            || (0xD7B0...0xD7C6).contains(cp) || (0x3131...0x318E).contains(cp)
            || (0xFFA1...0xFFDC).contains(cp)
    }

    /// Broad script group where ZWJ/ZWNJ can be orthographic.
    static func joiningScript(_ scalar: Unicode.Scalar) -> Int? {
        guard isLetterOrMark(scalar) else { return nil }
        switch scalar.value {
        case 0x0600...0x08FF: return 0 // Arabic
        case 0x0900...0x0DFF: return 1 // Indic
        case 0x0F00...0x109F: return 2 // Tibetan, Myanmar
        case 0x1780...0x17FF: return 3 // Khmer
        case 0x1800...0x18AF: return 4 // Mongolian
        default: return nil
        }
    }

    static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    static func isLetterOrMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: isLetter(scalar)
        }
    }

    /// Load-bearing invisibles that do not advance the "previous kept base".
    static func isGlue(_ cp: UInt32) -> Bool {
        emojiGlue.contains(cp) || isVariationSelector(cp) || scriptJoiners.contains(cp)
            || flagTags.contains(cp) || mongolianFVS.contains(cp) || khmerVowels.contains(cp)
            || hangulFillers.contains(cp)
    }

    /// Strip-class code points that no context can make legitimate; used for HTML entity refs.
    static func isContextFreeStrip(_ cp: UInt32) -> Bool {
        switch cp {
        case 0x00AD, 0x034F, 0x180E, 0x200B, 0x202D, 0x202E, 0xFEFF, 0xE0001,
             0x2060...0x2064, 0x206A...0x206F, 0xFFF9...0xFFFB:
            return true
        default:
            return isNoncharacter(cp) || isReservedIgnorable(cp)
        }
    }
}

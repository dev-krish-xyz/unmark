import Foundation

/// A kind of metadata removed from an image.
public enum MetadataKind: String, Sendable, CaseIterable, Comparable {
    /// C2PA Content Credentials (JUMBF), the provenance manifest AI image generators attach.
    case contentCredentials
    case exif
    case location
    case xmp
    case iptc
    /// PNG text chunks; Stable Diffusion and others store the full prompt here.
    case text
    case comment
    /// Secondary images or data after the end of the main image (gain maps, thumbnails, trailers).
    case appendedData
    case other

    public var title: String {
        switch self {
        case .contentCredentials: "C2PA"
        case .exif: "EXIF"
        case .location: "GPS"
        case .xmp: "XMP"
        case .iptc: "IPTC"
        case .text: "text"
        case .comment: "comments"
        case .appendedData: "appended data"
        case .other: "other"
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public enum ImageFormat: String, Sendable {
    case jpeg, png, webp
}

public struct StripResult: Sendable, Equatable {
    public var format: ImageFormat
    public var data: Data
    public var removed: Set<MetadataKind>
    /// Removed metadata named an AI generator or carried C2PA credentials.
    public var aiProvenance: Bool
    public var changed: Bool { !removed.isEmpty }
}

public enum StripError: Error, Sendable, Equatable {
    case unsupportedFormat
    case malformed
}

/// Removes metadata from JPEG, PNG and WebP files without re-encoding: pixel data is copied
/// byte for byte. Colour profiles and rendering information are kept, and a non-default EXIF
/// orientation is rewritten as a minimal EXIF block so the image doesn't turn sideways.
public enum MetadataStripper {
    public static func format(of data: Data) -> ImageFormat? {
        let b = [UInt8](data.prefix(12))
        if b.count >= 3, b[0] == 0xFF, b[1] == 0xD8, b[2] == 0xFF { return .jpeg }
        if b.count >= 8, b[0..<8] == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return .png }
        if b.count >= 12, b[0..<4] == Array("RIFF".utf8)[...], b[8..<12] == Array("WEBP".utf8)[...] { return .webp }
        return nil
    }

    public static func strip(_ data: Data) throws -> StripResult {
        guard let format = format(of: data) else { throw StripError.unsupportedFormat }
        var removed = Set<MetadataKind>()
        var removedBytes: [UInt8] = []
        let bytes = [UInt8](data)
        let output: [UInt8] = switch format {
        case .jpeg: try stripJPEG(bytes, removed: &removed, removedBytes: &removedBytes)
        case .png: try stripPNG(bytes, removed: &removed, removedBytes: &removedBytes)
        case .webp: try stripWebP(bytes, removed: &removed, removedBytes: &removedBytes)
        }
        let ai = removed.contains(.contentCredentials) || mentionsAIGenerator(removedBytes)
        return StripResult(format: format, data: removed.isEmpty ? data : Data(output), removed: removed, aiProvenance: ai)
    }

    // MARK: JPEG

    private static func stripJPEG(_ b: [UInt8], removed: inout Set<MetadataKind>, removedBytes: inout [UInt8]) throws -> [UInt8] {
        var out: [UInt8] = [0xFF, 0xD8]
        var orientation: UInt16?
        var exifInsertAt: Int?
        var i = 2
        var inScan = false

        while i < b.count {
            if inScan {
                // Entropy-coded data: FF00 and restart markers belong to the scan.
                guard b[i] == 0xFF, i + 1 < b.count else { out.append(b[i]); i += 1; continue }
                let next = b[i + 1]
                if next == 0x00 || (0xD0...0xD7).contains(next) || next == 0xFF {
                    out.append(b[i]); i += 1; continue
                }
                inScan = false
            }
            guard b[i] == 0xFF else { throw StripError.malformed }
            var marker = i + 1
            while marker < b.count, b[marker] == 0xFF { marker += 1 }
            guard marker < b.count else { throw StripError.malformed }
            let code = b[marker]
            let start = marker - 1

            if code == 0xD9 {
                out += [0xFF, 0xD9]
                if marker + 1 < b.count {
                    removed.insert(.appendedData)
                    removedBytes += b[(marker + 1)...]
                }
                break
            }
            if (0xD0...0xD7).contains(code) || code == 0x01 {
                out += [0xFF, code]; i = marker + 1; continue
            }
            guard marker + 2 < b.count else { throw StripError.malformed }
            let length = Int(b[marker + 1]) << 8 | Int(b[marker + 2])
            let end = marker + 1 + length
            guard length >= 2, end <= b.count else { throw StripError.malformed }
            let segment = Array(b[start..<end])
            let payload = Array(b[(marker + 3)..<end])

            switch code {
            case 0xE0, 0xEE:
                // JFIF / Adobe colour transform: needed to decode correctly.
                out += segment
                if code == 0xE0 { exifInsertAt = out.count }
            case 0xE2 where payload.starts(with: Array("ICC_PROFILE\0".utf8)):
                out += segment
            case 0xE1 where payload.starts(with: Array("Exif\0\0".utf8)):
                let info = TIFF.info(Array(payload.dropFirst(6)))
                orientation = info.orientation ?? orientation
                removed.insert(.exif)
                if info.hasGPS { removed.insert(.location) }
                removedBytes += payload
            case 0xE1:
                removed.insert(payload.starts(with: Array("http://ns.adobe.com/".utf8)) ? .xmp : .other)
                removedBytes += payload
            case 0xEB:
                removed.insert(contains(payload, "c2pa") || contains(payload, "jumb") ? .contentCredentials : .other)
                removedBytes += payload
            case 0xED:
                removed.insert(.iptc)
                removedBytes += payload
            case 0xFE:
                removed.insert(.comment)
                removedBytes += payload
            case 0xE1...0xEF:
                removed.insert(.other)
                removedBytes += payload
            default:
                out += segment
                if code == 0xDA { inScan = true }
            }
            i = end
        }

        if let orientation, orientation != 1 {
            let tiff = TIFF.orientationOnly(orientation)
            var segment: [UInt8] = [0xFF, 0xE1]
            let length = 2 + 6 + tiff.count
            segment += [UInt8(length >> 8), UInt8(length & 0xFF)]
            segment += Array("Exif\0\0".utf8) + tiff
            out.insert(contentsOf: segment, at: exifInsertAt ?? 2)
        }
        return out
    }

    // MARK: PNG

    /// Chunks that affect how the image is decoded or displayed.
    private static let pngKeep: Set<String> = [
        "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "cHRM", "gAMA", "iCCP", "sBIT", "sRGB", "cICP",
        "mDCv", "cLLI", "bKGD", "hIST", "pHYs", "sPLT", "acTL", "fcTL", "fdAT",
    ]

    private static func stripPNG(_ b: [UInt8], removed: inout Set<MetadataKind>, removedBytes: inout [UInt8]) throws -> [UInt8] {
        var out = Array(b[0..<8])
        var orientation: UInt16?
        var i = 8
        while i + 8 <= b.count {
            let length = Int(UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]))
            let end = i + 12 + length
            guard end <= b.count else { throw StripError.malformed }
            let type = String(decoding: b[(i + 4)..<(i + 8)], as: UTF8.self)
            let data = Array(b[(i + 8)..<(i + 8 + length)])
            // An unknown critical chunk (uppercase first letter) can't be dropped safely.
            let critical = b[i + 4] & 0x20 == 0
            if pngKeep.contains(type) || critical {
                // Orientation must precede the image data.
                if type == "IDAT" || type == "IEND", let value = orientation {
                    if value != 1 { out += pngChunk("eXIf", TIFF.orientationOnly(value)) }
                    orientation = nil
                }
                out += b[i..<end]
                if type == "IEND" {
                    if end < b.count {
                        removed.insert(.appendedData)
                        removedBytes += b[end...]
                    }
                    return out
                }
            } else {
                switch type {
                case "caBX": removed.insert(.contentCredentials)
                case "eXIf":
                    let info = TIFF.info(data)
                    orientation = info.orientation ?? orientation
                    removed.insert(.exif)
                    if info.hasGPS { removed.insert(.location) }
                case "iTXt" where data.starts(with: Array("XML:com.adobe.xmp".utf8)): removed.insert(.xmp)
                case "tEXt", "zTXt", "iTXt": removed.insert(.text)
                default: removed.insert(.other)
                }
                removedBytes += data
            }
            i = end
        }
        throw StripError.malformed
    }

    private static func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let typeBytes = Array(type.utf8)
        let n = UInt32(data.count)
        return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
            + typeBytes + data + bigEndian(CRC32.checksum(typeBytes + data))
    }

    // MARK: WebP

    private static let webpKeep: Set<String> = ["VP8 ", "VP8L", "VP8X", "ALPH", "ANIM", "ANMF", "ICCP"]

    private static func stripWebP(_ b: [UInt8], removed: inout Set<MetadataKind>, removedBytes: inout [UInt8]) throws -> [UInt8] {
        var body: [UInt8] = Array("WEBP".utf8)
        var vp8xFlagsIndex: Int?
        var i = 12
        while i + 8 <= b.count {
            let size = Int(UInt32(b[i + 4]) | UInt32(b[i + 5]) << 8 | UInt32(b[i + 6]) << 16 | UInt32(b[i + 7]) << 24)
            let padded = size + (size & 1)
            let end = i + 8 + padded
            guard i + 8 + size <= b.count else { throw StripError.malformed }
            let fourCC = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            let data = Array(b[(i + 8)..<(i + 8 + size)])
            if webpKeep.contains(fourCC) {
                if fourCC == "VP8X" { vp8xFlagsIndex = body.count + 8 }
                body += b[i..<min(end, b.count)]
            } else {
                switch fourCC {
                case "EXIF":
                    let tiff = data.starts(with: Array("Exif\0\0".utf8)) ? Array(data.dropFirst(6)) : data
                    removed.insert(.exif)
                    if TIFF.info(tiff).hasGPS { removed.insert(.location) }
                case "XMP ": removed.insert(.xmp)
                case "C2PA": removed.insert(.contentCredentials)
                default: removed.insert(.other)
                }
                removedBytes += data
            }
            i = end
        }
        if let flags = vp8xFlagsIndex, flags < body.count {
            body[flags] &= ~UInt8(0x08 | 0x04) // EXIF and XMP present bits.
        }
        let size = UInt32(body.count)
        return Array("RIFF".utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + body
    }

    // MARK: Helpers

    private static let aiMarkers = [
        "c2pa", "trainedalgorithmicmedia", "openai", "dall-e", "dall·e", "chatgpt", "midjourney",
        "stable diffusion", "stablediffusion", "comfyui", "\"prompt\"", "negative prompt", "gemini",
        "imagen", "synthid", "firefly", "grok", "x.ai", "leonardo.ai", "ideogram", "black forest labs",
    ]

    static func mentionsAIGenerator(_ bytes: [UInt8]) -> Bool {
        guard !bytes.isEmpty else { return false }
        let text = String(decoding: bytes, as: UTF8.self).lowercased()
        return aiMarkers.contains { text.contains($0) }
    }

    private static func contains(_ bytes: [UInt8], _ ascii: String) -> Bool {
        let needle = Array(ascii.utf8)
        guard bytes.count >= needle.count else { return false }
        return (0...(bytes.count - needle.count)).contains { bytes[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    private static func bigEndian(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }
}

/// Just enough TIFF to read IFD0's orientation and GPS pointer, and write an orientation-only IFD.
enum TIFF {
    struct Info {
        var orientation: UInt16?
        var hasGPS = false
    }

    static func info(_ t: [UInt8]) -> Info {
        guard t.count >= 8 else { return Info() }
        let little: Bool
        switch (t[0], t[1]) {
        case (0x49, 0x49): little = true
        case (0x4D, 0x4D): little = false
        default: return Info()
        }
        func u16(_ o: Int) -> UInt16? {
            guard o + 2 <= t.count else { return nil }
            return little ? UInt16(t[o]) | UInt16(t[o + 1]) << 8 : UInt16(t[o]) << 8 | UInt16(t[o + 1])
        }
        func u32(_ o: Int) -> Int? {
            guard o + 4 <= t.count else { return nil }
            let v = little
                ? UInt32(t[o]) | UInt32(t[o + 1]) << 8 | UInt32(t[o + 2]) << 16 | UInt32(t[o + 3]) << 24
                : UInt32(t[o]) << 24 | UInt32(t[o + 1]) << 16 | UInt32(t[o + 2]) << 8 | UInt32(t[o + 3])
            return Int(v)
        }
        var info = Info()
        guard let ifd = u32(4), let count = u16(ifd) else { return info }
        for n in 0..<Int(count) {
            let entry = ifd + 2 + n * 12
            guard let tag = u16(entry) else { break }
            if tag == 0x0112 { info.orientation = u16(entry + 8) }
            if tag == 0x8825 { info.hasGPS = true }
        }
        return info
    }

    /// Big-endian TIFF with a single IFD holding only the orientation tag.
    static func orientationOnly(_ orientation: UInt16) -> [UInt8] {
        [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
         0x00, 0x01,
         0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, UInt8(orientation >> 8), UInt8(orientation & 0xFF), 0x00, 0x00,
         0x00, 0x00, 0x00, 0x00]
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        (0..<8).reduce(UInt32(n)) { c, _ in c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
    }

    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        ~bytes.reduce(UInt32.max) { table[Int(($0 ^ UInt32($1)) & 0xFF)] ^ ($0 >> 8) }
    }
}

// MARK: - Files

public struct FileStripReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public var source: URL
        /// The clean copy; nil when nothing needed removing or the file couldn't be handled.
        public var output: URL?
        public var removed: [MetadataKind]
        public var aiProvenance: Bool
        public var error: StripError?
    }

    public var items: [Item] = []

    public var cleaned: [Item] { items.filter { $0.output != nil } }
    public var alreadyClean: Int { items.filter { $0.output == nil && $0.error == nil }.count }
    public var unsupported: Int { items.filter { $0.error == .unsupportedFormat }.count }
    public var failed: Int { items.filter { $0.error == .malformed }.count }
    public var aiProvenance: Bool { items.contains(where: \.aiProvenance) }
    public var kinds: [MetadataKind] { Set(items.flatMap(\.removed)).sorted() }
}

public enum MetadataFileCleaner {
    public static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "webp"]

    /// Writes a clean copy of each file into `directory` as "name (clean).ext". Originals are
    /// never modified.
    public static func process(_ urls: [URL], into directory: URL) -> FileStripReport {
        var report = FileStripReport()
        for url in urls {
            var item = FileStripReport.Item(source: url, output: nil, removed: [], aiProvenance: false, error: nil)
            do {
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let result = try MetadataStripper.strip(data)
                item.removed = result.removed.sorted()
                item.aiProvenance = result.aiProvenance
                if result.changed {
                    let output = uniqueURL(for: url, in: directory)
                    try result.data.write(to: output, options: .withoutOverwriting)
                    item.output = output
                }
            } catch let error as StripError {
                item.error = error
            } catch {
                item.error = .malformed
            }
            report.items.append(item)
        }
        return report
    }

    static func uniqueURL(for source: URL, in directory: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        var candidate = directory.appendingPathComponent("\(stem) (clean)").appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (clean \(n))").appendingPathExtension(ext)
            n += 1
        }
        return candidate
    }
}

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import UnmarkCore

private func makeImage() -> CGImage {
    let context = CGContext(data: nil, width: 6, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for x in 0..<6 {
        for y in 0..<4 {
            context.setFillColor(red: CGFloat(x) / 6, green: CGFloat(y) / 4, blue: 0.5, alpha: 1)
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    return context.makeImage()!
}

private func encode(_ type: UTType, properties: [CFString: Any] = [:]) -> [UInt8] {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, makeImage(), properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return [UInt8](data as Data)
}

private func pixels(_ data: Data) -> [UInt8] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
    let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8,
                            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return buffer
}

private func properties(_ data: Data) -> [CFString: Any] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
}

private func jpegSegment(_ marker: UInt8, _ payload: [UInt8]) -> [UInt8] {
    let length = payload.count + 2
    return [0xFF, marker, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
}

private func pngChunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
    let n = UInt32(data.count)
    let body = Array(type.utf8) + data
    let crc = CRC32.checksum(body)
    return [UInt8(n >> 24), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + body
        + [UInt8(crc >> 24), UInt8(crc >> 16 & 0xFF), UInt8(crc >> 8 & 0xFF), UInt8(crc & 0xFF)]
}

private func contains(_ haystack: Data, _ needle: String) -> Bool {
    haystack.range(of: Data(needle.utf8)) != nil
}

private let c2paPayload = Array("JP".utf8) + [0, 1, 0, 0, 0, 1] + Array("jumbc2pa manifest from OpenAI".utf8)

@Suite struct MetadataStripperTests {
    @Test func jpegLosesMetadataButKeepsPixelsAndOrientation() throws {
        var jpeg = encode(.jpeg, properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "Secret Camera App"],
        ])
        jpeg.insert(contentsOf: jpegSegment(0xEB, c2paPayload) + jpegSegment(0xFE, Array("made by me".utf8)), at: 2)
        let original = Data(jpeg)
        #expect(contains(original, "Secret Camera App"))

        let result = try MetadataStripper.strip(original)

        #expect(result.format == .jpeg)
        #expect(result.removed.isSuperset(of: [.contentCredentials, .exif, .location, .comment]))
        #expect(result.aiProvenance)
        #expect(!contains(result.data, "Secret Camera App"))
        #expect(!contains(result.data, "c2pa"))
        #expect(!contains(result.data, "made by me"))
        #expect(pixels(result.data) == pixels(original))
        let props = properties(result.data)
        #expect(props[kCGImagePropertyOrientation] as? Int == 6)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
    }

    @Test func jpegWithDefaultOrientationGetsNoExif() throws {
        let jpeg = encode(.jpeg, properties: [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFSoftware: "Midjourney"]])
        let result = try MetadataStripper.strip(Data(jpeg))
        #expect(result.aiProvenance)
        #expect(!contains(result.data, "Exif"))
        #expect(pixels(result.data) == pixels(Data(jpeg)))
    }

    @Test func jpegDropsDataAfterTheImage() throws {
        let jpeg = encode(.jpeg) + Array("trailing secondary image".utf8)
        let result = try MetadataStripper.strip(Data(jpeg))
        #expect(result.removed.contains(.appendedData))
        #expect(result.data.suffix(2) == Data([0xFF, 0xD9]))
    }

    @Test func pngLosesTextAndCredentials() throws {
        var png = encode(.png)
        let tiff = TIFF.orientationOnly(3)
        let extra = pngChunk("tEXt", Array("parameters\0a cat in space, Steps: 20, Sampler: Euler".utf8))
            + pngChunk("iTXt", Array("XML:com.adobe.xmp\0\0\0\0\0<x:xmpmeta>trainedAlgorithmicMedia</x:xmpmeta>".utf8))
            + pngChunk("caBX", c2paPayload)
            + pngChunk("eXIf", tiff)
            + pngChunk("tIME", [0x07, 0xEA, 10, 15, 12, 0, 0])
        png.insert(contentsOf: extra, at: 33) // After the signature and IHDR.
        let original = Data(png)

        let result = try MetadataStripper.strip(original)

        #expect(result.removed.isSuperset(of: [.text, .xmp, .contentCredentials, .exif, .other]))
        #expect(result.aiProvenance)
        #expect(!contains(result.data, "a cat in space"))
        #expect(!contains(result.data, "caBX"))
        #expect(!contains(result.data, "tIME"))
        #expect(pixels(result.data) == pixels(original))
        #expect(properties(result.data)[kCGImagePropertyOrientation] as? Int == 3)
    }

    @Test func webpLosesMetadataChunks() throws {
        func chunk(_ fourCC: String, _ data: [UInt8]) -> [UInt8] {
            let n = UInt32(data.count)
            return Array(fourCC.utf8) + [UInt8(n & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 24)]
                + data + (data.count % 2 == 1 ? [0] : [])
        }
        let body = Array("WEBP".utf8)
            + chunk("VP8X", [0x0C, 0, 0, 0, 5, 0, 0, 3, 0, 0])
            + chunk("VP8L", [0x2F, 1, 2, 3, 4])
            + chunk("EXIF", Array("Exif\0\0".utf8) + TIFF.orientationOnly(1))
            + chunk("XMP ", Array("<x:xmpmeta>Imagen</x:xmpmeta>".utf8))
            + chunk("C2PA", c2paPayload)
        let size = UInt32(body.count)
        let webp = Array("RIFF".utf8) + [UInt8(size & 0xFF), UInt8(size >> 8 & 0xFF), UInt8(size >> 16 & 0xFF), UInt8(size >> 24)] + body

        let result = try MetadataStripper.strip(Data(webp))
        let out = [UInt8](result.data)

        #expect(result.removed == [.exif, .xmp, .contentCredentials])
        #expect(result.aiProvenance)
        let expectedSize = 4 + (8 + 10) + (8 + 6)
        #expect(Int(out[4]) | Int(out[5]) << 8 == expectedSize)
        #expect(out.count == expectedSize + 8)
        #expect(out[20] == 0) // VP8X EXIF and XMP flags cleared.
        #expect(!contains(result.data, "Imagen"))
    }

    @Test func cleanImageIsUntouched() throws {
        // ImageIO writes its own eXIf chunk, so strip once to get a metadata-free file.
        let png = try MetadataStripper.strip(Data(encode(.png))).data
        let result = try MetadataStripper.strip(png)
        #expect(!result.changed)
        #expect(result.data == png)
    }

    @Test func rejectsOtherFormatsAndBrokenFiles() {
        #expect(throws: StripError.unsupportedFormat) { try MetadataStripper.strip(Data("GIF89a".utf8)) }
        let truncated = Data(encode(.png).prefix(40))
        #expect(throws: StripError.malformed) { try MetadataStripper.strip(truncated) }
    }

    @Test func tiffReader() {
        let info = TIFF.info(TIFF.orientationOnly(8))
        #expect(info.orientation == 8)
        #expect(!info.hasGPS)
    }

    @Test func crc32MatchesKnownValue() {
        #expect(CRC32.checksum(Array("IEND".utf8)) == 0xAE42_6082)
    }
}

@Suite struct MetadataFileCleanerTests {
    @Test func writesCleanCopiesAndLeavesOriginals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var jpeg = encode(.jpeg)
        jpeg.insert(contentsOf: jpegSegment(0xEB, c2paPayload), at: 2)
        let dirty = directory.appendingPathComponent("photo.jpg")
        try Data(jpeg).write(to: dirty)
        let clean = directory.appendingPathComponent("plain.png")
        try MetadataStripper.strip(Data(encode(.png))).data.write(to: clean)
        let text = directory.appendingPathComponent("notes.txt")
        try Data("hello".utf8).write(to: text)

        let first = MetadataFileCleaner.process([dirty, clean, text], into: directory)
        let second = MetadataFileCleaner.process([dirty], into: directory)

        #expect(first.cleaned.map { $0.output?.lastPathComponent } == ["photo (clean).jpg"])
        #expect(second.cleaned.first?.output?.lastPathComponent == "photo (clean 2).jpg")
        #expect(first.alreadyClean == 1)
        #expect(first.unsupported == 1)
        #expect(first.aiProvenance)
        #expect(try Data(contentsOf: dirty) == Data(jpeg))
    }
}

import AppKit
import Testing
@testable import UnmarkCore

/// Each test gets its own uniquely named pasteboard; the user's clipboard is never touched.
@MainActor
private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("unmark.tests.\(UUID().uuidString)"))
}

@MainActor
private func put(_ pasteboard: NSPasteboard, _ representations: [(String, Data)]) {
    let item = NSPasteboardItem()
    for (type, data) in representations {
        item.setData(data, forType: NSPasteboard.PasteboardType(type))
    }
    pasteboard.clearContents()
    pasteboard.writeObjects([item])
}

private func utf8(_ text: String) -> Data { Data(text.utf8) }

private func rtf(_ text: NSAttributedString) -> Data {
    try! text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
}

@Suite(.serialized) @MainActor struct ClipboardCleanerTests {
    let options = CleaningOptions()

    @Test func cleansPlainText() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Hello\u{200B}world\u{202F}!", forType: .string)
        let cleaner = ClipboardCleaner(pasteboard: pasteboard)

        let outcome = await cleaner.clean(options: options)

        #expect(outcome == .cleaned(removed: 1, replaced: 1))
        #expect(pasteboard.string(forType: .string) == "Helloworld !")
        #expect(cleaner.lastWrittenChangeCount == pasteboard.changeCount)
    }

    @Test func cleanTextIsNeverRewritten() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("Plain text 👩‍💻 \u{F8FF}", forType: .string)
        let before = pasteboard.changeCount

        let outcome = await ClipboardCleaner(pasteboard: pasteboard).clean(options: options)

        #expect(outcome == .alreadyClean)
        #expect(pasteboard.changeCount == before)
    }

    @Test func repeatedCleaningIsANoOp() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("a\u{200B}b", forType: .string)
        let cleaner = ClipboardCleaner(pasteboard: pasteboard)

        _ = await cleaner.clean(options: options)
        let count = pasteboard.changeCount
        #expect(await cleaner.clean(options: options) == .alreadyClean)
        #expect(await ClipboardCleaner(pasteboard: pasteboard).clean(options: options) == .alreadyClean)
        #expect(pasteboard.changeCount == count)
    }

    @Test func undoRestoresOriginalBytes() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let original = utf8("x\u{200B}y")
        put(pasteboard, [(PasteboardTypes.plainUTF8, original), ("com.example.private", Data([1, 2, 3]))])
        let cleaner = ClipboardCleaner(pasteboard: pasteboard)

        _ = await cleaner.clean(options: options)
        #expect(cleaner.canUndo)
        #expect(cleaner.undo())

        #expect(pasteboard.data(forType: .string) == original)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.private")) == Data([1, 2, 3]))
        #expect(!cleaner.canUndo)
    }

    @Test func undoRefusedAfterNewCopy() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x\u{200B}y", forType: .string)
        let cleaner = ClipboardCleaner(pasteboard: pasteboard)
        _ = await cleaner.clean(options: options)

        pasteboard.clearContents()
        pasteboard.setString("something new", forType: .string)

        #expect(!cleaner.canUndo)
        #expect(!cleaner.undo())
        #expect(pasteboard.string(forType: .string) == "something new")
    }

    @Test func staleTriggerDoesNothing() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x\u{200B}y", forType: .string)
        let stale = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("newer\u{200B}copy", forType: .string)
        let current = pasteboard.changeCount

        let outcome = await ClipboardCleaner(pasteboard: pasteboard).clean(options: options, expectedChangeCount: stale)

        #expect(outcome == .clipboardChanged)
        #expect(pasteboard.changeCount == current)
        #expect(pasteboard.string(forType: .string) == "newer\u{200B}copy")
    }

    @Test func concealedContentIsNeverRead() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        put(pasteboard, [(PasteboardTypes.plainUTF8, utf8("pass\u{200B}word")),
                         ("org.nspasteboard.ConcealedType", Data())])
        let before = pasteboard.changeCount

        #expect(await ClipboardCleaner(pasteboard: pasteboard).clean(options: options) == .protected)
        #expect(pasteboard.changeCount == before)
    }

    @Test func nonTextIsIgnored() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        put(pasteboard, [("public.png", Data([0x89, 0x50, 0x4E, 0x47]))])
        #expect(await ClipboardCleaner(pasteboard: pasteboard).clean(options: options) == .noText)

        let empty = makePasteboard()
        defer { empty.releaseGlobally() }
        empty.clearContents()
        #expect(await ClipboardCleaner(pasteboard: empty).clean(options: options) == .noText)
    }

    @Test func oversizedClipboardIsSkipped() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let huge = String(repeating: "a\u{200B}", count: ClipboardCleaner.maximumBytes / 2)
        pasteboard.clearContents()
        pasteboard.setString(huge, forType: .string)
        let before = pasteboard.changeCount

        #expect(await ClipboardCleaner(pasteboard: pasteboard).clean(options: options) == .tooLarge)
        #expect(pasteboard.changeCount == before)
    }

    @Test func richTextKeepsFormatting() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let styled = NSMutableAttributedString(string: "Bold\u{200B} and ", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        styled.append(NSAttributedString(string: "link\u{2060}", attributes: [.link: URL(string: "https://example.com")!]))
        put(pasteboard, [(PasteboardTypes.plainUTF8, utf8(styled.string)), ("public.rtf", rtf(styled))])

        let outcome = await ClipboardCleaner(pasteboard: pasteboard).clean(options: options)
        #expect(outcome == .cleaned(removed: 2, replaced: 0))

        let data = try #require(pasteboard.data(forType: .rtf))
        let cleaned = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(cleaned.string == "Bold and link")
        let font = cleaned.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
        #expect(cleaned.attribute(.link, at: 9, effectiveRange: nil) != nil)
        #expect(pasteboard.string(forType: .string) == "Bold and link")
    }

    /// AppKit's own writer adds legacy alias types (NSStringPboardType, CorePasteboardFlavorType …).
    @Test func attributedStringWrittenByAppKit() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let styled = NSMutableAttributedString(string: "Bold\u{200B} text", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        pasteboard.clearContents()
        pasteboard.writeObjects([styled])

        let outcome = await ClipboardCleaner(pasteboard: pasteboard).clean(options: options)

        #expect(outcome == .cleaned(removed: 1, replaced: 0))
        #expect(pasteboard.string(forType: .string) == "Bold text")
        let data = try #require(pasteboard.data(forType: .rtf))
        #expect(NSAttributedString(rtf: data, documentAttributes: nil)?.string == "Bold text")
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("public.utf16-external-plain-text"))
            .flatMap { String(data: $0, encoding: .utf16) } == "Bold text")
    }

    /// The copying app quit before fulfilling a promised type: that type reads as nil for everyone.
    @Test func unfulfillablePromisesAreSkipped() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let provider = SilentProvider()
        let item = NSPasteboardItem()
        item.setString("promise\u{200B}d", forType: .string)
        item.setDataProvider(provider, forTypes: [NSPasteboard.PasteboardType("public.utf16-external-plain-text")])
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        #expect(await ClipboardCleaner(pasteboard: pasteboard).clean(options: options) == .cleaned(removed: 1, replaced: 0))
        #expect(pasteboard.string(forType: .string) == "promised")
    }

    @Test func untouchedRichTextKeepsOriginalBytes() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let rtfData = rtf(NSAttributedString(string: "clean rich text"))
        put(pasteboard, [(PasteboardTypes.plainUTF8, utf8("plain\u{200B}")), ("public.rtf", rtfData),
                         ("com.example.private", Data([9]))])

        _ = await ClipboardCleaner(pasteboard: pasteboard).clean(options: options)

        #expect(pasteboard.data(forType: .rtf) == rtfData)
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType("com.example.private")) == Data([9]))
    }

    @Test func htmlIsCleanedAndWebArchiveDropped() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let html = "<p class=\"x\">Hi\u{200B} there&#8203;&nbsp;&#x200D;&shy;\u{00A0}end\u{202F}.</p>"
        put(pasteboard, [(PasteboardTypes.plainUTF8, utf8("Hi there end.")),
                         ("public.html", utf8(html)),
                         (PasteboardTypes.webArchive, Data([0xAA]))])

        let outcome = await ClipboardCleaner(pasteboard: pasteboard).clean(options: options)

        #expect(outcome == .cleaned(removed: 3, replaced: 1))
        let cleaned = pasteboard.data(forType: .html).flatMap { String(data: $0, encoding: .utf8) }
        // ZWJ references are context dependent and stay; literal NBSP is HTML layout and stays.
        #expect(cleaned?.unicodeScalars.map(\.value) == "<p class=\"x\">Hi there&nbsp;&#x200D;\u{00A0}end .</p>".unicodeScalars.map(\.value))
        #expect(pasteboard.data(forType: NSPasteboard.PasteboardType(PasteboardTypes.webArchive)) == nil)
    }

    @Test func everyItemIsCleaned() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let items = ["one\u{200B}", "two\u{FEFF}"].map { text -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(text, forType: .string)
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(items)

        #expect(await ClipboardCleaner(pasteboard: pasteboard).clean(options: options) == .cleaned(removed: 2, replaced: 0))
        #expect(pasteboard.pasteboardItems?.compactMap { $0.string(forType: .string) } == ["one", "two"])
    }

    @Test func utf16RepresentationsAreCleaned() {
        let snapshot = PasteboardSnapshot(items: [[
            .init(type: PasteboardTypes.plainUTF16External, data: "a\u{200B}b".data(using: .utf16)!),
            .init(type: PasteboardTypes.plainUTF16, data: "c\u{200B}d".data(using: .utf16LittleEndian)!),
        ]], changeCount: 0)
        let result = PasteboardTextCleaner.process(snapshot, options: options)
        #expect(String(data: result.items[0][0].data, encoding: .utf16) == "ab")
        #expect(String(data: result.items[0][1].data, encoding: .utf16LittleEndian) == "cd")
    }
}

@Suite @MainActor struct ClipboardMonitorTests {
    @Test func classifiesTypes() {
        #expect(PasteboardTypes.classify(nil) == .empty)
        #expect(PasteboardTypes.classify(["public.utf8-plain-text"]) == .text)
        #expect(PasteboardTypes.classify(["public.html"]) == .text)
        #expect(PasteboardTypes.classify(["public.png"]) == .other)
        #expect(PasteboardTypes.classify(["public.file-url", "public.utf8-plain-text"]) == .text)
        #expect(PasteboardTypes.classify(["public.utf8-plain-text", "org.nspasteboard.TransientType"]) == .protected)
    }

    @Test func reportsOnlyNewChanges() {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before start", forType: .string)

        let monitor = ClipboardMonitor(pasteboard: pasteboard)
        var changes: [ClipboardMonitor.Change] = []
        monitor.onChange = { changes.append($0) }
        monitor.start()
        defer { monitor.stop() }

        monitor.poll()
        #expect(changes.isEmpty)

        pasteboard.clearContents()
        pasteboard.setString("copied", forType: .string)
        monitor.poll()
        monitor.poll()
        #expect(changes == [.init(changeCount: pasteboard.changeCount, content: .text)])

        put(pasteboard, [("public.png", Data([1]))])
        monitor.poll()
        #expect(changes.last?.content == .other)
    }
}

private final class SilentProvider: NSObject, NSPasteboardItemDataProvider {
    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {}
}

@Suite struct StagedCleaningTests {
    @Test func progressIsMonotonicAndCompletes() {
        let snapshot = PasteboardSnapshot(items: [[
            .init(type: PasteboardTypes.plainUTF8, data: Data("a\u{200B}b".utf8)),
            .init(type: "public.png", data: Data(repeating: 0, count: 1000)),
        ]], changeCount: 0)
        let values = Locked<[Double]>([])
        _ = PasteboardTextCleaner.process(snapshot, options: CleaningOptions()) { value in values.mutate { $0.append(value) } }
        let reported = values.value
        #expect(reported == reported.sorted())
        #expect(reported.last == 1)
    }

    @Test func plainTextPrefersPlainThenRichText() {
        let rtfData = try! NSAttributedString(string: "from rtf").data(
            from: NSRange(location: 0, length: 8), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        let rtfOnly = PasteboardSnapshot(items: [[.init(type: "public.rtf", data: rtfData)]], changeCount: 0)
        #expect(rtfOnly.plainText == "from rtf")
        let both = PasteboardSnapshot(items: [[.init(type: "public.rtf", data: rtfData),
                                               .init(type: PasteboardTypes.plainUTF8, data: Data("plain".utf8))]], changeCount: 0)
        #expect(both.plainText == "plain")
        #expect(PasteboardSnapshot(items: [[.init(type: "public.png", data: Data())]], changeCount: 0).plainText == nil)
    }

    @MainActor @Test func stagesMatchOneShotClean() async throws {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x\u{200B}y", forType: .string)
        let cleaner = ClipboardCleaner(pasteboard: pasteboard)

        let snapshot = try cleaner.prepare().get()
        #expect(snapshot.plainText == "x\u{200B}y")
        let result = await cleaner.process(snapshot, options: CleaningOptions())
        #expect(result.plainText == "xy")
        #expect(cleaner.commit(result, from: snapshot) == .cleaned(removed: 1, replaced: 0))
        #expect(pasteboard.string(forType: .string) == "xy")
        #expect(cleaner.prepare().failureValue == .alreadyClean)
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func mutate(_ body: (inout Value) -> Void) { lock.withLock { body(&stored) } }
}

private extension Result {
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

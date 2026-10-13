import AppKit

public enum CleanOutcome: Sendable, Equatable {
    case cleaned(removed: Int, replaced: Int)
    case alreadyClean
    case noText
    case protected
    case tooLarge
    case accessDenied
    /// The clipboard changed while cleaning; nothing was written.
    case clipboardChanged
    /// A representation could not be read; nothing was written.
    case unreadable
    /// Reworded by a language model; `divergence` is the share of word pairs that changed, 0...1.
    case rewritten(divergence: Double)
    case rewriteFailed(RewriteError)
    /// The user stopped a reword; nothing was written.
    case cancelled
}

/// Reads, cleans and rewrites a pasteboard. Only ever invoked from an explicit user action.
@MainActor
public final class ClipboardCleaner {
    public static let maximumBytes = 20 * 1024 * 1024

    public let pasteboard: NSPasteboard
    /// Change count produced by our own most recent write.
    public private(set) var lastWrittenChangeCount: Int?
    private var undoSnapshot: PasteboardSnapshot?

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Undo is only offered while the clipboard still holds our cleaned content.
    public var canUndo: Bool {
        undoSnapshot != nil && pasteboard.changeCount == lastWrittenChangeCount
    }

    public var accessDenied: Bool {
        if #available(macOS 15.4, *) {
            return pasteboard.accessBehavior == .alwaysDeny
        }
        return false
    }

    /// Reads the clipboard, cleans it and writes the result back in one step.
    /// - Parameter expectedChangeCount: the clipboard generation the user acted on. If the
    ///   clipboard moved on since, nothing is touched.
    public func clean(options: CleaningOptions, expectedChangeCount: Int? = nil) async -> CleanOutcome {
        let snapshot: PasteboardSnapshot
        switch prepare(expectedChangeCount: expectedChangeCount) {
        case .success(let value): snapshot = value
        case .failure(let outcome): return outcome
        }
        let result = await process(snapshot, options: options)
        return commit(result, from: snapshot)
    }

    /// Step 1: checks the clipboard and copies its contents into memory.
    /// - Parameter includingOwnWrite: also accept text Unmark itself just wrote, for example to
    ///   reword text that was cleaned a moment ago.
    public func prepare(
        expectedChangeCount: Int? = nil, includingOwnWrite: Bool = false
    ) -> Result<PasteboardSnapshot, CleanOutcome> {
        let changeCount = pasteboard.changeCount
        if let expectedChangeCount, expectedChangeCount != changeCount { return .failure(.clipboardChanged) }
        if changeCount == lastWrittenChangeCount && !includingOwnWrite { return .failure(.alreadyClean) }

        switch PasteboardTypes.classify(pasteboard.types?.map(\.rawValue)) {
        case .protected: return .failure(.protected)
        case .empty, .other: return .failure(.noText)
        case .text: break
        }
        if accessDenied { return .failure(.accessDenied) }
        return capture()
    }

    /// Step 2: cleans the snapshot off the main thread.
    public func process(
        _ snapshot: PasteboardSnapshot, options: CleaningOptions, progress: (@Sendable (Double) -> Void)? = nil
    ) async -> PasteboardCleaningResult {
        await Task.detached(priority: .userInitiated) {
            PasteboardTextCleaner.process(snapshot, options: options, progress: progress)
        }.value
    }

    /// Step 3: writes the cleaned items, unless the clipboard changed in the meantime.
    public func commit(_ result: PasteboardCleaningResult, from snapshot: PasteboardSnapshot) -> CleanOutcome {
        guard pasteboard.changeCount == snapshot.changeCount else { return .clipboardChanged }
        guard result.changed else { return .alreadyClean }

        write(result.items, markSource: true)
        undoSnapshot = snapshot
        lastWrittenChangeCount = pasteboard.changeCount
        return .cleaned(removed: result.removedCount, replaced: result.replacedCount)
    }

    /// Replaces the clipboard with plain text derived from `snapshot`, unless the clipboard
    /// changed in the meantime. Undo restores the snapshot.
    public func commit(plainText: String, from snapshot: PasteboardSnapshot) -> Bool {
        guard pasteboard.changeCount == snapshot.changeCount else { return false }
        write([[PasteboardSnapshot.Entry(type: PasteboardTypes.plainUTF8, data: Data(plainText.utf8))]], markSource: true)
        undoSnapshot = snapshot
        lastWrittenChangeCount = pasteboard.changeCount
        return true
    }

    /// Restores the exact bytes that were on the clipboard before the last clean.
    @discardableResult
    public func undo() -> Bool {
        guard canUndo, let snapshot = undoSnapshot else { return false }
        write(snapshot.items, markSource: false)
        undoSnapshot = nil
        lastWrittenChangeCount = nil
        return true
    }

    /// Drops the in-memory copy of the previous clipboard.
    public func forgetUndo() {
        undoSnapshot = nil
    }

    private func capture() -> Result<PasteboardSnapshot, CleanOutcome> {
        let changeCount = pasteboard.changeCount
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return .failure(.noText) }
        var copied: [[PasteboardSnapshot.Entry]] = []
        var bytes = 0
        for item in items {
            var entries: [PasteboardSnapshot.Entry] = []
            for type in item.types {
                // A promise whose provider has quit reads as nil for every app, so leaving it
                // out loses nothing.
                guard let data = item.data(forType: type) else { continue }
                bytes += data.count
                if bytes > Self.maximumBytes { return .failure(.tooLarge) }
                entries.append(PasteboardSnapshot.Entry(type: type.rawValue, data: data))
            }
            guard !entries.isEmpty else { return .failure(readFailure) }
            copied.append(entries)
        }
        return .success(PasteboardSnapshot(items: copied, changeCount: changeCount))
    }

    /// Nothing readable usually means the user declined the system paste prompt.
    private var readFailure: CleanOutcome {
        if #available(macOS 15.4, *), pasteboard.accessBehavior != .alwaysAllow {
            return .accessDenied
        }
        return .unreadable
    }

    private func write(_ items: [[PasteboardSnapshot.Entry]], markSource: Bool) {
        let objects = items.enumerated().map { index, entries in
            let item = NSPasteboardItem()
            for entry in entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            if markSource, index == 0, let bundleID = Bundle.main.bundleIdentifier,
               !entries.contains(where: { $0.type == PasteboardTypes.source }) {
                item.setString(bundleID, forType: NSPasteboard.PasteboardType(PasteboardTypes.source))
            }
            return item
        }
        pasteboard.clearContents()
        pasteboard.writeObjects(objects)
    }
}

extension CleanOutcome: Error {}

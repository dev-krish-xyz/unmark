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

    /// - Parameter expectedChangeCount: the clipboard generation the user acted on. If the
    ///   clipboard moved on since, nothing is touched.
    public func clean(options: CleaningOptions, expectedChangeCount: Int? = nil) async -> CleanOutcome {
        let changeCount = pasteboard.changeCount
        if let expectedChangeCount, expectedChangeCount != changeCount { return .clipboardChanged }
        if changeCount == lastWrittenChangeCount { return .alreadyClean }

        switch PasteboardTypes.classify(pasteboard.types?.map(\.rawValue)) {
        case .protected: return .protected
        case .empty, .other: return .noText
        case .text: break
        }
        if accessDenied { return .accessDenied }

        let snapshot: PasteboardSnapshot
        switch capture() {
        case .success(let value): snapshot = value
        case .failure(let outcome): return outcome
        }

        let result = await Task.detached(priority: .userInitiated) {
            PasteboardTextCleaner.process(snapshot, options: options)
        }.value

        guard pasteboard.changeCount == snapshot.changeCount else { return .clipboardChanged }
        guard result.changed else { return .alreadyClean }

        write(result.items, markSource: true)
        undoSnapshot = snapshot
        lastWrittenChangeCount = pasteboard.changeCount
        return .cleaned(removed: result.removedCount, replaced: result.replacedCount)
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
                guard let data = item.data(forType: type) else { return .failure(.unreadable) }
                bytes += data.count
                if bytes > Self.maximumBytes { return .failure(.tooLarge) }
                entries.append(PasteboardSnapshot.Entry(type: type.rawValue, data: data))
            }
            copied.append(entries)
        }
        return .success(PasteboardSnapshot(items: copied, changeCount: changeCount))
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

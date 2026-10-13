import AppKit

/// Watches the pasteboard generation. Reads only `changeCount` and the list of types,
/// never contents, so monitoring does not trigger clipboard privacy prompts.
///
/// NSPasteboard has no change notification, so this samples `changeCount` on a coalescable
/// timer; each tick is a single integer read.
@MainActor
public final class ClipboardMonitor {
    public struct Change: Sendable, Equatable {
        public var changeCount: Int
        public var content: ClipboardContent
    }

    public var onChange: ((Change) -> Void)?
    public private(set) var isRunning = false

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    private var timer: Timer?
    private var lastChangeCount: Int

    public init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    /// Starting does not report what is already on the clipboard; only new copies count.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = interval / 2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Re-reads the change count without reporting, e.g. after wake.
    public func resync() {
        lastChangeCount = pasteboard.changeCount
    }

    public func poll() {
        let changeCount = pasteboard.changeCount
        guard changeCount != lastChangeCount else { return }
        lastChangeCount = changeCount
        let content = PasteboardTypes.classify(pasteboard.types?.map(\.rawValue))
        onChange?(Change(changeCount: changeCount, content: content))
    }
}

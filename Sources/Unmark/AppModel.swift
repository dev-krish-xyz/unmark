import AppKit
import Observation
import UnmarkCore

enum IslandPhase: Equatable {
    case hidden
    /// Text is on the clipboard and has not been cleaned.
    case ready
    /// Cursor is resting on the notch; cleaning starts when the dwell completes.
    case dwelling
    /// Cleaning has taken long enough to be worth showing.
    case processing
    case result(CleanOutcome)
}

/// Drives the clipboard flow: copy → ready → intentional hover → clean → result → collapse.
@MainActor
@Observable
final class AppModel {
    static let dwell: Duration = .milliseconds(280)
    static let processingDelay: Duration = .milliseconds(120)
    static let resultDuration: Duration = .milliseconds(1700)
    /// The pre-clean clipboard is held in memory only this long.
    static let undoLifetime: Duration = .seconds(600)

    private(set) var phase: IslandPhase = .hidden
    private(set) var hasPendingText = false
    private(set) var lastOutcome: CleanOutcome?
    @ObservationIgnored private(set) var dwellStart = ContinuousClock.now

    @ObservationIgnored let cleaner = ClipboardCleaner()
    @ObservationIgnored private let monitor = ClipboardMonitor()
    @ObservationIgnored private var pendingChangeCount: Int?
    @ObservationIgnored private var dwellTask: Task<Void, Never>?
    @ObservationIgnored private var collapseTask: Task<Void, Never>?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var isCleaning = false
    /// Called after every completed clean so the menu bar can reflect it.
    @ObservationIgnored var onOutcome: ((CleanOutcome) -> Void)?

    init() {
        monitor.onChange = { [weak self] change in self?.clipboardChanged(change) }
    }

    // MARK: Monitoring

    func startMonitoring() {
        guard Preferences.monitorClipboard else { return }
        refreshPendingState()
        monitor.start()
    }

    func stopMonitoring() {
        monitor.stop()
    }

    func applyMonitoringPreference() {
        if Preferences.monitorClipboard {
            startMonitoring()
        } else {
            stopMonitoring()
            setPending(false, changeCount: nil)
        }
    }

    /// Reads only the change count and type list, never contents.
    private func refreshPendingState() {
        let pasteboard = cleaner.pasteboard
        let changeCount = pasteboard.changeCount
        let isText = PasteboardTypes.classify(pasteboard.types?.map(\.rawValue)) == .text
        setPending(isText && changeCount != cleaner.lastWrittenChangeCount, changeCount: changeCount)
    }

    private func clipboardChanged(_ change: ClipboardMonitor.Change) {
        if change.changeCount == cleaner.lastWrittenChangeCount { return }
        // Another copy replaced our cleaned text; drop the in-memory original right away.
        cleaner.forgetUndo()
        setPending(change.content == .text, changeCount: change.changeCount)
    }

    private func setPending(_ pending: Bool, changeCount: Int?) {
        hasPendingText = pending
        pendingChangeCount = pending ? changeCount : nil
        if phase == .hidden || phase == .ready {
            phase = pending ? .ready : .hidden
        }
    }

    // MARK: Hover

    func hoverBegan() {
        guard Preferences.hoverToClean, !isCleaning else { return }
        if !Preferences.monitorClipboard || !monitor.isRunning { refreshPendingState() }
        guard hasPendingText, let expected = pendingChangeCount else { return }
        collapseTask?.cancel()
        dwellStart = .now
        phase = .dwelling
        dwellTask?.cancel()
        dwellTask = Task { [weak self] in
            try? await Task.sleep(for: Self.dwell)
            guard !Task.isCancelled else { return }
            await self?.clean(expectedChangeCount: expected)
        }
    }

    func hoverEnded() {
        // Once the dwell completed, the clean runs to completion and shows its result.
        guard phase == .dwelling, !isCleaning else { return }
        dwellTask?.cancel()
        dwellTask = nil
        phase = hasPendingText ? .ready : .hidden
    }

    // MARK: Cleaning

    /// Explicit user action (notch dwell or menu). Never called automatically.
    func clean(expectedChangeCount: Int? = nil) async {
        guard !isCleaning else { return }
        isCleaning = true
        collapseTask?.cancel()
        let indicator = Task { [weak self] in
            try? await Task.sleep(for: Self.processingDelay)
            guard !Task.isCancelled, let self, self.isCleaning else { return }
            self.phase = .processing
        }

        let outcome = await cleaner.clean(options: Preferences.cleaningOptions, expectedChangeCount: expectedChangeCount)
        indicator.cancel()
        isCleaning = false

        if case .cleaned = outcome {
            undoExpiryTask?.cancel()
            undoExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: Self.undoLifetime)
                guard !Task.isCancelled else { return }
                self?.cleaner.forgetUndo()
            }
        }

        switch outcome {
        case .cleaned, .alreadyClean, .noText, .protected:
            setPending(false, changeCount: nil)
        case .clipboardChanged:
            refreshPendingState()
        case .tooLarge, .accessDenied, .unreadable:
            break
        }
        show(outcome)
    }

    func undo() {
        guard cleaner.undo() else { return }
        // The restored text still carries its markers, so it is ready to clean again.
        refreshPendingState()
    }

    private func show(_ outcome: CleanOutcome) {
        lastOutcome = outcome
        phase = .result(outcome)
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: outcome.message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        onOutcome?(outcome)
        collapseTask?.cancel()
        collapseTask = Task { [weak self] in
            try? await Task.sleep(for: Self.resultDuration)
            guard !Task.isCancelled, let self else { return }
            self.phase = self.hasPendingText ? .ready : .hidden
        }
    }
}

extension CleanOutcome {
    var message: String {
        switch self {
        case let .cleaned(removed, replaced):
            switch (removed, replaced) {
            case (_, 0): return "Removed \(removed) \(removed == 1 ? "character" : "characters")"
            case (0, _): return "Fixed \(replaced) \(replaced == 1 ? "space" : "spaces")"
            default: return "Removed \(removed) · fixed \(replaced) \(replaced == 1 ? "space" : "spaces")"
            }
        case .alreadyClean: return "Already clean"
        case .noText: return "No text to clean"
        case .protected: return "Protected content skipped"
        case .tooLarge: return "Too large to clean"
        case .accessDenied: return "Clipboard access denied"
        case .clipboardChanged: return "Clipboard changed"
        case .unreadable: return "Couldn’t read clipboard"
        }
    }

    var isSuccess: Bool {
        if case .cleaned = self { return true }
        return false
    }

    var isProblem: Bool {
        switch self {
        case .tooLarge, .accessDenied, .unreadable, .clipboardChanged: true
        default: false
        }
    }
}

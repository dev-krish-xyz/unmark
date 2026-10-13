import AppKit
import Observation
import UnmarkCore

/// What the notch island is showing.
enum Island: Equatable {
    case hidden
    /// Copied text is waiting; small indicator beside the notch.
    case ready
    /// The large hover popup.
    case popup
    /// Compact result after cleaning from the menu bar.
    case toast(CleanOutcome)
}

/// Progress of the popup's single action.
enum PopupStage: Equatable {
    case idle
    case processing
    case done(CleanOutcome)
    case undone
}

/// Drives the flow: copy → ready → hover opens popup → Paste & Clean → live progress →
/// cleaned text on the clipboard → ⌘V anywhere.
@MainActor
@Observable
final class AppModel {
    static let openDelay: Duration = .milliseconds(120)
    /// Cleaning is usually instant; the activity bar stays up this long so it can be seen.
    /// The clipboard is written as soon as cleaning finishes, not when the bar does.
    static let minimumActivity: Duration = .milliseconds(650)
    static let toastDuration: Duration = .milliseconds(1700)
    /// A finished popup stays open at least this long, even if the cursor already left.
    static let resultHold: Duration = .milliseconds(1500)
    /// The pre-clean clipboard is held in memory only this long.
    static let undoLifetime: Duration = .seconds(600)
    static let previewLength = 600

    private(set) var island: Island = .hidden {
        didSet { if island != oldValue { onIslandChange?(island) } }
    }
    private(set) var stage: PopupStage = .idle
    private(set) var progress: Double = 0
    /// Copied text as read when the user clicked, for display.
    private(set) var originalPreview: String?
    /// The same text after cleaning.
    private(set) var cleanedPreview: String?
    private(set) var hasPendingText = false
    /// Whether the clipboard holds text at all (from its type list, not its contents).
    private(set) var clipboardHasText = false
    private(set) var lastOutcome: CleanOutcome?

    @ObservationIgnored let cleaner = ClipboardCleaner()
    @ObservationIgnored private let monitor = ClipboardMonitor()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var isCleaning = false
    @ObservationIgnored private var finishedAt: ContinuousClock.Instant?
    @ObservationIgnored var onOutcome: ((CleanOutcome) -> Void)?
    @ObservationIgnored var onIslandChange: ((Island) -> Void)?

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
            setPending(false)
        }
    }

    /// Reads only the change count and type list, never contents.
    private func refreshPendingState() {
        let pasteboard = cleaner.pasteboard
        clipboardHasText = PasteboardTypes.classify(pasteboard.types?.map(\.rawValue)) == .text
        setPending(clipboardHasText && pasteboard.changeCount != cleaner.lastWrittenChangeCount)
    }

    private func clipboardChanged(_ change: ClipboardMonitor.Change) {
        if change.changeCount == cleaner.lastWrittenChangeCount { return }
        // Another copy replaced our cleaned text; drop the in-memory original right away.
        cleaner.forgetUndo()
        clipboardHasText = change.content == .text
        setPending(clipboardHasText)
    }

    private func setPending(_ pending: Bool) {
        hasPendingText = pending
        if island == .hidden || island == .ready {
            island = pending ? .ready : .hidden
        }
    }

    // MARK: Popup

    func hoverBegan() {
        guard Preferences.hoverToClean, island != .popup else { return }
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(for: Self.openDelay)
            guard !Task.isCancelled else { return }
            self?.openPopup()
        }
    }

    /// Cursor left the notch before the popup opened: a passing cursor never opens it.
    func hoverEnded() {
        openTask?.cancel()
        openTask = nil
    }

    private func openPopup() {
        toastTask?.cancel()
        refreshPendingState()
        stage = .idle
        progress = 0
        originalPreview = nil
        cleanedPreview = nil
        island = .popup
    }

    /// Called when the cursor has left the popup. Never interrupts a running clean, and keeps
    /// a fresh result on screen briefly.
    func pointerLeftPopup() {
        guard island == .popup, stage != .processing else { return }
        if let finishedAt, ContinuousClock.now - finishedAt < Self.resultHold { return }
        closePopup()
    }

    func closePopup() {
        guard island == .popup, !isCleaning else { return }
        stage = .idle
        originalPreview = nil
        cleanedPreview = nil
        finishedAt = nil
        island = hasPendingText ? .ready : .hidden
    }

    // MARK: Cleaning

    /// The popup's button: read the clipboard, clean it, put the result back.
    func pasteAndClean() {
        Task { await run(inPopup: true) }
    }

    /// Menu bar fallback; shows the popup's progress if it is open, a compact result otherwise.
    func cleanFromMenu() {
        Task { await run(inPopup: island == .popup) }
    }

    func undo() {
        guard cleaner.undo() else { return }
        // The restored text still carries its markers, so it is ready to clean again.
        refreshPendingState()
        if island == .popup {
            stage = .undone
            cleanedPreview = nil
            finishedAt = .now
        }
    }

    private func run(inPopup: Bool) async {
        guard !isCleaning else { return }
        isCleaning = true
        let started = ContinuousClock.now
        if inPopup {
            stage = .processing
            progress = 0
            originalPreview = nil
            cleanedPreview = nil
        }

        let options = Preferences.cleaningOptions
        let outcome: CleanOutcome
        switch cleaner.prepare() {
        case .failure(let failure):
            outcome = failure
        case .success(let snapshot):
            if inPopup { originalPreview = snapshot.plainText.map(Self.preview) }
            let result = await cleaner.process(snapshot, options: options) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, self.isCleaning else { return }
                    self.progress = max(self.progress, fraction)
                }
            }
            outcome = cleaner.commit(result, from: snapshot)
            if inPopup {
                cleanedPreview = outcome.isSuccess ? result.plainText.map(Self.preview) : originalPreview
            }
        }

        if inPopup {
            progress = 1
            let remaining = Self.minimumActivity - (ContinuousClock.now - started)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        isCleaning = false
        finish(outcome, inPopup: inPopup)
    }

    private func finish(_ outcome: CleanOutcome, inPopup: Bool) {
        switch outcome {
        case .cleaned:
            undoExpiryTask?.cancel()
            undoExpiryTask = Task { [weak self] in
                try? await Task.sleep(for: Self.undoLifetime)
                guard !Task.isCancelled else { return }
                self?.cleaner.forgetUndo()
            }
            setPending(false)
        case .alreadyClean, .noText, .protected:
            setPending(false)
        case .clipboardChanged:
            refreshPendingState()
        case .tooLarge, .accessDenied, .unreadable:
            break
        }

        lastOutcome = outcome
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: outcome.isSuccess ? "\(outcome.message). Cleaned text is on the clipboard." : outcome.message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
        onOutcome?(outcome)

        if inPopup, island == .popup {
            stage = .done(outcome)
            finishedAt = .now
        } else {
            island = .toast(outcome)
            toastTask?.cancel()
            toastTask = Task { [weak self] in
                try? await Task.sleep(for: Self.toastDuration)
                guard !Task.isCancelled, let self, case .toast = self.island else { return }
                self.island = self.hasPendingText ? .ready : .hidden
            }
        }
    }

    private static func preview(_ text: String) -> String {
        text.count > previewLength ? String(text.prefix(previewLength)) + "…" : text
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
        case .alreadyClean: return "No hidden characters found"
        case .noText: return "No text to clean"
        case .protected: return "Protected content skipped"
        case .tooLarge: return "Too large to clean"
        case .accessDenied: return "Clipboard access denied"
        case .clipboardChanged: return "Clipboard changed"
        case .unreadable: return "Couldn’t read clipboard"
        }
    }

    var detail: String {
        switch self {
        case .cleaned: "Cleaned text is on your clipboard. Press ⌘V to paste it anywhere."
        case .alreadyClean: "Nothing to remove. Visible punctuation such as “quotes” and — dashes is kept."
        case .noText: "Copy some text first, then try again."
        case .protected: "This came from a password manager, so Unmark didn’t read it."
        case .tooLarge: "Clipboards over 20 MB are skipped."
        case .accessDenied: "Allow Unmark under Privacy & Security › Paste from Other Apps."
        case .clipboardChanged: "Something new was copied while cleaning. Nothing was changed."
        case .unreadable: "The app that copied this text may have quit."
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

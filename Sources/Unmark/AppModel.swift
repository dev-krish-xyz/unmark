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

/// What the popup's current or last run does.
enum PopupAction: Equatable {
    /// Remove hidden characters (Layer A).
    case clean
    /// Rewrite with the on-device model (Layer B).
    case reword
    /// Strip metadata from dropped image files.
    case files
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
    private(set) var action: PopupAction = .clean
    private(set) var rewordStyle = Preferences.rewordStyle
    /// Nil when the on-device model can reword; otherwise why not.
    private(set) var rewordUnavailableReason: String?
    private(set) var rewordProgress: RewriteProgress?
    private(set) var isBusy = false
    /// A file is being dragged over the island.
    private(set) var isDropTargeted = false

    @ObservationIgnored let cleaner = ClipboardCleaner()
    @ObservationIgnored private let monitor = ClipboardMonitor()
    @ObservationIgnored private var openTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var undoExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var isCleaning = false {
        didSet { isBusy = isCleaning }
    }
    @ObservationIgnored private var rewordTask: Task<Void, Never>?
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
        rewordUnavailableReason = OnDeviceModel.unavailableReason
        if !isCleaning { resetStage() }
        island = .popup
    }

    private func resetStage() {
        stage = .idle
        progress = 0
        originalPreview = nil
        cleanedPreview = nil
        rewordProgress = nil
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
        isDropTargeted = false
        resetStage()
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

    /// The popup's Reword button: rewrite the copied text with the on-device model.
    func pasteAndReword() {
        rewordTask = Task { await reword(inPopup: true) }
    }

    func rewordFromMenu() {
        rewordTask = Task { await reword(inPopup: island == .popup) }
    }

    func cancelReword() {
        rewordTask?.cancel()
    }

    func setRewordStyle(_ style: RewriteStyle) {
        Preferences.rewordStyle = style
        rewordStyle = style
    }

    // MARK: Files

    /// A file drag reached the notch: open right away so the popup can take the drop.
    func dropEntered() {
        openTask?.cancel()
        if island != .popup { openPopup() }
        isDropTargeted = true
    }

    func dropExited() {
        isDropTargeted = false
    }

    /// Saves metadata-free copies to Downloads and puts them on the clipboard.
    func stripFiles(_ urls: [URL], revealInFinder: Bool = false) {
        isDropTargeted = false
        guard !urls.isEmpty, !isCleaning else { return }
        Task { await strip(urls, inPopup: island == .popup, revealInFinder: revealInFinder) }
    }

    private func strip(_ urls: [URL], inPopup: Bool, revealInFinder: Bool) async {
        isCleaning = true
        action = .files
        let started = ContinuousClock.now
        if inPopup {
            resetStage()
            stage = .processing
            originalPreview = urls.map(\.lastPathComponent).joined(separator: "\n")
        }
        let directory = Self.downloadsDirectory
        let report = await Task.detached(priority: .userInitiated) {
            MetadataFileCleaner.process(urls, into: directory)
        }.value
        let outputs = report.cleaned.compactMap(\.output)
        if !outputs.isEmpty {
            cleaner.put(fileURLs: outputs)
            if revealInFinder { NSWorkspace.shared.activateFileViewerSelecting(outputs) }
        }
        if inPopup {
            cleanedPreview = report.items.map(Self.describe).joined(separator: "\n")
            progress = 1
            let remaining = Self.minimumActivity - (ContinuousClock.now - started)
            if remaining > .zero { try? await Task.sleep(for: remaining) }
        }
        isCleaning = false
        finish(.filesProcessed(report), inPopup: inPopup)
    }

    private static func describe(_ item: FileStripReport.Item) -> String {
        let name = item.output?.lastPathComponent ?? item.source.lastPathComponent
        switch item.error {
        case .unsupportedFormat: return "\(name) · not a JPEG, PNG or WebP"
        case .malformed: return "\(name) · couldn’t be read"
        case nil:
            guard item.output != nil else { return "\(name) · no metadata" }
            let kinds = item.removed.map(\.title).joined(separator: ", ")
            return "\(name) · removed \(kinds)\(item.aiProvenance ? " · AI provenance" : "")"
        }
    }

    /// The real Downloads folder (the sandbox grants it via the downloads entitlement).
    static var downloadsDirectory: URL {
        let home = getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home).appendingPathComponent("Downloads", isDirectory: true)
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
        action = .clean
        let started = ContinuousClock.now
        if inPopup {
            resetStage()
            stage = .processing
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

    private func reword(inPopup: Bool) async {
        guard !isCleaning else { return }
        isCleaning = true
        action = .reword
        if inPopup {
            resetStage()
            stage = .processing
        }
        let outcome = await rewordOutcome(inPopup: inPopup)
        if inPopup { progress = 1 }
        rewordTask = nil
        isCleaning = false
        finish(outcome, inPopup: inPopup)
    }

    private func rewordOutcome(inPopup: Bool) async -> CleanOutcome {
        guard let model = OnDeviceModel.make() else {
            return .rewriteFailed(.unavailable(OnDeviceModel.unavailableReason ?? "Reword isn’t available."))
        }
        let snapshot: PasteboardSnapshot
        switch cleaner.prepare(includingOwnWrite: true) {
        case .failure(let failure): return failure
        case .success(let value): snapshot = value
        }
        guard let text = snapshot.plainText else { return .noText }
        if inPopup { originalPreview = Self.preview(text) }

        let result: RewriteResult
        do {
            result = try await Rewriter(model: model).rewrite(
                text, style: rewordStyle, cleaning: Preferences.cleaningOptions
            ) { [weak self] update in
                guard let self, inPopup else { return }
                self.rewordProgress = update
                self.progress = max(self.progress, update.fraction)
                if !update.text.isEmpty { self.cleanedPreview = Self.preview(update.text) }
            }
        } catch is CancellationError {
            return .cancelled
        } catch let error as RewriteError {
            return .rewriteFailed(error)
        } catch {
            return .rewriteFailed(.failed(error.localizedDescription))
        }
        if Task.isCancelled { return .cancelled }
        guard cleaner.commit(plainText: result.text, from: snapshot) else { return .clipboardChanged }
        if inPopup { cleanedPreview = Self.preview(result.text) }
        return .rewritten(divergence: result.divergence)
    }

    private func finish(_ outcome: CleanOutcome, inPopup: Bool) {
        switch outcome {
        case .cleaned, .rewritten:
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
        case .tooLarge, .accessDenied, .unreadable, .rewriteFailed, .cancelled, .filesProcessed:
            break
        }

        lastOutcome = outcome
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: outcome.isSuccess ? "\(outcome.message). The result is on the clipboard." : outcome.message,
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
        case let .rewritten(divergence): return "Reworded · \(Int((divergence * 100).rounded()))% of phrasing changed"
        case .cancelled: return "Reword cancelled"
        case .filesProcessed(let report):
            let count = report.cleaned.count
            if count == 0 { return report.alreadyClean > 0 ? "No metadata found" : "Couldn’t strip metadata" }
            let files = count == 1 ? "image" : "\(count) images"
            return report.aiProvenance ? "Removed AI provenance from \(files)" : "Stripped metadata from \(files)"
        case .rewriteFailed(let error):
            switch error {
            case .unavailable: return "Reword unavailable"
            case .tooLong: return "Too long to reword"
            case .nothingToRewrite: return "Nothing to reword"
            case .declined: return "The model declined this text"
            case .unsupportedLanguage: return "Language not supported"
            case .busy: return "Model busy"
            case .unusableOutput, .failed: return "Reword didn’t work"
            }
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
        case .rewritten: "Plain text is on your clipboard. Read it before you use it: meaning can shift."
        case .cancelled: "Your clipboard is unchanged."
        case .filesProcessed(let report):
            if !report.cleaned.isEmpty {
                "Clean \(report.cleaned.count == 1 ? "copy" : "copies") saved to Downloads and copied. ⌘V attaches \(report.cleaned.count == 1 ? "it" : "them")."
            } else if report.alreadyClean > 0 {
                "Nothing to remove, so no copy was made."
            } else {
                "Unmark handles JPEG, PNG and WebP images."
            }
        case .rewriteFailed(let error):
            switch error {
            case .unavailable(let reason): reason
            case .tooLong: "Reword handles up to \(Rewriter.maximumCharacters.formatted()) characters at a time."
            case .nothingToRewrite: "The copied text has no sentences to rewrite."
            case .declined: "Apple’s on-device model wouldn’t rewrite it. Your clipboard is unchanged."
            case .unsupportedLanguage: "Apple Intelligence can’t rewrite this language yet."
            case .busy: "Apple’s on-device model is busy. Try again in a moment."
            case .unusableOutput: "The model’s answer didn’t look like a rewrite, so nothing changed."
            case .failed(let message): message
            }
        }
    }

    var isSuccess: Bool {
        switch self {
        case .cleaned, .rewritten: true
        case .filesProcessed(let report): !report.cleaned.isEmpty
        default: false
        }
    }

    var isProblem: Bool {
        switch self {
        case .tooLarge, .accessDenied, .unreadable, .clipboardChanged: true
        case .rewriteFailed(let error): error != .nothingToRewrite
        case .filesProcessed(let report): report.cleaned.isEmpty && report.alreadyClean == 0
        default: false
        }
    }
}

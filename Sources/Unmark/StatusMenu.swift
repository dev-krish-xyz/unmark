import AppKit
import UnmarkCore

/// Menu bar item: preferences, undo, and the cleaning trigger for Macs without a notch.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let onPreferencesChanged: () -> Void
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var feedbackTask: Task<Void, Never>?

    private lazy var statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private lazy var cleanItem = menuItem("Clean Clipboard", #selector(cleanClipboard))
    private lazy var undoItem = menuItem("Undo Last Clean", #selector(undo))
    private lazy var monitorItem = menuItem("Watch Clipboard", #selector(toggleMonitor))
    private lazy var hoverItem = menuItem("Open on Notch Hover", #selector(toggleHover))
    private lazy var spacesItem = menuItem("Normalize Unusual Spaces", #selector(toggleSpaces))
    private lazy var loginItem = menuItem("Launch at Login", #selector(toggleLogin))

    init(model: AppModel, onPreferencesChanged: @escaping () -> Void) {
        self.model = model
        self.onPreferencesChanged = onPreferencesChanged
        super.init()

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = self
        statusLine.isEnabled = false
        for entry in [statusLine, .separator(), cleanItem, undoItem, .separator(),
                      monitorItem, hoverItem, spacesItem, loginItem, .separator(),
                      menuItem("About Unmark", #selector(about)),
                      menuItem("Quit Unmark", #selector(quit), key: "q")] {
            menu.addItem(entry)
        }
        item.menu = menu
        setIcon(ready: false)
    }

    func modelDidChange() {
        guard feedbackTask == nil else { return }
        setIcon(ready: model.hasPendingText)
    }

    /// Brief icon confirmation, mainly for Macs without a notch.
    func show(_ outcome: CleanOutcome) {
        feedbackTask?.cancel()
        setIcon(symbol: outcome.isProblem ? "exclamationmark.circle" : "checkmark.circle", label: outcome.message)
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(for: AppModel.toastDuration)
            guard !Task.isCancelled, let self else { return }
            self.feedbackTask = nil
            self.setIcon(ready: self.model.hasPendingText)
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        statusLine.title = model.lastOutcome.map { "Last: \($0.message)" }
            ?? (model.hasPendingText ? "Copied text ready to clean" : "Copy text, then hover over the notch")
        undoItem.isEnabled = model.cleaner.canUndo
        monitorItem.state = Preferences.monitorClipboard ? .on : .off
        hoverItem.state = Preferences.hoverToClean ? .on : .off
        spacesItem.state = Preferences.normalizeSpaces ? .on : .off
        loginItem.state = Preferences.launchAtLogin ? .on : .off
    }

    private func setIcon(ready: Bool) {
        setIcon(symbol: ready ? "eraser.line.dashed.fill" : "eraser.line.dashed",
                label: ready ? "Unmark – text ready to clean" : "Unmark")
    }

    private func setIcon(symbol: String, label: String) {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = label
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func cleanClipboard() {
        model.cleanFromMenu()
    }

    @objc private func undo() {
        model.undo()
    }

    @objc private func toggleMonitor() {
        Preferences.monitorClipboard.toggle()
        onPreferencesChanged()
    }

    @objc private func toggleHover() {
        Preferences.hoverToClean.toggle()
        onPreferencesChanged()
    }

    @objc private func toggleSpaces() {
        Preferences.normalizeSpaces.toggle()
    }

    @objc private func toggleLogin() {
        Preferences.launchAtLogin.toggle()
    }

    @objc private func about() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "Removes invisible Unicode characters and unusual spaces from copied text. Works offline.\n\nCleaning rules ported from watermarks-remover (MIT).",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

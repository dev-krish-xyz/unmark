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
    private lazy var rewordItem = menuItem("Reword Clipboard", #selector(reword))
    private lazy var styleItem = NSMenuItem(title: "Reword Style", action: nil, keyEquivalent: "")
    private lazy var undoItem = menuItem("Undo", #selector(undo))
    private lazy var stripItem = menuItem("Strip Image Metadata…", #selector(stripImages))
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
        let styles = NSMenu()
        for style in RewriteStyle.allCases {
            let item = menuItem(style.title, #selector(chooseStyle(_:)))
            item.representedObject = style.rawValue
            item.toolTip = style.summary
            styles.addItem(item)
        }
        styleItem.submenu = styles
        for entry in [statusLine, .separator(), cleanItem, rewordItem, styleItem, undoItem, .separator(), stripItem, .separator(),
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
        statusLine.title = model.isBusy ? "Working…" : model.lastOutcome.map { "Last: \($0.message)" }
            ?? (model.hasPendingText ? "Copied text ready to clean" : "Copy text, then hover over the notch")
        cleanItem.isEnabled = !model.isBusy
        stripItem.isEnabled = !model.isBusy
        let unavailable = OnDeviceModel.unavailableReason
        rewordItem.isEnabled = !model.isBusy && unavailable == nil
        rewordItem.toolTip = unavailable ?? "Rewrites the copied text with Apple’s on-device model"
        for item in styleItem.submenu?.items ?? [] {
            item.state = item.representedObject as? String == model.rewordStyle.rawValue ? .on : .off
        }
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

    @objc private func reword() {
        model.rewordFromMenu()
    }

    @objc private func stripImages() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.title = "Strip Image Metadata"
        panel.message = "Clean copies are saved to Downloads. The originals aren’t changed."
        panel.prompt = "Strip"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.jpeg, .png, .webP]
        guard panel.runModal() == .OK else { return }
        model.stripFiles(panel.urls, revealInFinder: true)
    }

    @objc private func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = RewriteStyle(rawValue: raw) else { return }
        model.setRewordStyle(style)
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
                string: "Removes invisible Unicode characters and unusual spaces from copied text, and can reword it with Apple’s on-device model. Works offline.\n\nCleaning rules and reword prompts adapted from watermarks-remover (MIT).",
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

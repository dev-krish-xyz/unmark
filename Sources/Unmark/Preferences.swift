import Foundation
import ServiceManagement
import UnmarkCore

/// Lightweight user preferences backed by UserDefaults.
@MainActor
enum Preferences {
    private enum Key {
        static let monitorClipboard = "monitorClipboard"
        static let hoverToClean = "hoverToClean"
        static let normalizeSpaces = "normalizeSpaces"
    }

    private static let defaults: UserDefaults = {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            Key.monitorClipboard: true,
            Key.hoverToClean: true,
            Key.normalizeSpaces: true,
        ])
        return defaults
    }()

    static var monitorClipboard: Bool {
        get { defaults.bool(forKey: Key.monitorClipboard) }
        set { defaults.set(newValue, forKey: Key.monitorClipboard) }
    }

    static var hoverToClean: Bool {
        get { defaults.bool(forKey: Key.hoverToClean) }
        set { defaults.set(newValue, forKey: Key.hoverToClean) }
    }

    static var normalizeSpaces: Bool {
        get { defaults.bool(forKey: Key.normalizeSpaces) }
        set { defaults.set(newValue, forKey: Key.normalizeSpaces) }
    }

    static var cleaningOptions: CleaningOptions {
        var options = CleaningOptions()
        options.normalizeSpaces = normalizeSpaces
        return options
    }

    static var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Unmark: launch at login change failed: \(error.localizedDescription)")
            }
        }
    }
}

import AppKit
import Observation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private lazy var notch = NotchController(model: model)
    private var statusMenu: StatusMenu?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var isAsleep = false
    private var isLocked = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }

        let statusMenu = StatusMenu(model: model) { [weak self] in self?.preferencesChanged() }
        self.statusMenu = statusMenu
        model.onOutcome = { [weak statusMenu] outcome in statusMenu?.show(outcome) }
        observeModel()

        notch.update()
        model.startMonitoring()
        observeSystem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stopMonitoring()
        notch.teardown()
        for (center, token) in observers { center.removeObserver(token) }
    }

    private func preferencesChanged() {
        model.applyMonitoringPreference()
        notch.applyHoverPreference()
    }

    /// Re-registers on every change, the standard pattern for observing @Observable outside SwiftUI.
    private func observeModel() {
        withObservationTracking {
            _ = model.hasPendingText
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.statusMenu?.modelDidChange()
                self?.observeModel()
            }
        }
    }

    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.willSleepNotification) { $0.isAsleep = true; $0.updateMonitoring() }
        observe(workspace, NSWorkspace.didWakeNotification) { $0.isAsleep = false; $0.updateMonitoring() }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { $0.notch.update() }
        observe(workspace, NSWorkspace.activeSpaceDidChangeNotification) { $0.notch.update() }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true; $0.updateMonitoring() }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false; $0.updateMonitoring() }
    }

    /// Clipboard watching pauses while asleep or locked and resumes without replaying changes.
    private func updateMonitoring() {
        if isAsleep || isLocked {
            model.stopMonitoring()
        } else {
            model.startMonitoring()
            notch.update()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor (AppDelegate) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                handler(self)
            }
        }
        observers.append((center, token))
    }
}

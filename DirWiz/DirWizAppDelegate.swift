import AppKit
import DirWizCore
import DirWizUI
@preconcurrency import UserNotifications

@MainActor
final class DirWizAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated static let openNotificationAction = "OPEN_DIRWIZ"

    weak var appState: AppState?
    var openWindowAction: (() -> Void)?

    func connect(_ state: AppState) {
        appState = state
        DirWizRuntime.shared.appState = state
        state.requestNotificationAuthorization = { [weak self] in
            self?.requestNotificationAuthorization()
        }
        state.postMenuBarNotification = { [weak self] event in
            self?.post(event)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: "DIRWIZ_SPACE",
                actions: [
                    UNNotificationAction(
                        identifier: Self.openNotificationAction,
                        title: "Open DirWiz",
                        options: [.foreground]
                    ),
                ],
                intentIdentifiers: []
            ),
        ])
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let action = ResidencyPolicy.policyAfterLastWindowClosed(
            residencyEnabled: appState?.keepsRunningInMenuBar == true
        )
        switch action {
        case .terminate:
            return true
        case .remainRunningAsAccessory:
            sender.setActivationPolicy(.accessory)
            return false
        }
    }

    func openDirWiz() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let openWindowAction {
            openWindowAction()
        } else if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            // SwiftUI installs this responder action for WindowGroup. The explicit
            // `openWindowAction` above is the normal path after first launch.
            NSApp.sendAction(Selector(("newWindow:")), to: nil, from: nil)
        }
    }

    func quitDirWiz() {
        NSApp.terminate(nil)
    }

    // MARK: - Dock menu

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu(title: "DirWiz")
        if let state = appState {
            for path in state.recentVolumePaths {
                let name = path == "/" ? "Macintosh HD" : URL(fileURLWithPath: path).lastPathComponent
                let item = NSMenuItem(
                    title: "Scan \(name)",
                    action: #selector(scanRecentVolume(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = path
                menu.addItem(item)
            }
            if !state.recentVolumePaths.isEmpty { menu.addItem(.separator()) }
        }
        let checkpoint = NSMenuItem(
            title: "Take Checkpoint",
            action: #selector(takeCheckpoint(_:)),
            keyEquivalent: ""
        )
        checkpoint.target = self
        checkpoint.isEnabled = appState?.fileTree != nil
        menu.addItem(checkpoint)
        return menu
    }

    @objc private func scanRecentVolume(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        openDirWiz()
        appState?.startScan(path: path)
    }

    @objc private func takeCheckpoint(_ sender: Any?) {
        appState?.takeSnapshot()
    }

    // MARK: - Finder Service

    @objc(scanInDirWiz:userData:error:)
    func scanInDirWiz(
        _ pasteboard: NSPasteboard,
        userData: String,
        error errorPointer: AutoreleasingUnsafeMutablePointer<NSString>
    ) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        guard let folder = urls.first(where: {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }) else {
            errorPointer.pointee = "Select a folder to scan in DirWiz."
            return
        }
        openDirWiz()
        appState?.startScan(path: folder.path)
    }

    // MARK: - Notifications

    private func requestNotificationAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    private func post(_ event: MenuBarNotificationEvent) {
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = "DIRWIZ_SPACE"
        content.sound = .default
        let identifier: String
        switch event {
        case .lowSpace(let volumeName, let volumePath, let availableBytes, let thresholdBytes):
            content.title = "Low space on \(volumeName)"
            content.body = "\(SizeFormatter.shared.format(availableBytes)) remains. Your alert threshold is \(SizeFormatter.shared.format(thresholdBytes))."
            content.userInfo = ["volumePath": volumePath]
            identifier = "low-space-" + stableIdentifier(volumePath)
        case .growth(let volumeName, let path, let deltaBytes):
            content.title = "A folder grew on \(volumeName)"
            content.body = "\(URL(fileURLWithPath: path).lastPathComponent) grew by \(SizeFormatter.shared.format(deltaBytes)) since the previous checkpoint."
            content.userInfo = ["path": path]
            identifier = "growth-" + stableIdentifier(path)
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == Self.openNotificationAction
                || response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        await MainActor.run { self.openDirWiz() }
    }

    private func stableIdentifier(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 0x100000001b3 }
        return String(hash, radix: 16)
    }
}

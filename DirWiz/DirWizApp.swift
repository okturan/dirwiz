import SwiftUI
import DirWizLib

@main
struct DirWizApp: App {
    @State private var appState = AppState()
    @State private var showFullDiskAccessAlert = false

    init() {
        // When launched via `swift run`, the process starts as a background agent.
        // This promotes it to a regular app with Dock icon and Cmd+Tab presence.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
                .frame(minWidth: 1000, minHeight: 700)
                .onAppear {
                    appState.hasFullDiskAccess = checkFullDiskAccess()
                    if !appState.hasFullDiskAccess {
                        showFullDiskAccessAlert = true
                    }
                }
                .alert(
                    "Full Disk Access Required",
                    isPresented: $showFullDiskAccessAlert
                ) {
                    Button("Open System Settings") {
                        openFullDiskAccessSettings()
                    }
                    Button("Continue Anyway", role: .cancel) {}
                } message: {
                    Text("DirWiz needs Full Disk Access to scan all files on your volumes. Without it, many system and user files will be inaccessible.\n\nGo to System Settings > Privacy & Security > Full Disk Access and enable DirWiz.")
                }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1200, height: 800)
        .commands {
            // Edit menu: Cmd+F -> Find
            CommandGroup(after: .textEditing) {
                Button("Find...") {
                    NotificationCenter.default.post(name: .searchRequested, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
            }

        }
    }

    private func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let searchRequested = Notification.Name("searchRequested")
}

import AppKit
import Observation
import ServiceManagement

@MainActor
@Observable
public final class LoginItemController {
    public enum DisplayStatus: Equatable, Sendable {
        case off
        case on
        case requiresApproval
        case unavailable
    }

    public private(set) var status: DisplayStatus = .off
    public private(set) var errorMessage: String?

    public init() {
        refresh()
    }

    public var isEnabled: Bool { status == .on || status == .requiresApproval }

    public var statusText: String {
        if let errorMessage { return errorMessage }
        switch status {
        case .off: return "Off"
        case .on: return "Enabled"
        case .requiresApproval: return "Needs approval in System Settings"
        case .unavailable: return "Unavailable for this copy of the app"
        }
    }

    public func refresh() {
        errorMessage = nil
        switch SMAppService.mainApp.status {
        case .notRegistered: status = .off
        case .enabled: status = .on
        case .requiresApproval: status = .requiresApproval
        case .notFound: status = .unavailable
        @unknown default: status = .unavailable
        }
    }

    public func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    public func openApprovalSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

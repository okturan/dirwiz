import Foundation
import DirWizCore

/// Focused sub-model for treemap navigation state (breadcrumb path, back/forward stacks).
/// Extracted from AppState to reduce god-object complexity.
@MainActor
@Observable
public final class NavigationState {
    /// Root node for treemap display (navigation into subdirectories).
    public var treemapRootIndex: UInt32 = 0

    /// Navigation path for treemap breadcrumb — always canonical (root -> current).
    public var treemapPath: [UInt32] = [0]

    var backStack: [UInt32] = []
    var forwardStack: [UInt32] = []

    public var canNavigateBack: Bool { !backStack.isEmpty }
    public var canNavigateForward: Bool { !forwardStack.isEmpty }
    public var canNavigateUp: Bool { treemapPath.count > 1 }

    public init() {}

    /// Reset navigation state for a new scan.
    public func reset() {
        backStack.removeAll()
        forwardStack.removeAll()
        treemapRootIndex = 0
        treemapPath = [0]
    }
}

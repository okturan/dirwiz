import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// The treemap pane collapse preference. The divider button itself lives in the app
/// target where tests cannot reach it; what IS testable - and what actually broke things
/// once before with `treemapRenderStyle` - is the persistence discipline.
@Suite("Treemap Pane Collapse Tests")
@MainActor
struct TreemapPaneCollapseTests {

    private func isolated() -> (UserDefaults, () -> Void) {
        let suite = "dirwiz.test.panecollapse"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test("The pane starts expanded")
    func defaultsToExpanded() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        #expect(!AppState(defaults: defaults).isTreemapPaneCollapsed)
    }

    @Test("Collapse round-trips through the injected defaults, not .standard")
    func persistsThroughInjectedDefaults() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }

        let state = AppState(defaults: defaults)
        state.isTreemapPaneCollapsed = true
        #expect(defaults.bool(forKey: AppState.treemapCollapsedKey),
                "the choice must land in the injected store")

        // A relaunch reading the same store honours it.
        #expect(AppState(defaults: defaults).isTreemapPaneCollapsed)

        // And the developer's real app is untouched - the exact leak treemapRenderStyle
        // shipped with once.
        #expect(UserDefaults.standard.object(forKey: AppState.treemapCollapsedKey) == nil)
    }

    /// Layout preference, not scan state: a new scan must not spring the map back open.
    @Test("A new scan does not reset the collapsed pane")
    func survivesResetForNewScan() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }

        let state = AppState(defaults: defaults)
        state.isTreemapPaneCollapsed = true
        state.resetForNewScan()
        #expect(state.isTreemapPaneCollapsed)
    }

    @Test("Un-collapsing writes back too")
    func uncollapsePersists() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }

        let state = AppState(defaults: defaults)
        state.isTreemapPaneCollapsed = true
        state.isTreemapPaneCollapsed = false
        #expect(!AppState(defaults: defaults).isTreemapPaneCollapsed)
    }
}

import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// The Insights restructure: collapsible sections with persisted state, and the retirement
/// of the Space tab.
@Suite("Insights Restructure Tests")
@MainActor
struct InsightsRestructureTests {

    private func freshStore(_ name: String) -> (SectionCollapseStore, UserDefaults) {
        let suite = "dirwiz.test.insights.\(name)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (SectionCollapseStore(key: "collapsed", defaults: defaults), defaults)
    }

    /// The store records COLLAPSED ids, not expanded ones. That choice is what makes a
    /// section added in a future release default to visible instead of arriving collapsed.
    @Test("An unknown section defaults to expanded")
    func unknownSectionIsExpanded() {
        let (store, _) = freshStore("unknown")
        #expect(!store.isCollapsed("a-section-that-never-existed"))
    }

    @Test("Collapse state round-trips through UserDefaults")
    func collapseStatePersists() {
        let suite = "dirwiz.test.persist"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let first = SectionCollapseStore(key: "collapsed", defaults: defaults)
        first.setCollapsed(true, for: "fileAge")
        first.setCollapsed(true, for: "icloud")
        first.setCollapsed(false, for: "icloud")

        // A fresh store reads what the previous launch wrote.
        let second = SectionCollapseStore(key: "collapsed", defaults: defaults)
        #expect(second.isCollapsed("fileAge"))
        #expect(!second.isCollapsed("icloud"), "un-collapsing must remove, not just overwrite")
        defaults.removePersistentDomain(forName: suite)
    }

    @Test("Toggle flips state and removeAll restores every default")
    func toggleAndReset() {
        let (store, _) = freshStore("toggle")
        store.toggle("space")
        #expect(store.isCollapsed("space"))
        store.toggle("space")
        #expect(!store.isCollapsed("space"))

        store.setCollapsed(true, for: "a")
        store.setCollapsed(true, for: "b")
        store.removeAll()
        #expect(!store.isCollapsed("a") && !store.isCollapsed("b"))
    }

    // MARK: - Space tab retirement

    /// The Space tab is gone; its analysis lives in Insights. A leftover case would render
    /// an empty tab, since ContentView no longer has an arm for it.
    @Test("DetailTab no longer offers a Space tab")
    func spaceTabIsRetired() {
        let names = DetailTab.allCases.map(\.rawValue)
        #expect(!names.contains("Space"))
        #expect(DetailTab(rawValue: "Space") == nil)
        #expect(names.contains("Insights"), "the analysis has to be reachable somewhere")
        #expect(!names.contains("Extensions"), "retired in favour of the sidebar legend")
    }

    /// `activeTab` is not part of saved session state, so removing a case cannot strand a
    /// user on a tab that no longer exists. This pins that assumption.
    @Test("The active tab is not persisted, so retiring a case strands nobody")
    func activeTabIsNotPersisted() {
        let state = AppState()
        #expect(state.activeTab == DetailTab.allCases.first)

        state.activeTab = .insights
        // A brand-new AppState is what a relaunch produces.
        let relaunched = AppState()
        #expect(relaunched.activeTab == DetailTab.allCases.first)
    }
}

import Foundation
import DirWizCore
import Observation

/// Focused sub-model for file search state (query, results, in-progress flag).
/// Extracted from AppState to reduce god-object complexity.
@MainActor
@Observable
public final class SearchState {
    /// Current query text in the search bar.
    public var searchQuery: String = ""

    /// Matched node indices for the current query.
    public var searchResults: [UInt32] = []

    /// Whether a search is currently running.
    public var isSearching: Bool = false

    /// Extension drill-down filter: extensionHash of the pinned extension, nil = no filter.
    /// Set by clicking a row in the Extensions tab.
    public var extensionFilter: UInt32? = nil

    /// Display name for the active extension filter (e.g. ".swift" or "(no ext)").
    public var extensionFilterName: String = ""

    /// OR-combined extension multi-select, with display names for the chips.
    /// The single-extension drill-down above seeds this; both stay in sync via `SearchView`.
    public var extensionFilters: [UInt32: String] = [:]

    /// Inclusive upper size bound; nil = unbounded.
    public var maximumSize: UInt64? = nil

    /// Modified-date preset. Bounds are recomputed at search time, never cached, so a
    /// window left open overnight does not keep filtering against yesterday's "last 24h".
    public var datePreset: SearchDatePreset = .any

    /// Subtree scope set by "Search in this folder".
    ///
    /// The PATH is the source of truth, not the index: `removeSubtree` renumbers every
    /// index in the tree, so a stored index silently becomes a different folder after any
    /// mutation. The index is re-resolved from the path before each search.
    public var scopePath: String? = nil
    public var scopeName: String = ""
    /// Set when a scope path no longer resolves, so the UI can say why it cleared itself.
    public var scopeClearedNotice: String? = nil

    public var hasActiveFilters: Bool {
        extensionFilter != nil || !extensionFilters.isEmpty
            || maximumSize != nil || datePreset != .any || scopePath != nil
    }

    public init() {}

    /// Point a search at a folder subtree.
    public func setScope(path: String, name: String) {
        scopePath = path
        scopeName = name.isEmpty ? path : name
        scopeClearedNotice = nil
    }

    public func clearScope(notice: String? = nil) {
        scopePath = nil
        scopeName = ""
        scopeClearedNotice = notice
    }

    /// Reset search state for a new scan.
    public func reset() {
        searchQuery = ""
        searchResults = []
        isSearching = false
        extensionFilter = nil
        extensionFilterName = ""
        extensionFilters = [:]
        maximumSize = nil
        datePreset = .any
        scopePath = nil
        scopeName = ""
        scopeClearedNotice = nil
    }
}

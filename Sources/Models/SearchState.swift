import Foundation
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

    public init() {}

    /// Reset search state for a new scan.
    public func reset() {
        searchQuery = ""
        searchResults = []
        isSearching = false
    }
}

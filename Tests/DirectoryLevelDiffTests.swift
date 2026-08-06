import Testing
import Foundation
@testable import DirWizCore

/// The diff that decides which children a changed directory must actually touch. Every
/// downstream saving in `selective-child-rescan` depends on this classification being
/// exactly right: a false "unchanged" leaves a stale subtree forever, and a false
/// "changed" re-reads a subtree the patch was supposed to skip.
@Suite("Directory Level Diff Tests")
struct DirectoryLevelDiffTests {

    private func entry(_ name: String, dir: Bool = false, bundle: Bool = false)
        -> DirectoryEntryIdentity {
        DirectoryEntryIdentity(name: name, isDirectory: dir, isBundle: bundle)
    }

    @Test("A level with the same entries is metadata-only")
    func metadataOnly() {
        let cached = [entry("a.txt"), entry("sub", dir: true), entry("App.app", dir: true, bundle: true)]
        let result = DirectoryLevelDiff.compare(
            cached: cached, fresh: cached, isCaseSensitive: true)
        #expect(result.isMetadataOnly)
        #expect(Set(result.unchanged) == ["a.txt", "sub", "App.app"])
        #expect(result.requiresEnumeration.isEmpty)
        #expect(result.requiresRemoval.isEmpty)
    }

    @Test("Additions and removals are isolated to the entries that changed")
    func additionsAndRemovals() {
        let result = DirectoryLevelDiff.compare(
            cached: [entry("keep", dir: true), entry("gone", dir: true), entry("f.txt")],
            fresh: [entry("keep", dir: true), entry("new", dir: true), entry("f.txt")],
            isCaseSensitive: true
        )
        #expect(result.added == ["new"])
        #expect(result.removed == ["gone"])
        #expect(Set(result.unchanged) == ["keep", "f.txt"],
                "an untouched sibling must never be scheduled for work")
        #expect(!result.isMetadataOnly)
    }

    @Test("A type change is a removal plus an addition")
    func typeChanges() {
        // file -> directory
        var result = DirectoryLevelDiff.compare(
            cached: [entry("thing")], fresh: [entry("thing", dir: true)],
            isCaseSensitive: true)
        #expect(result.typeChanged == ["thing"])
        #expect(result.unchanged.isEmpty)
        #expect(result.requiresEnumeration == ["thing"])
        #expect(result.requiresRemoval == ["thing"],
                "the cached node describes something that no longer exists")

        // plain directory -> bundle
        result = DirectoryLevelDiff.compare(
            cached: [entry("X.app", dir: true)],
            fresh: [entry("X.app", dir: true, bundle: true)],
            isCaseSensitive: true)
        #expect(result.typeChanged == ["X.app"])
    }

    @Test("Case discipline follows the volume")
    func caseDiscipline() {
        // Case-insensitive volume: same entry, so no subtree churn...
        var result = DirectoryLevelDiff.compare(
            cached: [entry("Photos", dir: true)], fresh: [entry("photos", dir: true)],
            isCaseSensitive: false)
        #expect(result.added.isEmpty && result.removed.isEmpty,
                "a case-insensitive volume must not delete and re-read the same directory")
        #expect(result.typeChanged == ["photos"],
                "but the stored name is user-visible, so the entry is still replaced")

        // Case-sensitive volume: genuinely two different entries.
        result = DirectoryLevelDiff.compare(
            cached: [entry("Photos", dir: true)], fresh: [entry("photos", dir: true)],
            isCaseSensitive: true)
        #expect(result.added == ["photos"])
        #expect(result.removed == ["Photos"])
    }

    @Test("Empty levels on either side behave")
    func emptyLevels() {
        let both = DirectoryLevelDiff.compare(cached: [], fresh: [], isCaseSensitive: true)
        #expect(both.isMetadataOnly)
        #expect(both.unchanged.isEmpty)

        let filled = DirectoryLevelDiff.compare(
            cached: [], fresh: [entry("a"), entry("b", dir: true)], isCaseSensitive: true)
        #expect(Set(filled.added) == ["a", "b"])
        #expect(filled.removed.isEmpty)

        let emptied = DirectoryLevelDiff.compare(
            cached: [entry("a"), entry("b", dir: true)], fresh: [], isCaseSensitive: true)
        #expect(Set(emptied.removed) == ["a", "b"])
        #expect(emptied.added.isEmpty)
    }
}

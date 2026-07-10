import Foundation
import Testing
@testable import DirWizUI

/// Tests for `ColumnWidthsStore` — clamping, persistence, corruption handling, and
/// the `revision` invalidation counter. Each test gets its own `UserDefaults` suite
/// (removed in `defer`) so tests can run in parallel without clobbering each other.
@MainActor
@Suite("ColumnWidthsStore Tests")
struct ColumnWidthsStoreTests {

    private static let specs: [ColumnSpec] = [
        ColumnSpec(id: "name", defaultWidth: 0, minWidth: 200, maxWidth: .infinity, isFlexible: true),
        ColumnSpec(id: "size", defaultWidth: 90, minWidth: 60, maxWidth: 400, isFlexible: false),
        ColumnSpec(id: "modified", defaultWidth: 110, minWidth: 60, maxWidth: 400, isFlexible: false),
    ]

    /// Runs `body` against a fresh, isolated `UserDefaults` suite, tearing it down
    /// afterward regardless of how `body` exits.
    private func withDefaults(_ body: (UserDefaults, String) -> Void) {
        let suiteName = "test-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults, "columnWidths.test")
    }

    // MARK: - Unset / clamping / persistence

    @Test("Unset id returns the spec default")
    func unsetIdReturnsDefault() {
        withDefaults { defaults, key in
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store.width(for: "size") == 90)
            #expect(store.width(for: "modified") == 110)
        }
    }

    @Test("setWidth clamps below min and above max")
    func setWidthClamps() {
        withDefaults { defaults, key in
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            store.setWidth(10, for: "size")
            #expect(store.width(for: "size") == 60) // clamped to minWidth

            store.setWidth(9000, for: "size")
            #expect(store.width(for: "size") == 400) // clamped to maxWidth

            store.setWidth(150, for: "size")
            #expect(store.width(for: "size") == 150) // within range, unchanged
        }
    }

    @Test("setWidth is a no-op for the flexible column")
    func setWidthIgnoresFlexibleColumn() {
        withDefaults { defaults, key in
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            store.setWidth(999, for: "name")
            #expect(store.width(for: "name") == 0) // still the spec default
        }
    }

    @Test("setWidth persists — a new store on the same suite reads it back")
    func setWidthPersists() {
        withDefaults { defaults, key in
            let store1 = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            store1.setWidth(200, for: "size")

            let store2 = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store2.width(for: "size") == 200)
        }
    }

    // MARK: - reset / resetAll

    @Test("reset restores the spec default and persists the removal")
    func resetRestoresDefault() {
        withDefaults { defaults, key in
            let store1 = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            store1.setWidth(250, for: "size")
            store1.reset("size")
            #expect(store1.width(for: "size") == 90)

            // Persisted: a fresh store on the same suite also sees the default.
            let store2 = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store2.width(for: "size") == 90)
        }
    }

    @Test("resetAll restores every column and persists the removal")
    func resetAllRestoresDefaults() {
        withDefaults { defaults, key in
            let store1 = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            store1.setWidth(250, for: "size")
            store1.setWidth(300, for: "modified")
            store1.resetAll()
            #expect(store1.width(for: "size") == 90)
            #expect(store1.width(for: "modified") == 110)

            let store2 = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store2.width(for: "size") == 90)
            #expect(store2.width(for: "modified") == 110)
        }
    }

    // MARK: - Corrupt storage

    @Test("Non-Data value under the storage key falls back to defaults without crashing")
    func corruptStorageWrongTypeFallsBackToDefaults() {
        withDefaults { defaults, key in
            defaults.set("not json data at all", forKey: key)
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store.width(for: "size") == 90)
            #expect(store.width(for: "modified") == 110)
        }
    }

    @Test("Malformed JSON under the storage key falls back to defaults without crashing")
    func corruptStorageMalformedJSONFallsBackToDefaults() {
        withDefaults { defaults, key in
            let garbage = Data("{not valid json".utf8)
            defaults.set(garbage, forKey: key)
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store.width(for: "size") == 90)
            #expect(store.width(for: "modified") == 110)
        }
    }

    @Test("Negative width for one column falls back to its default while other columns still load")
    func corruptStorageNegativeValueFallsBackForThatColumnOnly() {
        withDefaults { defaults, key in
            let raw = Data(#"{"size": -50, "modified": 150}"#.utf8)
            defaults.set(raw, forKey: key)
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store.width(for: "size") == 90) // invalid -> spec default
            #expect(store.width(for: "modified") == 150) // valid -> loaded as-is
        }
    }

    @Test("Zero width for a column falls back to its default")
    func corruptStorageZeroValueFallsBackToDefault() {
        withDefaults { defaults, key in
            let raw = Data(#"{"size": 0}"#.utf8)
            defaults.set(raw, forKey: key)
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store.width(for: "size") == 90)
        }
    }

    // MARK: - Unknown id

    @Test("Unknown id returns a safe fallback width")
    func unknownIdReturnsSafeFallback() {
        withDefaults { defaults, key in
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            #expect(store.width(for: "nonexistent") == 100)
        }
    }

    @Test("setWidth/reset on an unknown id are no-ops")
    func unknownIdSetAndResetAreNoOps() {
        withDefaults { defaults, key in
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            let revisionBefore = store.revision
            store.setWidth(500, for: "nonexistent")
            store.reset("nonexistent")
            #expect(store.revision == revisionBefore)
            #expect(store.width(for: "nonexistent") == 100)
        }
    }

    // MARK: - revision

    @Test("revision increments on setWidth and reset")
    func revisionIncrementsOnChanges() {
        withDefaults { defaults, key in
            let store = ColumnWidthsStore(specs: Self.specs, storageKey: key, defaults: defaults)
            let r0 = store.revision

            store.setWidth(150, for: "size")
            let r1 = store.revision
            #expect(r1 > r0)

            store.reset("size")
            let r2 = store.revision
            #expect(r2 > r1)

            store.setWidth(200, for: "modified")
            store.resetAll()
            #expect(store.revision > r2)
        }
    }
}

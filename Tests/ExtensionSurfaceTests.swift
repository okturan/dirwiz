import Testing
import Foundation
@testable import DirWizCore
@testable import DirWizUI

/// The legend and the Extensions tab are two views of one thing. These tests pin the parts
/// that used to be duplicated - naming and drill-down - so they cannot drift apart again.
@Suite("Extension Surface Tests")
struct ExtensionSurfaceTests {

    private func model(_ id: UInt32, _ name: String) -> ExtensionRowModel {
        ExtensionRowModel(id: id, rawName: name, color: .zero, totalSize: 0, fileCount: 0)
    }

    @Test("Extension naming is spelled one way everywhere")
    func displayNaming() {
        #expect(model(1, "swift").displayName == ".swift")
        #expect(model(2, "").displayName == "(no ext)", "an empty extension is not a bare dot")
        #expect(model(ExtensionRowModel.otherID, "Other").displayName == "Other")
        #expect(model(ExtensionRowModel.otherID, "").isOther)
        #expect(!model(3, "png").isOther)
    }

    /// `ExtensionPalette` reserves UInt32.max for the aggregated tail. If that ever changes,
    /// "Other" would start drilling down as if it were a real extension and return nothing.
    @Test("The Other sentinel matches the palette's reserved id")
    func otherSentinelMatchesPalette() {
        var palette = ExtensionPalette()
        var stats: [FileTypeStat] = []
        for i in 0..<25 {
            stats.append(FileTypeStat(extensionName: "e\(i)",
                                      extensionHash: UInt32(i + 1),
                                      category: .other,
                                      totalSize: UInt64(1000 - i * 10),
                                      fileCount: 1,
                                      percentage: 0))
        }
        palette.assign(from: stats)
        if let other = palette.entries.first(where: { $0.extensionName == "Other" }) {
            #expect(other.id == ExtensionRowModel.otherID)
            #expect(ExtensionRowModel(other).isOther)
        }
    }

    @Test("A palette entry maps into a row model without losing anything")
    func paletteEntryRoundTrip() {
        let entry = PaletteEntry(id: 42, extensionName: "png",
                                 color: SIMD4<Float>(0.1, 0.2, 0.3, 1),
                                 totalSize: 2_048, fileCount: 7)
        let m = ExtensionRowModel(entry)
        #expect(m.id == 42)
        #expect(m.displayName == ".png")
        #expect(m.totalSize == 2_048)
        #expect(m.fileCount == 7)
        #expect(m.fraction(of: 4_096) == 0.5)
        #expect(m.fraction(of: 0) == 0, "an empty tree must not divide by zero")
    }

    // MARK: - Drill-down

    @Test("Drilling into an extension filters Search and switches to it")
    @MainActor
    func drillDownSetsFilterAndTab() {
        let state = AppState()
        state.search.searchQuery = "leftover query"
        state.activeTab = .treeView

        state.drillDownToExtension(hash: 99, displayName: ".swift")

        #expect(state.search.extensionFilter == 99)
        #expect(state.search.extensionFilterName == ".swift")
        #expect(state.search.searchQuery.isEmpty,
                "a stale query would AND with the new filter and read as 'no results'")
        #expect(state.activeTab == .search)
    }

    /// "Other" is an aggregate of many extensions, so there is no filter that expresses it.
    /// Sending it to Search would produce a guaranteed-empty result; it opens the full
    /// file-type table instead (a sheet now that the Extensions TAB is retired).
    @Test("Drilling into Other opens the full file-type list instead of an empty search")
    @MainActor
    func drillDownOtherGoesToTable() {
        let state = AppState()
        state.activeTab = .treeView
        state.search.extensionFilter = 7
        state.search.extensionFilterName = ".png"

        state.drillDownToExtension(hash: ExtensionRowModel.otherID, displayName: "Other")

        #expect(state.showAllFileTypes, "Other must lead somewhere it can actually be explored")
        #expect(state.activeTab == .treeView, "and must not hijack the current tab")
        #expect(state.search.extensionFilter == 7, "an existing filter must not be clobbered")
        #expect(state.search.extensionFilterName == ".png")
    }

    /// The sidebar legend and the tab were two surfaces for one thing. The tab is gone; the
    /// legend's "see all" sheet keeps the full sortable table one click away.
    @Test("The Extensions tab is retired")
    @MainActor
    func extensionsTabRetired() {
        let names = DetailTab.allCases.map(\.rawValue)
        #expect(!names.contains("Extensions"))
        #expect(DetailTab(rawValue: "Extensions") == nil)

        let state = AppState()
        #expect(!state.showAllFileTypes, "the sheet starts closed")
    }
}

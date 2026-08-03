import Foundation
import Testing
@testable import DirWizUI

@Suite("Website product contract")
struct WebsiteContractTests {
    private var html: String {
        get throws {
            let repositoryRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: repositoryRoot.appendingPathComponent("docs/index.html"),
                encoding: .utf8
            )
        }
    }

    @Test("Hero leads with the outcome, not allocated-size mechanics")
    func heroCopyIsOutcomeFirst() throws {
        let page = try html
        #expect(!page.contains("sized by the space it actually takes on disk"))
        #expect(page.contains(
            "DirWiz scans millions of files in seconds and turns your disk into a map you can explore."
        ))
        #expect(page.contains(
            "Find the space hogs, compare what changed, and move what you no longer need to the Trash."
        ))
        #expect(page.contains("Every rectangle is sized by the blocks it occupies on disk"),
                "allocated-block accuracy stays as lower-page technical proof")
    }

    @Test("Feature grid includes the current living and native Mac workflows")
    func featureInventoryIsCurrent() throws {
        let page = try html
        #expect(page.contains("<h3>Living view</h3>"))
        #expect(page.contains("<h3>Mac-native controls</h3>"))
        #expect(page.contains("<h3>Snapshot timeline</h3>"))
        #expect(page.contains("macOS menu bar"))
        #expect(page.contains("window toolbar"))
        #expect(page.contains("Back, Forward, Enclosing Folder, and Root"))
        #expect(page.contains("recency heatmap, snapshot pinning, temporal diff, CSV/JSON export"))
    }

    /// The demo's Folders mode mirrors the shipped semantics: depth colors from the
    /// finalized Nord palette, applied through the same named seam. The eight RGB rows
    /// are CardGeometry's Nord `chromeLevels` scaled to bytes - if the shipped palette
    /// changes, this pin fails instead of the website silently drifting.
    @Test("Browser Folders demo uses the shipped Nord depth palette")
    func browserFoldersUsesShippedDepthPalette() throws {
        let page = try html
        #expect(page.contains("const FOLDERS_DEPTH = [[79,92,117],[92,130,163],[77,156,153],[122,161,125],"))
        #expect(page.contains("[153,135,173],[110,140,184],[140,148,158],[179,102,107]];"))
        #expect(page.contains("function folderLeafColor"))
        #expect(page.contains("mapStyle===1 ? folderLeafColor"),
                "Folders keeps a named parity seam while Cushions bypasses it")

        let nord = FoldersColorScheme.nord
        for depth in 0..<8 {
            let fill = CardGeometry.containerFill(depth: depth, scheme: nord)
            let expected = "[\(Int((fill.x * 255).rounded())),\(Int((fill.y * 255).rounded())),\(Int((fill.z * 255).rounded()))]"
            #expect(page.contains(expected),
                    "depth \(depth) swatch \(expected) missing - demo drifted from the app palette")
        }
    }
}

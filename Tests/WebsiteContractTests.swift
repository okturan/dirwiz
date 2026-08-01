import Foundation
import Testing

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

    @Test("Browser Cards demo applies the app's Folders color policy")
    func browserCardsUseSettledPalette() throws {
        let page = try html
        #expect(page.contains("const FOLDER_LEAF_CHROME_BLEND = .75;"))
        #expect(page.contains("function folderLeafColor"))
        #expect(page.contains("mapStyle===1 ? folderLeafColor"),
                "Cards must transform leaf colors while Cushions retain the raw palette")
    }
}

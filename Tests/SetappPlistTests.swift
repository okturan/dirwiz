import Testing
import Foundation

@Suite("Setapp Info.plist Tests")
struct SetappPlistTests {

    @Test("infoPlistCarriesSetappKeys")
    func infoPlistCarriesSetappKeys() throws {
        let testDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = testDir.deletingLastPathComponent()
        let plistPath = repoRoot.appendingPathComponent("DirWiz/Info.plist").path

        let data = try #require(FileManager.default.contents(atPath: plistPath))
        let plist = try #require(
            try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        )

        let updatePolicy = try #require(plist["NSUpdateSecurityPolicy"] as? [String: Any])
        let allowProcesses = try #require(updatePolicy["AllowProcesses"] as? [String: Any])
        let setappTeamProcesses = try #require(allowProcesses["MEHY5QF425"] as? [String])
        #expect(setappTeamProcesses.contains("com.setapp.DesktopClient.SetappAgent"))

        let keywords = try #require(plist["MDItemKeywords"] as? [String])
        #expect(!keywords.isEmpty)
        #expect(keywords.allSatisfy { !$0.isEmpty })
    }
}

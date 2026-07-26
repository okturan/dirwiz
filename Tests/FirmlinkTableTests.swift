import Testing
import Foundation
@testable import DirWizCore

/// Coverage for `FirmlinkTable` (firmlink-double-traversal).
///
/// Parsing is tested against INJECTED table contents, never the host's real
/// `/usr/share/firmlinks` - otherwise these assertions would drift with the macOS version
/// the suite happens to run on.
@Suite("FirmlinkTable Tests")
struct FirmlinkTableTests {

    private let sample = """
    /AppleInternal\tAppleInternal
    /Applications\tApplications
    /Library\tLibrary
    /System/Library/Caches\tSystem/Library/Caches
    /Users\tUsers
    /usr/local\tusr/local
    """

    @Test("Parses the table into absolute Data-volume paths")
    func parsesTable() {
        let paths = FirmlinkTable.duplicateDataPaths(
            contents: sample, dataVolumeRoot: "/System/Volumes/Data", systemSideExists: { _ in true }
        )
        #expect(paths.contains("/System/Volumes/Data/Applications"))
        #expect(paths.contains("/System/Volumes/Data/Library"))
        #expect(paths.contains("/System/Volumes/Data/Users"))
        #expect(paths.contains("/System/Volumes/Data/System/Library/Caches"))
        #expect(paths.contains("/System/Volumes/Data/usr/local"))
        #expect(paths.count == 6)
    }

    @Test("A target whose system-side path is missing is NOT skipped")
    func missingSystemSideIsNotSkipped() {
        // Skipping the Data copy when the /-side path doesn't exist would drop the content
        // from BOTH sides - under-reporting, which is worse than the double count.
        let paths = FirmlinkTable.duplicateDataPaths(
            contents: sample, dataVolumeRoot: "/System/Volumes/Data",
            systemSideExists: { $0 != "/AppleInternal" }
        )
        #expect(!paths.contains("/System/Volumes/Data/AppleInternal"))
        #expect(paths.contains("/System/Volumes/Data/Applications"))
        #expect(paths.count == 5)
    }

    @Test("Missing table yields an empty set - fails open")
    func missingTableFailsOpen() {
        #expect(FirmlinkTable.duplicateDataPaths(contents: nil, systemSideExists: { _ in true }).isEmpty)
    }

    @Test("Malformed, blank, and CRLF rows are tolerated")
    func malformedRowsTolerated() {
        let messy = "\r\n/Applications\tApplications\r\ngarbage-no-tab\n\n/Users\tUsers\nthree\tfields\there\n\t\n"
        let paths = FirmlinkTable.duplicateDataPaths(
            contents: messy, dataVolumeRoot: "/System/Volumes/Data", systemSideExists: { _ in true }
        )
        #expect(paths == ["/System/Volumes/Data/Applications", "/System/Volumes/Data/Users"])
    }

    @Test("Rows whose system side isn't absolute are ignored")
    func relativeSystemSideIgnored() {
        let paths = FirmlinkTable.duplicateDataPaths(
            contents: "Applications\tApplications", systemSideExists: { _ in true }
        )
        #expect(paths.isEmpty)
    }

    @Test("Kill switch disables deduplication entirely")
    func killSwitchDisables() {
        let off = FirmlinkTable.loadSystemTable(environment: [FirmlinkTable.killSwitchEnv: "1"])
        #expect(off.isEmpty)
    }

    @Test("Trailing slash on the Data root doesn't produce a doubled separator")
    func dataRootTrailingSlashNormalized() {
        let paths = FirmlinkTable.duplicateDataPaths(
            contents: "/Users\tUsers", dataVolumeRoot: "/System/Volumes/Data/", systemSideExists: { _ in true }
        )
        #expect(paths == ["/System/Volumes/Data/Users"])
    }

    // MARK: - activation scope

    @Test("Active for a whole-volume scan, inactive at or below the Data volume")
    func activationScope() {
        #expect(FirmlinkTable.isActive(forScanRoot: "/"))
        // scanning the Data volume itself must enumerate everything
        #expect(!FirmlinkTable.isActive(forScanRoot: "/System/Volumes/Data"))
        #expect(!FirmlinkTable.isActive(forScanRoot: "/System/Volumes/Data/Users"))
        // unrelated roots never trigger it
        #expect(!FirmlinkTable.isActive(forScanRoot: "/Users/someone/Projects"))
        #expect(!FirmlinkTable.isActive(forScanRoot: "/Volumes/External"))
    }
}

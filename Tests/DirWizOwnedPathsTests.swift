import CoreServices
import Foundation
import Testing
@testable import DirWizCore

@Suite("DirWiz-owned FSEvents filtering")
struct DirWizOwnedPathsTests {
    @Test("Application Support override canonicalizes to the FSEvents spelling")
    func applicationSupportOverride() {
        #expect(
            DirWizOwnedPaths.applicationSupportRoot(environment: [
                DirWizOwnedPaths.appSupportOverrideEnv:
                    "/var/folders/test/T/app-support/",
            ])
                == "/private/var/folders/test/T/app-support/DirWiz"
        )
    }

    @Test("Only DirWiz-owned descendants are filtered from a root-volume monitor")
    func monitorIgnoresSelfOwnedWritesOnly() {
        let ownedRoot = "/Users/test/Library/Application Support/DirWiz"
        let monitor = FSEventsMonitor(
            watchPath: "/",
            ignoredRoots: [ownedRoot]
        )
        let modifiedFile = FSEventStreamEventFlags(
            kFSEventStreamEventFlagItemModified
                | kFSEventStreamEventFlagItemIsFile
        )

        #expect(monitor.processChanges([
            FSChange(
                path: ownedRoot + "/TreeCache/root.dwtc",
                flags: modifiedFile,
                timestamp: Date()
            ),
            FSChange(
                path: "/Users/test/Documents/report.txt",
                flags: modifiedFile,
                timestamp: Date()
            ),
            FSChange(
                path: ownedRoot + "-backup/not-owned.txt",
                flags: modifiedFile,
                timestamp: Date()
            ),
        ]))

        let paths = Set(monitor.currentChanges().map(\.path))
        #expect(!paths.contains(ownedRoot + "/TreeCache"))
        #expect(paths.contains("/Users/test/Documents"))
        #expect(paths.contains(ownedRoot + "-backup"))

        #expect(
            !monitor.processChanges([
                FSChange(
                    path: ownedRoot + "/TreeCache/another.dwtc",
                    flags: modifiedFile,
                    timestamp: Date()
                ),
            ]),
            "an ignored-only batch must not republish the old snapshot"
        )
    }
}

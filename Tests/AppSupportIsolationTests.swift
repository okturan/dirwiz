import Testing
import Foundation
@testable import DirWizCore

/// The developer's real Application Support was littered with 550+ fixture-keyed
/// stores (TreeCache, Snapshots, WarmStartHistory) because scan-completion work could
/// resolve store paths without the test override - a suite that forgot
/// `withTemporaryAppSupportDir`, or a detached completion (history record, cache save,
/// auto-checkpoint) that outlived the suite body and ran after the override was
/// restored. `DirWizOwnedPaths.applicationSupportBase` now refuses to fall back to the
/// real location under a test harness; these tests pin the detection, the redirect,
/// and the precedence so the littering cannot silently resume.
@Suite("App Support Isolation Tests")
struct AppSupportIsolationTests {

    /// Empirical pin: this very process must register as a harness. If the runner's
    /// environment signals ever change, this fails loudly instead of the redirect
    /// silently disarming.
    @Test("This test process is detected as a test harness")
    func harnessIsDetected() {
        #expect(DirWizOwnedPaths.isTestHarness(),
                "the runner sets no recognized harness signal - update DirWizOwnedPaths.isTestHarness before anything else runs unguarded")
    }

    @Test("SwiftPM and XCTest executable forms are harness signals")
    func testExecutableFormsAreDetected() {
        #expect(DirWizOwnedPaths.isTestHarness(
            [:],
            xctestLoaded: false,
            executablePath: "/usr/libexec/swiftpm-testing-helper"
        ))
        #expect(DirWizOwnedPaths.isTestHarness(
            [:],
            xctestLoaded: false,
            executablePath: "/tmp/DirWizTests.xctest/Contents/MacOS/DirWizTests"
        ))
        #expect(!DirWizOwnedPaths.isTestHarness(
            [:],
            xctestLoaded: false,
            executablePath: "/Applications/DirWiz.app/Contents/MacOS/DirWiz"
        ))
    }

    @Test("An explicit override always wins, harness or not")
    func overrideWins() {
        let base = DirWizOwnedPaths.applicationSupportBase(environment: [
            "DIRWIZ_APP_SUPPORT_DIR": "/tmp/x",
            "XCTestConfigurationFilePath": "/y",
        ])
        #expect(base == "/tmp/x")
        #expect(DirWizOwnedPaths.applicationSupportRoot(
            environment: ["DIRWIZ_APP_SUPPORT_DIR": "/tmp/x"]) == "/tmp/x/DirWiz")
    }

    @Test("Under a harness with no override, the fallback is never the real location")
    func harnessFallbackAvoidsRealAppSupport() {
        let harnessEnv = ["XCTestConfigurationFilePath": "/anything"]
        let base = DirWizOwnedPaths.applicationSupportBase(environment: harnessEnv)
        #expect(base.contains("DirWizTestFallbackAppSupport"))
        #expect(!base.hasPrefix(NSHomeDirectory() + "/Library/Application Support"),
                "a test-harness fallback under the real store defeats the guard")
        // Stable within one process: a straggler finishing after its suite restored
        // the env lands in the same sandbox, not a fresh one per resolution.
        #expect(base == DirWizOwnedPaths.applicationSupportBase(environment: harnessEnv))
        // The runtime probe alone must also redirect - SwiftPM's swift-testing runner
        // sets no XCTest environment, which is exactly how the original litter escaped.
        #expect(DirWizOwnedPaths.isTestHarness([:], xctestLoaded: true))
        #expect(DirWizOwnedPaths.applicationSupportBase(environment: [:])
                    .contains("DirWizTestFallbackAppSupport"),
                "default resolution inside a test process must self-redirect")
    }

    @Test("Production resolution without harness signals is unchanged")
    func productionFallback() {
        #expect(!DirWizOwnedPaths.isTestHarness(
            [:],
            xctestLoaded: false,
            executablePath: "/Applications/DirWiz.app/Contents/MacOS/DirWiz"
        ))
        let base = DirWizOwnedPaths.applicationSupportBase(
            environment: [:], testHarness: false)
        #expect(base.hasSuffix("/Library/Application Support"))
    }
}

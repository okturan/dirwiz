import Foundation

/// Paths written by DirWiz itself while a volume is being watched.
///
/// A root-volume FSEvents stream includes the app's own TreeCache, warm history, and
/// snapshot files under Application Support. Feeding those events back into the living
/// view would schedule another refresh merely because the previous one completed.
public enum DirWizOwnedPaths {
    public static let appSupportOverrideEnv = "DIRWIZ_APP_SUPPORT_DIR"

    /// The single Application Support BASE resolution every DirWiz store must use
    /// (TreeCache, SnapshotStore, TemporalSnapshot, WarmStartHistory) - callers append
    /// their own "DirWiz/<sub>" component. Centralized because the override-or-real
    /// logic used to exist in five copies, and only this copy can enforce the rule
    /// below.
    ///
    /// Under a test harness the fallback is NEVER the real Application Support. Suites
    /// isolate via `DIRWIZ_APP_SUPPORT_DIR`, but that env travels by `setenv`: a scan's
    /// detached completion work (history record, cache save, auto-checkpoint) can
    /// outlive the suite body and resolve paths AFTER the override was restored - which
    /// littered the developer's real store with 550+ fixture-keyed entries before this
    /// guard existed. Those stragglers, and any suite that forgets the override, land
    /// in one per-process temp directory instead.
    public static func applicationSupportBase(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        testHarness: Bool? = nil
    ) -> String {
        if let override = environment[appSupportOverrideEnv], !override.isEmpty {
            return override
        }
        if testHarness ?? isTestHarness(environment) {
            return NSTemporaryDirectory()
                + "DirWizTestFallbackAppSupport-\(ProcessInfo.processInfo.processIdentifier)"
        }
        return FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path
            ?? NSHomeDirectory() + "/Library/Application Support"
    }

    /// True when this process is a test runner. Checked only when no explicit override
    /// is set, so production, the CLI, and direct .build binary runs are unaffected.
    ///
    /// SwiftPM's swift-testing runner (`swiftpm-testing-helper`) sets NO XCTest
    /// environment at all - verified empirically, and pinned by the isolation suite -
    /// so environment signals alone are insufficient. The runtime probe covers it:
    /// XCTest is linked into every test process but never into the app or CLI.
    /// `xctestLoaded` is injectable because the probe is true for the entire test run,
    /// which would otherwise make the non-harness branches untestable.
    public static func isTestHarness(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        xctestLoaded: Bool = xctestRuntimeLoaded
    ) -> Bool {
        environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || xctestLoaded
    }

    /// Whether XCTest is present in this process - resolved once; class lookup is not
    /// free and the answer cannot change after launch.
    public static let xctestRuntimeLoaded = NSClassFromString("XCTestCase") != nil

    public static func applicationSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        canonicalize(applicationSupportBase(environment: environment) + "/DirWiz")
    }

    /// Boundary-aware containment using the same `/private/var` spelling FSEvents emits.
    public static func contains(_ path: String, under root: String) -> Bool {
        let candidate = canonicalize(path)
        let canonicalRoot = canonicalize(root)
        return candidate == canonicalRoot
            || candidate.hasPrefix(canonicalRoot + "/")
    }

    private static func canonicalize(_ path: String) -> String {
        let standardized = (path as NSString).standardizingPath
        if standardized == "/var" {
            return "/private/var"
        }
        if standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        return standardized
    }
}

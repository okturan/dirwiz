import Foundation

/// Paths written by DirWiz itself while a volume is being watched.
///
/// A root-volume FSEvents stream includes the app's own TreeCache, warm history, and
/// snapshot files under Application Support. Feeding those events back into the living
/// view would schedule another refresh merely because the previous one completed.
public enum DirWizOwnedPaths {
    public static let appSupportOverrideEnv = "DIRWIZ_APP_SUPPORT_DIR"

    public static func applicationSupportRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let base: String
        if let override = environment[appSupportOverrideEnv], !override.isEmpty {
            base = override
        } else {
            base = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?.path
                ?? NSHomeDirectory() + "/Library/Application Support"
        }
        return canonicalize(base + "/DirWiz")
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

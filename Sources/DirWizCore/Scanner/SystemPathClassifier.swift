/// Classifies paths under macOS-managed, SIP-protected locations where user cleanup
/// is impossible or meaningless (trash fails under SIP; the OS owns the lifecycle).
public enum SystemPathClassifier {
    /// Path prefixes (boundary-respecting — each ends with "/", so a merely-textual
    /// prefix like "/Systemx/" can never match) considered system-managed.
    /// Conservative list — expand deliberately, with a test per entry:
    ///   /System/                     — sealed system volume + Preboot/Cryptexes via firmlinks
    ///   /private/var/db/             — OS databases (dyld caches, ConfigurationProfiles…)
    ///   /Library/Apple/               — Apple-managed support (e.g. Rosetta)
    ///   /usr/ (EXCEPT /usr/local/)   — OS binaries; /usr/local is user territory
    private static let systemPrefixes: [String] = [
        "/System/",
        "/private/var/db/",
        "/Library/Apple/",
        "/usr/",
    ]

    private static let systemPrefixExceptions: [String] = [
        "/usr/local/",
    ]

    /// Whether `path` falls under a system-managed prefix (and not one of its exceptions).
    public static func isSystemManaged(_ path: String) -> Bool {
        guard systemPrefixes.contains(where: { path.hasPrefix($0) }) else { return false }
        return !systemPrefixExceptions.contains(where: { path.hasPrefix($0) })
    }

    /// A group is system-managed when EVERY path in it is (mixed groups stay actionable:
    /// the user-side copies are legitimately trashable).
    public static func isSystemManagedGroup(paths: [String]) -> Bool {
        guard !paths.isEmpty else { return false }
        return paths.allSatisfy(isSystemManaged)
    }
}

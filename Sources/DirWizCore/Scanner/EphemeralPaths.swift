import Darwin
import Foundation

/// The per-user Darwin roots whose contents churn continuously but do not need to be
/// accurate in the first, interactive tier of a warm patch.
///
/// Discovery is OS-owned: `_CS_DARWIN_USER_TEMP_DIR` and
/// `_CS_DARWIN_USER_CACHE_DIR` are resolved with `confstr` instead of guessing the
/// `/var/folders` layout. The pure initializer and resolver-injected `discover` entry
/// point keep every classification branch testable without consulting the host.
///
/// FAILS OPEN: both roots must resolve to safe absolute paths. If either lookup fails,
/// the result is empty and warm patches behave exactly as they did before ephemeral
/// deferral. This type only classifies patch targets; cold scans still enumerate and
/// count every root in full.
///
/// `~/Library/Caches` is deliberately NOT included. Unlike Darwin's private cache root,
/// it is a user-visible source of disk bloat that people reasonably expect a disk
/// analyzer to refresh interactively. Only the two roots explicitly supplied by macOS
/// through `confstr` are classified as ephemeral.
public struct EphemeralPaths: Equatable, Sendable {
    public enum DirectoryKind: Equatable, Sendable {
        case darwinUserTemporary
        case darwinUserCache
    }

    /// Set to `1` to restore the pre-deferral warm-patch schedule without a rebuild.
    public static let killSwitchEnv = "DIRWIZ_NO_EPHEMERAL_DEFER"

    public let darwinUserTemporaryRoot: String?
    public let darwinUserCacheRoot: String?

    /// Canonical roots use `/private/var`, matching FSEvents paths, and never end in `/`.
    public let canonicalRoots: Set<String>

    /// Pure construction from injected `confstr` results.
    ///
    /// This is intentionally all-or-nothing. A missing or malformed result means no
    /// target is classified as ephemeral, rather than silently operating with a partial
    /// policy whose behavior varies with the host.
    public init(
        darwinUserTemporaryDirectory: String?,
        darwinUserCacheDirectory: String?
    ) {
        guard
            let temporary = Self.canonicalizeDarwinPath(darwinUserTemporaryDirectory),
            let cache = Self.canonicalizeDarwinPath(darwinUserCacheDirectory)
        else {
            darwinUserTemporaryRoot = nil
            darwinUserCacheRoot = nil
            canonicalRoots = []
            return
        }
        darwinUserTemporaryRoot = temporary
        darwinUserCacheRoot = cache
        canonicalRoots = [temporary, cache]
    }

    /// Resolves the two OS-owned directories through an injectable lookup.
    ///
    /// Tests inject fixed strings; production's `current` entry point supplies the real
    /// `confstr` lookup. The escape hatch is checked before resolving anything.
    public static func discover(
        environment: [String: String],
        resolver: (DirectoryKind) -> String?
    ) -> EphemeralPaths {
        guard environment[killSwitchEnv] != "1" else {
            return EphemeralPaths(
                darwinUserTemporaryDirectory: nil,
                darwinUserCacheDirectory: nil
            )
        }
        return EphemeralPaths(
            darwinUserTemporaryDirectory: resolver(.darwinUserTemporary),
            darwinUserCacheDirectory: resolver(.darwinUserCache)
        )
    }

    /// Resolves the live per-user Darwin roots published by macOS.
    public static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> EphemeralPaths {
        discover(environment: environment) { kind in
            switch kind {
            case .darwinUserTemporary:
                return confstrValue(_CS_DARWIN_USER_TEMP_DIR)
            case .darwinUserCache:
                return confstrValue(_CS_DARWIN_USER_CACHE_DIR)
            }
        }
    }

    /// Whether `path` is one of the discovered roots or lies below one.
    ///
    /// Ancestors of an ephemeral root do not match: deferring such a target would also
    /// defer unrelated content. Boundary-aware descendant matching likewise prevents a
    /// root ending in `T` from accidentally matching a sibling named `T2`.
    public func contains(_ path: String) -> Bool {
        guard let candidate = Self.canonicalizeDarwinPath(path) else { return false }
        return canonicalRoots.contains { root in
            candidate == root || candidate.hasPrefix(root + "/")
        }
    }

    /// Splits the planner's already-collapsed targets without reordering either tier.
    ///
    /// Only an ephemeral root itself or one of its descendants moves to the trailing
    /// tier. An ancestor remains interactive because deferring it would also defer
    /// unrelated content, and splitting one planner target into smaller roots would
    /// change the planner's correctness contract rather than merely its schedule.
    public func partition(_ targets: [String]) -> WarmPatchTargetTiers {
        var interactive: [String] = []
        var ephemeral: [String] = []
        interactive.reserveCapacity(targets.count)
        ephemeral.reserveCapacity(min(targets.count, canonicalRoots.count))

        for target in targets {
            if contains(target) {
                ephemeral.append(target)
            } else {
                interactive.append(target)
            }
        }
        return WarmPatchTargetTiers(
            interactive: interactive,
            ephemeral: ephemeral
        )
    }

    private static func confstrValue(_ selector: Int32) -> String? {
        let requiredCount = confstr(selector, nil, 0)
        guard requiredCount > 1 else { return nil }

        var buffer = [CChar](repeating: 0, count: requiredCount)
        let writtenCount = confstr(selector, &buffer, buffer.count)
        guard writtenCount > 1, writtenCount <= buffer.count else { return nil }

        return buffer.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return nil }
            return String(validatingUTF8: baseAddress)
        }
    }

    /// Lexically normalizes the two path forms that otherwise make the policy a silent
    /// no-op: `confstr`'s trailing slash and its `/var` firmlink spelling versus the
    /// `/private/var` paths emitted by FSEvents.
    ///
    /// This stays lexical instead of resolving arbitrary filesystem symlinks, keeping
    /// injected decisions pure and independent of what happens to exist on the host.
    private static func canonicalizeDarwinPath(_ rawPath: String?) -> String? {
        // Check the raw spelling before `standardizingPath`: Foundation expands `~`
        // against the current user's home, which would turn a malformed non-absolute
        // `confstr` result into an apparently valid host-dependent path.
        guard let rawPath, rawPath.hasPrefix("/") else { return nil }
        let standardized = (rawPath as NSString).standardizingPath
        guard standardized.hasPrefix("/"), standardized != "/" else { return nil }

        if standardized == "/var" {
            return "/private/var"
        }
        if standardized.hasPrefix("/var/") {
            return "/private" + standardized
        }
        return standardized
    }
}

/// The two scheduling tiers of one warm patch. Both lists still belong to the same
/// replay window and together contain every planner target exactly once.
public struct WarmPatchTargetTiers: Equatable, Sendable {
    public let interactive: [String]
    public let ephemeral: [String]

    public init(interactive: [String], ephemeral: [String]) {
        self.interactive = interactive
        self.ephemeral = ephemeral
    }
}

import Foundation

/// Which mounted filesystems a scan intentionally includes.
///
/// The scope is part of a tree's identity: `/` scanned as one selected volume and `/`
/// scanned as a combined view have the same root path but describe different content.
public enum MountTraversalScope: UInt8, Codable, Equatable, Sendable {
    /// Stay on the scan root's device (`du -x` semantics).
    case selectedVolume = 0
    /// User explicitly requested one map spanning mounted filesystems.
    case combinedVolumes = 1
    /// Diagnostic compatibility mode selected by `DIRWIZ_CROSS_MOUNTS=1`.
    case unrestricted = 2

    public var crossesMounts: Bool {
        self != .selectedVolume
    }

    /// Pure resolver so the environment escape hatch can be pinned without mutating the
    /// process environment in parallel tests.
    public static func resolved(
        requested: MountTraversalScope,
        crossMountsEnvironmentValue: String?
    ) -> MountTraversalScope {
        crossMountsEnvironmentValue == "1" ? .unrestricted : requested
    }

    var cacheKeyComponent: String {
        switch self {
        case .selectedVolume: "selected-volume"
        case .combinedVolumes: "combined-volumes"
        case .unrestricted: "unrestricted"
        }
    }

    /// A stable identity for path-keyed persistence that must not mix trees built with
    /// different mount scopes. The ordinary selected-volume case deliberately remains
    /// the raw path so existing snapshots, sessions, and diagnostics remain compatible.
    public func persistenceIdentity(for rootPath: String) -> String {
        switch self {
        case .selectedVolume:
            rootPath
        case .combinedVolumes:
            "\(rootPath)|dirwiz-mount-scope=combined-volumes"
        case .unrestricted:
            "\(rootPath)|dirwiz-mount-scope=unrestricted"
        }
    }
}

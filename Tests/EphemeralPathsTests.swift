import Foundation
import Testing
@testable import DirWizCore

@Suite("EphemeralPaths Tests")
struct EphemeralPathsTests {
    private let confstrTemporary = "/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T/"
    private let confstrCache = "/var/folders/9_/53r7j1md2hq5x1_n0000000000000/C/"

    private func discovered(
        environment: [String: String] = [:]
    ) -> EphemeralPaths {
        EphemeralPaths.discover(environment: environment) { kind in
            switch kind {
            case .darwinUserTemporary:
                return confstrTemporary
            case .darwinUserCache:
                return confstrCache
            }
        }
    }

    @Test("confstr trailing slash and var firmlink spelling canonicalize to FSEvents paths")
    func canonicalizesConfstrPathsForFSEvents() {
        let paths = discovered()

        #expect(paths.canonicalRoots == [
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T",
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/C",
        ])
        #expect(
            paths.darwinUserTemporaryRoot
                == "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T"
        )
        #expect(
            paths.darwinUserCacheRoot
                == "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/C"
        )

        // FSEvents reports the real `/private/var` side, not the `/var` spelling
        // returned by `confstr`. This is the production-shaped match that must not
        // silently become a no-op.
        #expect(paths.contains(
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T"
        ))
        #expect(paths.contains(
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T/com.apple.app/session"
        ))
        #expect(paths.contains(confstrCache))
    }

    @Test("Matching is descendant- and component-boundary-aware")
    func matchesOnlyRootsAndDescendants() {
        let paths = discovered()

        #expect(!paths.contains(
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000"
        ))
        #expect(!paths.contains(
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T2"
        ))
        #expect(!paths.contains("/private/var/folders/another-user/T"))
    }

    @Test("Any failed or unsafe confstr result fails open")
    func resolutionFailureFailsOpen() {
        let missingTemporary = EphemeralPaths(
            darwinUserTemporaryDirectory: nil,
            darwinUserCacheDirectory: confstrCache
        )
        let missingCache = EphemeralPaths(
            darwinUserTemporaryDirectory: confstrTemporary,
            darwinUserCacheDirectory: nil
        )
        let relativeTemporary = EphemeralPaths(
            darwinUserTemporaryDirectory: "var/folders/user/T/",
            darwinUserCacheDirectory: confstrCache
        )
        let rootCache = EphemeralPaths(
            darwinUserTemporaryDirectory: confstrTemporary,
            darwinUserCacheDirectory: "/"
        )
        let tildeCache = EphemeralPaths(
            darwinUserTemporaryDirectory: confstrTemporary,
            darwinUserCacheDirectory: "~/Library/Caches/"
        )

        #expect(missingTemporary.canonicalRoots.isEmpty)
        #expect(missingCache.canonicalRoots.isEmpty)
        #expect(relativeTemporary.canonicalRoots.isEmpty)
        #expect(rootCache.canonicalRoots.isEmpty)
        #expect(tildeCache.canonicalRoots.isEmpty)
    }

    @Test("User Library Caches stays interactive")
    func userLibraryCachesIsNotEphemeral() {
        let paths = discovered()

        // This is an intentional product boundary, not an omission: users hunt for
        // cache bloat here and can reasonably expect it to be fresh in a disk analyzer.
        #expect(!paths.contains("/Users/test/Library/Caches"))
        #expect(!paths.contains("/Users/test/Library/Caches/com.example.large-cache"))
    }

    @Test("DIRWIZ_NO_EPHEMERAL_DEFER disables discovery before lookup")
    func escapeHatchDisablesDiscovery() {
        var didResolve = false
        let paths = EphemeralPaths.discover(
            environment: [EphemeralPaths.killSwitchEnv: "1"]
        ) { _ in
            didResolve = true
            return "/var/folders/user/T/"
        }

        #expect(paths.canonicalRoots.isEmpty)
        #expect(!didResolve)
    }

    @Test("Only the exact escape-hatch value 1 disables discovery")
    func escapeHatchRequiresOne() {
        #expect(discovered(environment: [EphemeralPaths.killSwitchEnv: "0"])
            .canonicalRoots.count == 2)
        #expect(discovered(environment: [EphemeralPaths.killSwitchEnv: "true"])
            .canonicalRoots.count == 2)
    }

    @Test("Warm patch targets partition into stable interactive and trailing tiers")
    func partitionsTargetsWithoutReordering() {
        let paths = discovered()
        let result = paths.partition([
            "/Users/test/Documents",
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T",
            "/Applications",
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/C/com.example",
        ])

        #expect(result.interactive == [
            "/Users/test/Documents",
            "/Applications",
        ])
        #expect(result.ephemeral == [
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/T",
            "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000/C/com.example",
        ])
    }

    @Test("An ancestor containing an ephemeral root remains interactive")
    func ancestorRemainsInteractive() {
        let paths = discovered()
        let ancestor = "/private/var/folders/9_/53r7j1md2hq5x1_n0000000000000"

        #expect(paths.partition([ancestor]) == WarmPatchTargetTiers(
            interactive: [ancestor],
            ephemeral: []
        ))
    }

    @Test("Fail-open discovery keeps the pre-deferral one-tier schedule")
    func failedDiscoveryKeepsEveryTargetInteractive() {
        let paths = EphemeralPaths(
            darwinUserTemporaryDirectory: nil,
            darwinUserCacheDirectory: nil
        )
        let targets = ["/one", "/two", "/three"]

        #expect(paths.partition(targets) == WarmPatchTargetTiers(
            interactive: targets,
            ephemeral: []
        ))
    }
}

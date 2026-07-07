import Foundation

// MARK: - Models

/// Safety rating for a space category.
public enum SafetyRating: String, Sendable, CaseIterable {
    case safe           // Can be deleted without data loss
    case caution        // May affect app behavior, review first
    case informational  // Not recommended to delete
}

/// A categorized group of disk space usage.
public struct SpaceCategory: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let safetyRating: SafetyRating
    public var totalSize: UInt64
    public var fileCount: Int
    public var matchedPaths: [String]
}

/// Groups of space categories.
public enum SpaceCategoryGroup: String, Sendable, CaseIterable {
    case developerTools = "Developer Tools"
    case systemCaches = "System Caches"
    case applicationData = "Application Data"
    case systemData = "System Data"
    case logs = "Logs"
    case other = "Other"
}

public struct SpaceAnalysisResult: Sendable {
    public let categories: [SpaceCategory]
    public let totalAnalyzed: UInt64
    public let scanDate: Date

    public var categorizedSize: UInt64 {
        categories.reduce(0) { $0 + $1.totalSize }
    }
}

// MARK: - Category Definitions

private struct CategoryDefinition {
    let id: String
    let name: String
    let description: String
    let safetyRating: SafetyRating
    let group: SpaceCategoryGroup
    let pathSuffixes: [String]  // Suffixes relative to volume root (after rootPath)
}

/// All known category patterns. Order matters: first match wins, so more specific
/// patterns (e.g. SPM cache inside DerivedData) must come before broader ones.
private let categoryDefinitions: [CategoryDefinition] = [
    // Developer Tools — specific before general
    CategoryDefinition(
        id: "xcode_derived_data",
        name: "Xcode DerivedData",
        description: "Build artifacts that can be regenerated",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Developer/Xcode/DerivedData"]
    ),
    CategoryDefinition(
        id: "xcode_simulators",
        name: "Xcode iOS Simulators",
        description: "Simulator runtimes and data; re-downloadable",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Developer/CoreSimulator"]
    ),
    CategoryDefinition(
        id: "xcode_device_support",
        name: "Xcode Device Support",
        description: "Debug symbols for connected devices; re-downloadable",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: [
            "Library/Developer/Xcode/iOS DeviceSupport",
            "Library/Developer/Xcode/watchOS DeviceSupport",
            "Library/Developer/Xcode/tvOS DeviceSupport",
        ]
    ),
    CategoryDefinition(
        id: "xcode_archives",
        name: "Xcode Archives",
        description: "App build archives for distribution",
        safetyRating: .caution,
        group: .developerTools,
        pathSuffixes: ["Library/Developer/Xcode/Archives"]
    ),
    CategoryDefinition(
        id: "spm_cache",
        name: "Swift Package Manager Cache",
        description: "Resolved package checkouts; re-downloaded on build",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/org.swift.swiftpm"]
    ),
    CategoryDefinition(
        id: "cocoapods_cache",
        name: "CocoaPods Cache",
        description: "Downloaded pod specs and sources",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Caches/CocoaPods"]
    ),
    CategoryDefinition(
        id: "carthage_cache",
        name: "Carthage Cache",
        description: "Carthage build cache and frameworks",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Caches/org.carthage.CarthageKit"]
    ),
    CategoryDefinition(
        id: "homebrew_cache",
        name: "Homebrew Cache",
        description: "Downloaded package bottles and source tarballs",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Caches/Homebrew"]
    ),
    CategoryDefinition(
        id: "npm_cache",
        name: "npm Cache",
        description: "Cached npm packages; cleared with npm cache clean",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: [".npm", "Library/Caches/npm"]
    ),
    CategoryDefinition(
        id: "yarn_cache",
        name: "Yarn Cache",
        description: "Cached Yarn packages",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Caches/Yarn"]
    ),
    CategoryDefinition(
        id: "pip_cache",
        name: "pip Cache",
        description: "Cached Python packages",
        safetyRating: .safe,
        group: .developerTools,
        pathSuffixes: ["Library/Caches/pip"]
    ),
    CategoryDefinition(
        id: "docker_data",
        name: "Docker Data",
        description: "Docker images, containers, and volumes",
        safetyRating: .caution,
        group: .developerTools,
        pathSuffixes: ["Library/Containers/com.docker.docker", ".docker"]
    ),

    // Browser Caches — before general Application Caches
    CategoryDefinition(
        id: "browser_caches",
        name: "Browser Caches",
        description: "Cached web content; automatically regenerated",
        safetyRating: .safe,
        group: .systemCaches,
        pathSuffixes: [
            "Library/Caches/Google/Chrome",
            "Library/Caches/com.apple.Safari",
            "Library/Caches/Firefox",
            "Library/Caches/com.google.Chrome",
            "Library/Caches/org.mozilla.firefox",
        ]
    ),

    // System Caches — general (after specific cache patterns)
    CategoryDefinition(
        id: "application_caches",
        name: "Application Caches",
        description: "App-specific cached data; usually safe to clear",
        safetyRating: .safe,
        group: .systemCaches,
        pathSuffixes: ["Library/Caches"]
    ),

    // Application Data
    CategoryDefinition(
        id: "mail_downloads",
        name: "Mail Downloads",
        description: "Attachments saved by Mail.app",
        safetyRating: .caution,
        group: .applicationData,
        pathSuffixes: ["Library/Containers/com.apple.mail/Data/Library/Mail Downloads"]
    ),
    CategoryDefinition(
        id: "application_support",
        name: "Application Support",
        description: "Persistent app data and configuration",
        safetyRating: .informational,
        group: .applicationData,
        pathSuffixes: ["Library/Application Support"]
    ),
    CategoryDefinition(
        id: "application_containers",
        name: "Application Containers",
        description: "Sandboxed app data (containers and group containers)",
        safetyRating: .informational,
        group: .applicationData,
        pathSuffixes: ["Library/Containers", "Library/Group Containers"]
    ),

    // Logs
    CategoryDefinition(
        id: "system_logs",
        name: "System Logs",
        description: "System and application log files",
        safetyRating: .safe,
        group: .logs,
        pathSuffixes: ["private/var/log", "Library/Logs"]
    ),

    // System Data
    CategoryDefinition(
        id: "spotlight_index",
        name: "Spotlight Index",
        description: "Search index maintained by macOS",
        safetyRating: .informational,
        group: .systemData,
        pathSuffixes: [".Spotlight-V100"]
    ),
    CategoryDefinition(
        id: "trash",
        name: "Trash",
        description: "Files in the Trash; can be emptied to reclaim space",
        safetyRating: .safe,
        group: .other,
        pathSuffixes: [".Trash"]
    ),
]

// MARK: - SpaceAnalyzer

public struct SpaceAnalyzer: Sendable {
    public init() {}

    /// Analyze a scanned FileTree and categorize disk space usage.
    /// Cancellation-aware — checks `Task.isCancelled` periodically.
    public func analyze(tree: FileTree) async -> SpaceAnalysisResult {
        let (nodes, stringPool, rootPath) = tree.pathBuildingSnapshot()
        guard !nodes.isEmpty else {
            return SpaceAnalysisResult(categories: [], totalAnalyzed: 0, scanDate: Date())
        }

        // Normalize rootPath: ensure no trailing slash for consistent suffix matching.
        let root = rootPath.hasSuffix("/") && rootPath.count > 1
            ? String(rootPath.dropLast())
            : rootPath

        // Resolve each category path suffix directly to a node instead of walking every
        // directory node in the tree and testing ~30 prefix matchers against each one.
        // Category prefixes are a small, fixed set of shallow locations, so descending to
        // them costs one FileTree.descendPath call each rather than an O(nodes) walk.
        var targets: [(catIndex: Int, nodeIndex: UInt32, componentCount: Int)] = []
        for (catIdx, def) in categoryDefinitions.enumerated() {
            for suffix in def.pathSuffixes {
                // Build absolute prefix from rootPath + suffix.
                // Handle both volume-root scans (rootPath="/") and user-dir scans (rootPath="/Users/foo").
                let absPrefix: String
                if root == "/" {
                    absPrefix = "/" + suffix
                } else {
                    absPrefix = root + "/" + suffix
                }
                // A prefix that isn't actually under rootPath (can't happen given the
                // construction above, but this mirrors iCloudAnalyzer's boundary-safe
                // derivation rather than assuming it) contributes nothing.
                guard let components = relativeComponents(of: absPrefix, from: rootPath) else { continue }
                guard let nodeIndex = FileTree.descendPath(components, nodes: nodes, stringPool: stringPool),
                      nodes[Int(nodeIndex)].isDirectory
                else {
                    // Unresolved (or resolved to a non-directory): this category isn't present
                    // in the scanned tree, so it contributes nothing. This is also where the old
                    // "direct child of an unclaimed prefix" branch is dropped — it only fired
                    // when a child's array index was lower than its parent's, which no real scan
                    // can produce (propagateSizes/sortAllChildren both rely on parent index <
                    // child index holding everywhere). See
                    // spaceAnalyzerNodeAnchoringIgnoresIndexInvertedLayouts for the accepted
                    // divergence this causes on that one synthetic, unreachable-in-practice shape.
                    continue
                }
                targets.append((catIndex: catIdx, nodeIndex: nodeIndex, componentCount: components.count))
            }
        }

        // Process shallowest-first so a structural ancestor (e.g. Library/Caches) claims its
        // whole subtree before a nested, more specific category (e.g. browser_caches) gets a
        // turn. On every root-to-leaf chain, parent index < child index (guaranteed elsewhere
        // in the codebase), so shallowest-first reproduces the old array-order-based shadowing
        // exactly. Ties preserve categoryDefinitions order via the original build-order index.
        let ordered = targets.enumerated()
            .sorted {
                $0.element.componentCount != $1.element.componentCount
                    ? $0.element.componentCount < $1.element.componentCount
                    : $0.offset < $1.offset
            }
            .map { $0.element }

        // Accumulators: one per category definition.
        var sizes = Array(repeating: UInt64(0), count: categoryDefinitions.count)
        var counts = Array(repeating: 0, count: categoryDefinitions.count)
        var topPaths: [[String]] = Array(repeating: [], count: categoryDefinitions.count)
        let maxMatchedPaths = 20

        // Track claimed nodes so we don't double-count when a shallower category's subtree
        // contains a deeper category's resolved node. We check ancestry: if any ancestor is
        // in `claimedRoots`, skip this node; also skip if this exact node was already claimed
        // by an earlier (shallower-or-equal, then definition-order) target.
        var claimedRoots = Set<UInt32>()

        for target in ordered {
            if Task.isCancelled { break }

            guard !claimedRoots.contains(target.nodeIndex),
                  !isDescendantOfClaimed(nodeIndex: target.nodeIndex, nodes: nodes, claimedRoots: claimedRoots)
            else { continue }

            let node = nodes[Int(target.nodeIndex)]
            let path = FileTree.pathFromSnapshot(
                at: target.nodeIndex, nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )
            sizes[target.catIndex] += node.displaySize
            counts[target.catIndex] += 1
            if topPaths[target.catIndex].count < maxMatchedPaths {
                topPaths[target.catIndex].append(path)
            }
            claimedRoots.insert(target.nodeIndex)
        }

        let totalAnalyzed = nodes[0].displaySize

        // Build result categories (only include non-empty ones).
        var categories: [SpaceCategory] = []
        for (idx, def) in categoryDefinitions.enumerated() {
            guard sizes[idx] > 0 else { continue }
            categories.append(SpaceCategory(
                id: def.id,
                name: def.name,
                description: def.description,
                safetyRating: def.safetyRating,
                totalSize: sizes[idx],
                fileCount: counts[idx],
                matchedPaths: topPaths[idx]
            ))
        }

        // Sort by size descending.
        categories.sort { $0.totalSize > $1.totalSize }

        return SpaceAnalysisResult(
            categories: categories,
            totalAnalyzed: totalAnalyzed,
            scanDate: Date()
        )
    }

    /// Check if a node is a descendant of any claimed root by walking up the parent chain.
    private func isDescendantOfClaimed(
        nodeIndex: UInt32,
        nodes: [FileNode],
        claimedRoots: Set<UInt32>
    ) -> Bool {
        var current = nodes[Int(nodeIndex)].parentIndex
        while current != FileNode.invalid {
            if claimedRoots.contains(current) { return true }
            let ci = Int(current)
            guard ci < nodes.count else { break }
            current = nodes[ci].parentIndex
        }
        return false
    }

    /// Path components of `child` relative to `ancestor`, when `ancestor` is `child` itself
    /// or a path-boundary-respecting prefix of it. Returns nil when `ancestor` is not an
    /// ancestor of (or equal to) `child` — including a merely-textual prefix match with no
    /// "/" boundary. Mirrors `iCloudAnalyzer.relativeComponents(of:from:)`; kept as a local
    /// copy so the two analyzers stay decoupled.
    private func relativeComponents(of child: String, from ancestor: String) -> [String]? {
        guard child.hasPrefix(ancestor) else { return nil }
        var rest = child.dropFirst(ancestor.count)
        if ancestor.hasSuffix("/") {
            // Boundary already consumed by the trailing slash (also covers ancestor == "/").
        } else if rest.isEmpty {
            // child == ancestor exactly.
        } else if rest.first == "/" {
            rest = rest.dropFirst()
        } else {
            return nil
        }
        return rest.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }
}

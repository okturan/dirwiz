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

        // Build the set of absolute path prefixes to match for each category.
        // Each entry: (absolutePrefix, categoryIndex).
        var matchers: [(prefix: String, catIndex: Int)] = []
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
                matchers.append((absPrefix, catIdx))
            }
        }

        // Accumulators: one per category definition.
        var sizes = Array(repeating: UInt64(0), count: categoryDefinitions.count)
        var counts = Array(repeating: 0, count: categoryDefinitions.count)
        var topPaths: [[String]] = Array(repeating: [], count: categoryDefinitions.count)
        let maxMatchedPaths = 20

        // Track nodes whose subtrees are already counted so we don't double-count
        // when a parent directory matched a category and its children also match.
        // We mark a node index when its displaySize is added to a category; any
        // descendant of that node should be skipped.
        //
        // Instead of storing all descendant indices, we check ancestry: if any
        // ancestor is in `claimedRoots`, skip this node.
        var claimedRoots = Set<UInt32>()

        // Cancellation check interval — every 50k nodes.
        let cancelCheckInterval = 50_000
        var totalAnalyzed: UInt64 = 0

        for i in 0..<nodes.count {
            if i % cancelCheckInterval == 0, Task.isCancelled { break }

            let node = nodes[i]
            totalAnalyzed = max(totalAnalyzed, nodes[0].displaySize)

            // Skip non-directory leaf files and directories with no size.
            // We only match directories at the "entry point" level.
            guard node.isDirectory else { continue }

            // Check if this node is already inside a claimed subtree.
            if isDescendantOfClaimed(nodeIndex: UInt32(i), nodes: nodes, claimedRoots: claimedRoots) {
                continue
            }

            // Build the path for this node.
            let path = FileTree.pathFromSnapshot(
                at: UInt32(i), nodes: nodes, stringPool: stringPool, rootPath: rootPath
            )

            // Try to match against category prefixes.
            // A match means the node's path equals the prefix or is a direct child-level
            // entry (e.g., DerivedData/MyProject-xxx).
            for (prefix, catIdx) in matchers {
                if path == prefix || path.hasPrefix(prefix + "/") {
                    // This directory falls under this category.
                    // If the path exactly equals the prefix, add its full displaySize.
                    // If it's a subdirectory of the prefix and the prefix dir itself wasn't
                    // scanned as a separate node, also add it.

                    // Check: is this node the prefix directory itself, or a deeper one?
                    if path == prefix {
                        // Exact match — add full subtree size.
                        sizes[catIdx] += node.displaySize
                        counts[catIdx] += 1
                        if topPaths[catIdx].count < maxMatchedPaths {
                            topPaths[catIdx].append(path)
                        }
                        claimedRoots.insert(UInt32(i))
                    } else {
                        // This node is inside the category prefix.
                        // Only count it if the prefix directory itself is NOT a node in the tree
                        // (i.e., we haven't already claimed the prefix root). If the prefix root
                        // exists and was claimed, we skip (descendant check above handles it).
                        // If we get here, the prefix root wasn't in the tree or wasn't claimed,
                        // so count direct children of the prefix as individual entries.
                        let depth = path.dropFirst(prefix.count + 1)  // after "prefix/"
                        if !depth.contains("/") {
                            // Direct child of the category prefix.
                            sizes[catIdx] += node.displaySize
                            counts[catIdx] += 1
                            if topPaths[catIdx].count < maxMatchedPaths {
                                topPaths[catIdx].append(path)
                            }
                            claimedRoots.insert(UInt32(i))
                        }
                    }
                    break  // First matching category wins.
                }
            }
        }

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
}

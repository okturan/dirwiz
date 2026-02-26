import Testing
import Foundation
@testable import DirWizLib

// MARK: - Build helpers

/// Build a minimal flat-array node snapshot suitable for color resolver tests.
/// Index 0 is the root directory. Subsequent indices are the provided children.
private func makeNodes(
    rootIsDir: Bool = true,
    children: [(isDir: Bool, fileSize: UInt64, extensionHash: UInt32,
                firstChildIndex: UInt32, childCount: UInt32)]
) -> [FileNode] {
    var nodes: [FileNode] = []

    // Root node
    var root = FileNode()
    root.isDirectory = rootIsDir
    root.parentIndex = FileNode.invalid
    if !children.isEmpty {
        root.firstChildIndex = 1
        root.childCount = UInt32(children.count)
    }
    nodes.append(root)

    for (i, c) in children.enumerated() {
        var node = FileNode()
        node.isDirectory = c.isDir
        node.fileSize = c.fileSize
        node.extensionHash = c.extensionHash
        node.parentIndex = 0
        node.firstChildIndex = c.firstChildIndex
        node.childCount = c.childCount
        _ = i  // suppress unused warning
        nodes.append(node)
    }
    return nodes
}

/// Convenience: root directory with flat file children (no grandchildren).
/// Children are always plain files (not directories).
private func makeFileChildren(
    _ files: [(fileSize: UInt64, extensionHash: UInt32)]
) -> [FileNode] {
    let children = files.map { f in
        (isDir: false, fileSize: f.fileSize, extensionHash: f.extensionHash,
         firstChildIndex: FileNode.invalid, childCount: UInt32(0))
    }
    return makeNodes(children: children)
}

/// Build a `TreemapRect` with the minimum required fields.
private func makeRect(
    nodeIndex: UInt32,
    depth: Int = 0
) -> TreemapRect {
    TreemapRect(
        nodeIndex: nodeIndex,
        x: 0, y: 0, width: 100, height: 100,
        depth: depth
    )
}

/// Build a populated `ExtensionPalette` from (name, hash, bytes) tuples.
private func makePalette(
    _ entries: [(name: String, hash: UInt32, bytes: UInt64)]
) -> ExtensionPalette {
    var palette = ExtensionPalette()
    let stats = entries.map { e in
        FileTypeStat(
            extensionName: e.name,
            extensionHash: e.hash,
            category: .other,
            totalSize: e.bytes,
            fileCount: 1,
            percentage: 0
        )
    }
    palette.assign(from: stats)
    return palette
}

// MARK: - TreemapColorResolver Tests

@Suite("TreemapColorResolver Tests")
struct TreemapColorResolverTests {

    // MARK: 1. Regular file returns palette color

    @Test("Regular file returns the palette color for its extensionHash")
    func regularFilePaletteColor() {
        let hash: UInt32 = 0xABCD_1234
        let palette = makePalette([("swift", hash, 1_000_000)])
        let expectedColor = palette.color(forHash: hash)

        let resolver = TreemapColorResolver(palette: palette)
        let nodes = makeFileChildren([(fileSize: 1_000_000, extensionHash: hash)])
        // Node index 1 is the file.
        let color = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        #expect(color.x == expectedColor.x)
        #expect(color.y == expectedColor.y)
        #expect(color.z == expectedColor.z)
        #expect(color.w == 1.0)
    }

    // MARK: 2. Directory without children returns depth-based gray/teal/purple

    @Test("Empty directory returns depth-based base color with alpha 1")
    func directoryNoChildrenBaseColor() {
        let resolver = TreemapColorResolver()

        // A lone directory node (no children).
        var dirNode = FileNode()
        dirNode.isDirectory = true
        dirNode.parentIndex = FileNode.invalid
        dirNode.firstChildIndex = FileNode.invalid
        dirNode.childCount = 0
        let nodes = [dirNode]

        for (depth, _) in [(0, "depth 0"), (2, "depth 2"), (5, "depth 5")] {
            let color = resolver.resolveColor(
                for: makeRect(nodeIndex: 0, depth: depth), nodes: nodes
            )
            // Alpha must be 1.0.
            #expect(color.w == 1.0, "Depth \(depth): alpha should be 1.0")
            // The color should be the directoryBaseColor at that depth, which is
            // low-saturation (all channels roughly similar and in [0.4, 0.6]).
            #expect(color.x > 0.0 && color.x < 1.0, "Depth \(depth): R in (0,1)")
            #expect(color.y > 0.0 && color.y < 1.0, "Depth \(depth): G in (0,1)")
            #expect(color.z > 0.0 && color.z < 1.0, "Depth \(depth): B in (0,1)")
        }
    }

    @Test("Directory base color differs across depth bands")
    func directoryBaseColorVariesByDepth() {
        let resolver = TreemapColorResolver()
        var dirNode = FileNode()
        dirNode.isDirectory = true
        dirNode.parentIndex = FileNode.invalid
        dirNode.firstChildIndex = FileNode.invalid
        let nodes = [dirNode]

        // depth 0 (blue-gray), depth 2 (teal), depth 4 (purple-gray) must all differ.
        let c0 = resolver.resolveColor(for: makeRect(nodeIndex: 0, depth: 0), nodes: nodes)
        let c2 = resolver.resolveColor(for: makeRect(nodeIndex: 0, depth: 2), nodes: nodes)
        let c4 = resolver.resolveColor(for: makeRect(nodeIndex: 0, depth: 4), nodes: nodes)

        // Each pair must differ in at least one channel.
        #expect(c0 != c2, "depth-0 and depth-2 base colors should differ")
        #expect(c2 != c4, "depth-2 and depth-4 base colors should differ")
        #expect(c0 != c4, "depth-0 and depth-4 base colors should differ")
    }

    // MARK: 3. Directory with one file child blends colors

    @Test("Directory with one file child blends dir base with dominant child color")
    func directoryWithFileChildBlend() {
        let hash: UInt32 = 0xCAFE_BABE
        let palette = makePalette([("jpg", hash, 5_000_000)])
        let resolver = TreemapColorResolver(palette: palette)

        // Nodes: 0=root dir, 1=file child.
        let nodes = makeFileChildren([(fileSize: 5_000_000, extensionHash: hash)])

        // Root (index 0) is a directory with one file child.
        let rect = makeRect(nodeIndex: 0, depth: 0)
        let blended = resolver.resolveColor(for: rect, nodes: nodes)

        // Pure directory color at depth 0.
        let pureDir = resolver.directoryBaseColor(depth: 0)
        let pureDirColor = SIMD4<Float>(pureDir.x, pureDir.y, pureDir.z, 1.0)

        // The blended color must differ from both the pure directory color and
        // the pure palette color, confirming that mixing occurred.
        let childColor = palette.color(forHash: hash)
        let blendedRGB = SIMD3<Float>(blended.x, blended.y, blended.z)
        let dirRGB = SIMD3<Float>(pureDirColor.x, pureDirColor.y, pureDirColor.z)
        let childRGB = SIMD3<Float>(childColor.x, childColor.y, childColor.z)

        #expect(blendedRGB != dirRGB,  "Blended should differ from pure dir color")
        #expect(blendedRGB != childRGB, "Blended should differ from pure child color")

        // The blend factor is 0.65 toward child, so result = dir + 0.65*(child-dir).
        let expectedR = dirRGB.x + 0.65 * (childRGB.x - dirRGB.x)
        let expectedG = dirRGB.y + 0.65 * (childRGB.y - dirRGB.y)
        let expectedB = dirRGB.z + 0.65 * (childRGB.z - dirRGB.z)
        #expect(abs(blended.x - expectedR) < 0.0001)
        #expect(abs(blended.y - expectedG) < 0.0001)
        #expect(abs(blended.z - expectedB) < 0.0001)
    }

    // MARK: 4. Recency overlay disabled — alpha always 1.0

    @Test("Recency overlay disabled: alpha is 1.0 regardless of recencyFactors")
    func recencyOverlayDisabled() {
        let hash: UInt32 = 0x1111_2222
        let palette = makePalette([("png", hash, 1_000_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            recencyFactors: [0.0, 0.3, 0.7, 1.0],
            isRecencyOverlayEnabled: false
        )

        let nodes = makeFileChildren([(fileSize: 1_000, extensionHash: hash)])
        let color = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)
        #expect(color.w == 1.0, "Alpha must be 1.0 when overlay is disabled")
    }

    // MARK: 5. Recency overlay enabled, empty factors — alpha 1.0 (loading state)

    @Test("Recency overlay enabled with empty factors yields alpha 1.0")
    func recencyOverlayEnabledEmptyFactors() {
        let hash: UInt32 = 0x3333_4444
        let palette = makePalette([("mp4", hash, 1_000_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            recencyFactors: [],
            isRecencyOverlayEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 1_000, extensionHash: hash)])
        let color = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)
        #expect(color.w == 1.0, "Empty recency factors should produce alpha 1.0")
    }

    // MARK: 6. Recency overlay enabled, factor present — alpha equals the factor

    @Test("Recency overlay enabled: alpha equals recencyFactors[nodeIndex]")
    func recencyOverlayEnabledFactorPresent() {
        let hash: UInt32 = 0x5555_6666
        let palette = makePalette([("zip", hash, 1_000_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            recencyFactors: [1.0, 0.42],
            isRecencyOverlayEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 1_000, extensionHash: hash)])
        let color = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)
        #expect(abs(color.w - 0.42) < 0.0001, "Alpha should equal recencyFactors[1] = 0.42")
    }

    // MARK: 7. Recency overlay enabled, index out of bounds — alpha 0.0

    @Test("Recency overlay enabled: out-of-bounds nodeIndex yields alpha 0.0")
    func recencyOverlayOutOfBounds() {
        let hash: UInt32 = 0x7777_8888
        let palette = makePalette([("doc", hash, 1_000_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            recencyFactors: [0.9],
            isRecencyOverlayEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 1_000, extensionHash: hash)])
        // Request node index 1 which is beyond recencyFactors.
        let color = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)
        #expect(color.w == 0.0, "Out-of-bounds recency index should yield alpha 0.0")
    }

    // MARK: 8. Temporal diff .new — RGB shifts toward green tint (0.20, 0.82, 0.35)

    @Test("Temporal diff .new shifts RGB toward green tint")
    func temporalDiffNew() {
        let hash: UInt32 = 0xAAAA_BBBB
        let palette = makePalette([("swift", hash, 1_000_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.new.rawValue],
            temporalDiffStrengths: [0.0, 1.0],
            isTemporalDiffEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 1_000, extensionHash: hash)])
        let baseColor = palette.color(forHash: hash)
        let tinted = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        // t = 0.25 + 0.45 * 1.0 = 0.70 → tinted = base + 0.70 * (tint - base)
        let t: Float = 0.25 + 0.45 * 1.0
        let tint = SIMD3<Float>(0.20, 0.82, 0.35)
        let expectedR = baseColor.x + (tint.x - baseColor.x) * t
        let expectedG = baseColor.y + (tint.y - baseColor.y) * t
        let expectedB = baseColor.z + (tint.z - baseColor.z) * t

        #expect(abs(tinted.x - expectedR) < 0.0001, "R should shift toward green tint")
        #expect(abs(tinted.y - expectedG) < 0.0001, "G should shift toward green tint")
        #expect(abs(tinted.z - expectedB) < 0.0001, "B should shift toward green tint")
    }

    // MARK: 9. Temporal diff .grown — RGB shifts toward blue tint (0.20, 0.55, 0.95)

    @Test("Temporal diff .grown shifts RGB toward blue tint")
    func temporalDiffGrown() {
        let hash: UInt32 = 0xCCCC_DDDD
        let palette = makePalette([("rs", hash, 500_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.grown.rawValue],
            temporalDiffStrengths: [0.0, 0.8],
            isTemporalDiffEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 500_000, extensionHash: hash)])
        let baseColor = palette.color(forHash: hash)
        let tinted = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        let t: Float = 0.25 + 0.45 * 0.8
        let tint = SIMD3<Float>(0.20, 0.55, 0.95)
        let expectedR = baseColor.x + (tint.x - baseColor.x) * t
        let expectedG = baseColor.y + (tint.y - baseColor.y) * t
        let expectedB = baseColor.z + (tint.z - baseColor.z) * t

        #expect(abs(tinted.x - expectedR) < 0.0001)
        #expect(abs(tinted.y - expectedG) < 0.0001)
        #expect(abs(tinted.z - expectedB) < 0.0001)
    }

    // MARK: 10. Temporal diff .shrunk — RGB shifts toward orange tint (0.95, 0.72, 0.20)

    @Test("Temporal diff .shrunk shifts RGB toward orange tint")
    func temporalDiffShrunk() {
        let hash: UInt32 = 0xEEEE_FFFF
        let palette = makePalette([("go", hash, 750_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.shrunk.rawValue],
            temporalDiffStrengths: [0.0, 0.6],
            isTemporalDiffEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 750_000, extensionHash: hash)])
        let baseColor = palette.color(forHash: hash)
        let tinted = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        let t: Float = 0.25 + 0.45 * 0.6
        let tint = SIMD3<Float>(0.95, 0.72, 0.20)
        let expectedR = baseColor.x + (tint.x - baseColor.x) * t
        let expectedG = baseColor.y + (tint.y - baseColor.y) * t
        let expectedB = baseColor.z + (tint.z - baseColor.z) * t

        #expect(abs(tinted.x - expectedR) < 0.0001)
        #expect(abs(tinted.y - expectedG) < 0.0001)
        #expect(abs(tinted.z - expectedB) < 0.0001)
    }

    // MARK: 11. Temporal diff .deletedDescendants — RGB shifts toward red tint (0.90, 0.25, 0.25)

    @Test("Temporal diff .deletedDescendants shifts RGB toward red tint")
    func temporalDiffDeletedDescendants() {
        let hash: UInt32 = 0x0011_2233
        let palette = makePalette([("py", hash, 300_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.deletedDescendants.rawValue],
            temporalDiffStrengths: [0.0, 0.55],
            isTemporalDiffEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 300_000, extensionHash: hash)])
        let baseColor = palette.color(forHash: hash)
        let tinted = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        let t: Float = 0.25 + 0.45 * 0.55
        let tint = SIMD3<Float>(0.90, 0.25, 0.25)
        let expectedR = baseColor.x + (tint.x - baseColor.x) * t
        let expectedG = baseColor.y + (tint.y - baseColor.y) * t
        let expectedB = baseColor.z + (tint.z - baseColor.z) * t

        #expect(abs(tinted.x - expectedR) < 0.0001)
        #expect(abs(tinted.y - expectedG) < 0.0001)
        #expect(abs(tinted.z - expectedB) < 0.0001)
    }

    // MARK: 12. Temporal diff disabled — color unchanged even with diff data populated

    @Test("Temporal diff disabled: color is unchanged even when kinds array has data")
    func temporalDiffDisabled() {
        let hash: UInt32 = 0x4455_6677
        let palette = makePalette([("ts", hash, 200_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.new.rawValue],
            temporalDiffStrengths: [0.0, 1.0],
            isTemporalDiffEnabled: false
        )

        let nodes = makeFileChildren([(fileSize: 200_000, extensionHash: hash)])
        let expected = palette.color(forHash: hash)
        let actual = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        #expect(abs(actual.x - expected.x) < 0.0001, "R unchanged when diff disabled")
        #expect(abs(actual.y - expected.y) < 0.0001, "G unchanged when diff disabled")
        #expect(abs(actual.z - expected.z) < 0.0001, "B unchanged when diff disabled")
    }

    // MARK: 13. Out-of-bounds nodeIndex returns fallbackColor

    @Test("Out-of-bounds nodeIndex returns ExtensionPalette.fallbackColor")
    func outOfBoundsNodeIndex() {
        let resolver = TreemapColorResolver()
        // Only 1 node (index 0), request index 99.
        var root = FileNode()
        root.isDirectory = true
        root.parentIndex = FileNode.invalid
        let nodes = [root]

        let color = resolver.resolveColor(for: makeRect(nodeIndex: 99), nodes: nodes)
        let fallback = ExtensionPalette.fallbackColor
        #expect(color.x == fallback.x)
        #expect(color.y == fallback.y)
        #expect(color.z == fallback.z)
        #expect(color.w == fallback.w)
    }

    // MARK: Temporal diff .none — no tinting even when diff enabled

    @Test("Temporal diff kind .none: no tinting applied")
    func temporalDiffKindNone() {
        let hash: UInt32 = 0x8899_AABB
        let palette = makePalette([("json", hash, 100_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.none.rawValue],
            temporalDiffStrengths: [0.0, 1.0],
            isTemporalDiffEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 100_000, extensionHash: hash)])
        let expected = palette.color(forHash: hash)
        let actual = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        #expect(abs(actual.x - expected.x) < 0.0001)
        #expect(abs(actual.y - expected.y) < 0.0001)
        #expect(abs(actual.z - expected.z) < 0.0001)
    }

    // MARK: Temporal diff missing strength defaults to 0.5

    @Test("Temporal diff: missing strength defaults to 0.5")
    func temporalDiffMissingStrength() {
        let hash: UInt32 = 0xCCDD_EEFF
        let palette = makePalette([("rb", hash, 400_000)])
        let resolver = TreemapColorResolver(
            palette: palette,
            temporalDiffKinds: [TemporalDiffKind.none.rawValue, TemporalDiffKind.new.rawValue],
            temporalDiffStrengths: [],
            isTemporalDiffEnabled: true
        )

        let nodes = makeFileChildren([(fileSize: 400_000, extensionHash: hash)])
        let baseColor = palette.color(forHash: hash)
        let tinted = resolver.resolveColor(for: makeRect(nodeIndex: 1), nodes: nodes)

        // Default strength is 0.5.
        let t: Float = 0.25 + 0.45 * 0.5
        let tint = SIMD3<Float>(0.20, 0.82, 0.35)
        let expectedR = baseColor.x + (tint.x - baseColor.x) * t
        let expectedG = baseColor.y + (tint.y - baseColor.y) * t
        let expectedB = baseColor.z + (tint.z - baseColor.z) * t

        #expect(abs(tinted.x - expectedR) < 0.0001)
        #expect(abs(tinted.y - expectedG) < 0.0001)
        #expect(abs(tinted.z - expectedB) < 0.0001)
    }
}

// MARK: - ExtensionPalette Tests

@Suite("ExtensionPalette Tests")
struct ExtensionPaletteTests {

    // MARK: 1. Empty input

    @Test("assign from empty array leaves palette empty; color returns fallback")
    func emptyInput() {
        var palette = ExtensionPalette()
        palette.assign(from: [])

        #expect(palette.entries.isEmpty, "Entries should be empty after assign(from: [])")
        // Any hash returns fallbackColor.
        let c = palette.color(forHash: 0x1234_5678)
        let fallback = ExtensionPalette.fallbackColor
        #expect(c.x == fallback.x)
        #expect(c.y == fallback.y)
        #expect(c.z == fallback.z)
        #expect(c.w == fallback.w)
    }

    // MARK: 2. Fewer than 17 extensions — all get distinct palette colors (not fallback)

    @Test("Fewer than 17 extensions all receive distinct palette colors")
    func fewerThan17Extensions() {
        var palette = ExtensionPalette()
        var stats: [FileTypeStat] = []
        for i in 0..<10 {
            stats.append(FileTypeStat(
                extensionName: "ext\(i)",
                extensionHash: UInt32(i + 1),
                category: .other,
                totalSize: UInt64(1000 + i * 100),
                fileCount: 1,
                percentage: 0
            ))
        }
        palette.assign(from: stats)

        // All 10 should be in entries (no "Other" aggregate because count < 17).
        #expect(palette.entries.count == 10)

        let fallback = ExtensionPalette.fallbackColor
        for stat in stats {
            let c = palette.color(forHash: stat.extensionHash)
            let isFallback = (c.x == fallback.x && c.y == fallback.y && c.z == fallback.z)
            #expect(!isFallback, "ext\(stat.extensionName) should not get fallback color")
        }

        // All assigned colors should be distinct.
        let colors = stats.map { palette.color(forHash: $0.extensionHash) }
        for i in 0..<colors.count {
            for j in (i+1)..<colors.count {
                let same = (colors[i].x == colors[j].x &&
                            colors[i].y == colors[j].y &&
                            colors[i].z == colors[j].z)
                #expect(!same, "Colors for index \(i) and \(j) should be distinct")
            }
        }
    }

    // MARK: 3. Exactly 17 extensions — all 17 get palette colors; none get fallback

    @Test("Exactly 17 extensions all receive palette colors, none get fallback")
    func exactly17Extensions() {
        var palette = ExtensionPalette()
        var stats: [FileTypeStat] = []
        for i in 0..<17 {
            stats.append(FileTypeStat(
                extensionName: "x\(i)",
                extensionHash: UInt32(100 + i),
                category: .other,
                totalSize: UInt64(500 + i),
                fileCount: 1,
                percentage: 0
            ))
        }
        palette.assign(from: stats)

        // Exactly 17 entries — no "Other" row.
        #expect(palette.entries.count == 17, "Should have exactly 17 entries")

        let fallback = ExtensionPalette.fallbackColor
        for stat in stats {
            let c = palette.color(forHash: stat.extensionHash)
            let isFallback = (c.x == fallback.x && c.y == fallback.y && c.z == fallback.z)
            #expect(!isFallback, "\(stat.extensionName) should not get fallback")
        }
    }

    // MARK: 4. More than 17 extensions — top 17 by bytes get palette; rest get fallback

    @Test("More than 17 extensions: top 17 get palette, 18th+ get fallback")
    func moreThan17Extensions() {
        var palette = ExtensionPalette()
        var stats: [FileTypeStat] = []
        // 20 extensions, sizes 1000 down to 81 (descending, unique).
        for i in 0..<20 {
            stats.append(FileTypeStat(
                extensionName: "y\(i)",
                extensionHash: UInt32(200 + i),
                category: .other,
                totalSize: UInt64(1000 - i * 10),
                fileCount: 1,
                percentage: 0
            ))
        }
        palette.assign(from: stats)

        // 17 named entries + 1 "Other" aggregate row = 18.
        #expect(palette.entries.count == 18, "Should have 17 real entries + 1 Other")

        let fallback = ExtensionPalette.fallbackColor
        for i in 0..<17 {
            let c = palette.color(forHash: UInt32(200 + i))
            let isFallback = (c.x == fallback.x && c.y == fallback.y && c.z == fallback.z)
            #expect(!isFallback, "top-17 extension y\(i) should not get fallback")
        }
        for i in 17..<20 {
            let c = palette.color(forHash: UInt32(200 + i))
            let isFallback = (c.x == fallback.x && c.y == fallback.y && c.z == fallback.z)
            #expect(isFallback, "extension y\(i) (rank \(i)) should get fallback")
        }
    }

    // MARK: 5. Sorted by size — largest extension gets palette index 0

    @Test("Largest extension by bytes receives palette index 0 color")
    func sortedBySize() {
        var palette = ExtensionPalette()
        // Deliberately out-of-order sizes.
        let stats = [
            FileTypeStat(extensionName: "small", extensionHash: 0xAAAA_0001,
                         category: .other, totalSize: 100, fileCount: 1, percentage: 0),
            FileTypeStat(extensionName: "huge",  extensionHash: 0xAAAA_0002,
                         category: .other, totalSize: 999_999, fileCount: 1, percentage: 0),
            FileTypeStat(extensionName: "mid",   extensionHash: 0xAAAA_0003,
                         category: .other, totalSize: 50_000, fileCount: 1, percentage: 0),
        ]
        palette.assign(from: stats)

        // The first entry (index 0) should be "huge".
        #expect(palette.entries.first?.extensionName == "huge",
            "Largest extension should be first in entries")
        #expect(palette.entries.first?.id == 0xAAAA_0002)
    }

    // MARK: 6. swiftUIColor returns a non-clear color for a known hash

    @Test("swiftUIColor(forHash:) returns a non-clear color for a known hash")
    func swiftUIColorForKnownHash() {
        var palette = ExtensionPalette()
        let hash: UInt32 = 0xBBBB_CCCC
        let stats = [
            FileTypeStat(extensionName: "pdf", extensionHash: hash,
                         category: .documents, totalSize: 10_000, fileCount: 1, percentage: 0)
        ]
        palette.assign(from: stats)

        let color = palette.swiftUIColor(forHash: hash)
        // A non-clear SwiftUI Color can't easily be compared numerically here,
        // but we can verify the underlying SIMD color is not the fallback gray.
        let simd = palette.color(forHash: hash)
        let fallback = ExtensionPalette.fallbackColor
        let isFallback = (simd.x == fallback.x && simd.y == fallback.y && simd.z == fallback.z)
        #expect(!isFallback, "swiftUIColor for known hash should not use fallback gray")
        // Also confirm the Color itself is not .clear (which would be 0,0,0,0).
        #expect(simd.w == 1.0, "Alpha should be 1.0 for a palette color")
        _ = color  // ensure the SwiftUI Color was actually created without crash
    }

    // MARK: 7. entries — ordered largest-first, count matches assigned extensions

    @Test("entries are ordered largest-first and count matches assigned extensions")
    func entriesOrderAndCount() {
        var palette = ExtensionPalette()
        let stats = [
            FileTypeStat(extensionName: "c",  extensionHash: 0x0001,
                         category: .code, totalSize: 300, fileCount: 3, percentage: 0),
            FileTypeStat(extensionName: "a",  extensionHash: 0x0002,
                         category: .code, totalSize: 100, fileCount: 1, percentage: 0),
            FileTypeStat(extensionName: "b",  extensionHash: 0x0003,
                         category: .code, totalSize: 200, fileCount: 2, percentage: 0),
        ]
        palette.assign(from: stats)

        #expect(palette.entries.count == 3, "Three distinct extensions → three entries")

        // Entries should be in descending size order.
        let sizes = palette.entries.map { $0.totalSize }
        for i in 0..<sizes.count - 1 {
            #expect(sizes[i] >= sizes[i+1],
                "entries[\(i)].totalSize (\(sizes[i])) should be >= entries[\(i+1)].totalSize (\(sizes[i+1]))")
        }

        // Verify the ordering by name as a proxy for size.
        #expect(palette.entries[0].extensionName == "c", "Largest (c=300) should be first")
        #expect(palette.entries[1].extensionName == "b", "Middle (b=200) should be second")
        #expect(palette.entries[2].extensionName == "a", "Smallest (a=100) should be last")
    }

    // MARK: generation increments on assign

    @Test("generation increments on each assign() call")
    func generationIncrements() {
        var palette = ExtensionPalette()
        let initial = palette.generation
        palette.assign(from: [])
        #expect(palette.generation == initial + 1, "generation should increment on assign")
        palette.assign(from: [])
        #expect(palette.generation == initial + 2, "generation should increment again")
    }

    // MARK: unknown hash falls back

    @Test("color(forHash:) with unrecognized hash returns fallbackColor")
    func unknownHashReturnsFallback() {
        var palette = ExtensionPalette()
        let stats = [
            FileTypeStat(extensionName: "swift", extensionHash: 0xAAAA,
                         category: .code, totalSize: 500, fileCount: 1, percentage: 0)
        ]
        palette.assign(from: stats)

        let c = palette.color(forHash: 0xDEAD_BEEF)  // not assigned
        let fallback = ExtensionPalette.fallbackColor
        #expect(c.x == fallback.x && c.y == fallback.y && c.z == fallback.z)
    }

    // MARK: Other aggregate row has correct id

    @Test("Other aggregate row has id UInt32.max and correct extensionName")
    func otherAggregateRow() {
        var palette = ExtensionPalette()
        var stats: [FileTypeStat] = []
        for i in 0..<18 {
            stats.append(FileTypeStat(
                extensionName: "z\(i)",
                extensionHash: UInt32(300 + i),
                category: .other,
                totalSize: UInt64(1000 - i),
                fileCount: 1,
                percentage: 0
            ))
        }
        palette.assign(from: stats)

        let lastEntry = palette.entries.last
        #expect(lastEntry?.id == UInt32.max, "Other aggregate row id should be UInt32.max")
        #expect(lastEntry?.extensionName == "Other", "Other aggregate row name should be 'Other'")
    }
}

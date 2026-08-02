import Foundation
import DirWizCore
import simd

// MARK: - TreemapColorResolver

/// Resolves the display color for a treemap rect given the current overlays.
/// Encapsulates all color logic out of the render loop for clarity and testability.
struct TreemapColorResolver {
    let palette: ExtensionPalette
    let recencyFactors: [Float]
    let isRecencyOverlayEnabled: Bool
    let temporalDiffKinds: [UInt8]
    let temporalDiffStrengths: [Float]
    let isTemporalDiffEnabled: Bool

    init(
        palette: ExtensionPalette = ExtensionPalette(),
        recencyFactors: [Float] = [],
        isRecencyOverlayEnabled: Bool = false,
        temporalDiffKinds: [UInt8] = [],
        temporalDiffStrengths: [Float] = [],
        isTemporalDiffEnabled: Bool = false
    ) {
        self.palette = palette
        self.recencyFactors = recencyFactors
        self.isRecencyOverlayEnabled = isRecencyOverlayEnabled
        self.temporalDiffKinds = temporalDiffKinds
        self.temporalDiffStrengths = temporalDiffStrengths
        self.isTemporalDiffEnabled = isTemporalDiffEnabled
    }

    /// Convenience overload for tests and one-off calls - allocates a local scratch dict.
    func resolveColor(for rect: TreemapRect, nodes: [FileNode]) -> SIMD4<Float> {
        var scratch: [UInt32: UInt64] = [:]
        return resolveColor(for: rect, nodes: nodes, scratchSizeByExt: &scratch)
    }

    /// Compute the final RGBA color for one treemap rect.
    ///
    /// - Parameters:
    ///   - rect: The layout rect whose color is needed.
    ///   - nodes: The full node snapshot (same array used for layout).
    ///   - scratchSizeByExt: A caller-owned scratch dictionary reused across calls
    ///     to avoid per-call allocation. The caller must pass an empty (but capacity-
    ///     reserved) dict and reuse the same instance across loop iterations.
    /// - Returns: An sRGB RGBA color with alpha encoding either opacity (normal) or
    ///   recency factor (when recency overlay is active).
    func resolveColor(
        for rect: TreemapRect,
        nodes: [FileNode],
        scratchSizeByExt: inout [UInt32: UInt64]
    ) -> SIMD4<Float> {
        let nodeIdx = Int(rect.nodeIndex)
        guard nodeIdx < nodes.count else {
            return ExtensionPalette.fallbackColor
        }
        let node = nodes[nodeIdx]

        // Get base color from extension hash.
        var baseColor: SIMD4<Float>
        if node.isDirectory {
            let dirRGB = directoryBaseColor(depth: rect.depth)
            let dirColor = SIMD4<Float>(dirRGB.x, dirRGB.y, dirRGB.z, 1.0)
            if let dominantHash = dominantDirectFileExtensionHash(
                in: rect.nodeIndex,
                nodes: nodes,
                scratchSizeByExt: &scratchSizeByExt
            ) {
                let childColor = palette.color(forHash: dominantHash)
                baseColor = blend(dirColor, childColor, factor: 0.65)
            } else {
                baseColor = dirColor
            }
        } else {
            baseColor = palette.color(forHash: node.extensionHash)
        }

        return applyingOverlays(to: baseColor, nodeIndex: nodeIdx)
    }

    /// Folders-only representative colour for a directory's full descendant shape.
    ///
    /// The ordinary resolver intentionally keeps Cushion's historical direct-child
    /// directory colouring unchanged. Folders needs one additional signal: a directory
    /// whose immediate children are all directories must not remain grey until its files
    /// appear several levels later. Follow the largest-content branch until a file-bearing
    /// directory is reached, then blend that extension 65% into the directory base before
    /// applying the directory's own overlays. The downstream panel/collapse transforms are
    /// specified in terms of that 65% representative signal.
    func resolveFoldersRepresentativeColor(
        for directoryIndex: UInt32,
        depth: Int,
        nodes: [FileNode],
        scratchSizeByExt: inout [UInt32: UInt64]
    ) -> SIMD4<Float>? {
        guard let hash = representativeDescendantExtensionHash(
            in: directoryIndex,
            nodes: nodes,
            scratchSizeByExt: &scratchSizeByExt
        ) else { return nil }
        let directoryRGB = directoryBaseColor(depth: depth)
        let directoryColor = SIMD4<Float>(
            directoryRGB.x, directoryRGB.y, directoryRGB.z, 1.0
        )
        let representativeColor = blend(
            directoryColor,
            palette.color(forHash: hash),
            factor: 0.65
        )
        return applyingOverlays(
            to: representativeColor,
            nodeIndex: Int(directoryIndex)
        )
    }

    // MARK: - Internal Helpers

    /// Depth-based directory base color using subtle hue shifts.
    func directoryBaseColor(depth: Int) -> SIMD3<Float> {
        let h: Float  // hue in degrees
        let s: Float  // saturation
        let b: Float  // brightness
        if depth <= 1 {
            h = 210; s = 0.12; b = 0.55  // blue-gray
        } else if depth <= 3 {
            h = 180; s = 0.12; b = 0.50  // teal
        } else {
            h = 260; s = 0.10; b = 0.50  // purple-gray
        }
        return hsbToRGB(h: h, s: s, b: b)
    }

    /// Convert HSB (hue 0-360, saturation 0-1, brightness 0-1) to RGB.
    private func hsbToRGB(h: Float, s: Float, b: Float) -> SIMD3<Float> {
        let c = b * s
        let x = c * (1 - abs(fmodf(h / 60, 2) - 1))
        let m = b - c
        let r1, g1, b1: Float
        switch h {
        case ..<60:    r1 = c; g1 = x; b1 = 0
        case ..<120:   r1 = x; g1 = c; b1 = 0
        case ..<180:   r1 = 0; g1 = c; b1 = x
        case ..<240:   r1 = 0; g1 = x; b1 = c
        case ..<300:   r1 = x; g1 = 0; b1 = c
        default:       r1 = c; g1 = 0; b1 = x
        }
        return SIMD3<Float>(r1 + m, g1 + m, b1 + m)
    }

    /// Dominant extension among direct file children (by bytes). Uses snapshot array directly.
    /// Reuses scratchSizeByExt (passed as inout) to avoid per-call dictionary allocation.
    private func dominantDirectFileExtensionHash(
        in directoryIndex: UInt32,
        nodes: [FileNode],
        scratchSizeByExt: inout [UInt32: UInt64]
    ) -> UInt32? {
        let i = Int(directoryIndex)
        guard i < nodes.count else { return nil }
        let node = nodes[i]
        guard node.firstChildIndex != FileNode.invalid else { return nil }
        let start = Int(node.firstChildIndex)
        let end = min(start + Int(node.childCount), nodes.count)
        guard start < end else { return nil }

        scratchSizeByExt.removeAll(keepingCapacity: true)
        for childIndex in start..<end {
            let child = nodes[childIndex]
            guard !child.isDirectory else { continue }
            scratchSizeByExt[child.extensionHash, default: 0] += child.displaySize
        }

        return scratchSizeByExt.max(by: { $0.value < $1.value })?.key
    }

    /// Representative extension reached through the largest-content descendant branch.
    /// Direct files at each level are aggregated by extension and compared with the largest
    /// child directory. This is bounded by tree depth rather than subtree size, so it avoids
    /// allocating per-directory descendant maps on multi-million-node scans.
    func representativeDescendantExtensionHash(
        in directoryIndex: UInt32,
        nodes: [FileNode],
        scratchSizeByExt: inout [UInt32: UInt64]
    ) -> UInt32? {
        var current = directoryIndex
        var fallbackDirectHash: UInt32?
        var remainingDepthGuard = nodes.count

        while remainingDepthGuard > 0 {
            remainingDepthGuard -= 1
            let i = Int(current)
            guard i < nodes.count else { break }
            let directory = nodes[i]
            guard directory.isDirectory,
                  directory.firstChildIndex != FileNode.invalid else { break }

            let start = Int(directory.firstChildIndex)
            let end = min(start + Int(directory.childCount), nodes.count)
            guard start < end else { break }

            scratchSizeByExt.removeAll(keepingCapacity: true)
            var largestDirectory: (index: UInt32, bytes: UInt64)?
            for childIndex in start..<end {
                let child = nodes[childIndex]
                if child.isDirectory {
                    let candidate = (index: UInt32(childIndex), bytes: child.displaySize)
                    if let best = largestDirectory {
                        if candidate.bytes > best.bytes
                            || (candidate.bytes == best.bytes && candidate.index < best.index) {
                            largestDirectory = candidate
                        }
                    } else {
                        largestDirectory = candidate
                    }
                } else {
                    scratchSizeByExt[child.extensionHash, default: 0] += child.displaySize
                }
            }

            let direct = scratchSizeByExt.reduce(
                into: Optional<(hash: UInt32, bytes: UInt64)>.none
            ) { best, entry in
                if let currentBest = best {
                    if entry.value > currentBest.bytes
                        || (entry.value == currentBest.bytes && entry.key < currentBest.hash) {
                        best = (entry.key, entry.value)
                    }
                } else {
                    best = (entry.key, entry.value)
                }
            }
            if fallbackDirectHash == nil {
                fallbackDirectHash = direct?.hash
            }

            if let direct {
                if let largestDirectory {
                    if direct.bytes >= largestDirectory.bytes {
                        return direct.hash
                    }
                } else {
                    return direct.hash
                }
            }
            guard let next = largestDirectory else {
                return direct?.hash ?? fallbackDirectHash
            }
            current = next.index
        }

        return fallbackDirectHash
    }

    private func applyingOverlays(
        to color: SIMD4<Float>,
        nodeIndex: Int
    ) -> SIMD4<Float> {
        var result = color

        // Encode recency factor in alpha for shader desaturation.
        // While factors are still loading (empty array), show everything as fully recent.
        if isRecencyOverlayEnabled {
            result.w = recencyFactors.isEmpty ? 1.0
                : (nodeIndex < recencyFactors.count ? recencyFactors[nodeIndex] : 0.0)
        }

        // Apply temporal diff tinting by pre-blending in Swift (no shader changes needed).
        if isTemporalDiffEnabled, nodeIndex < temporalDiffKinds.count {
            let kind = TemporalDiffKind(rawValue: temporalDiffKinds[nodeIndex]) ?? .none
            if kind != .none {
                let strength = nodeIndex < temporalDiffStrengths.count
                    ? temporalDiffStrengths[nodeIndex] : 0.5
                let tint: SIMD3<Float>
                switch kind {
                case .new:                tint = SIMD3(0.20, 0.82, 0.35)
                case .grown:              tint = SIMD3(0.20, 0.55, 0.95)
                case .shrunk:             tint = SIMD3(0.95, 0.72, 0.20)
                case .deletedDescendants: tint = SIMD3(0.90, 0.25, 0.25)
                case .none:               tint = .zero
                }
                let t = 0.25 + 0.45 * strength
                result.x += (tint.x - result.x) * t
                result.y += (tint.y - result.y) * t
                result.z += (tint.z - result.z) * t
            }
        }

        return result
    }

    private func blend(_ a: SIMD4<Float>, _ b: SIMD4<Float>, factor t: Float) -> SIMD4<Float> {
        let clamped = max(0, min(1, t))
        return a + (b - a) * clamped
    }
}

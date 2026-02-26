import Foundation
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

        // Encode recency factor in alpha for shader desaturation.
        // While factors are still loading (empty array), show everything as fully recent.
        if isRecencyOverlayEnabled {
            baseColor.w = recencyFactors.isEmpty ? 1.0
                : (nodeIdx < recencyFactors.count ? recencyFactors[nodeIdx] : 0.0)
        }
        // else: baseColor.w stays 1.0 (set by palette / directory colors above)

        // Apply temporal diff tinting by pre-blending in Swift (no shader changes needed).
        if isTemporalDiffEnabled {
            if nodeIdx < temporalDiffKinds.count {
                let kind = TemporalDiffKind(rawValue: temporalDiffKinds[nodeIdx]) ?? .none
                if kind != .none {
                    let strength = nodeIdx < temporalDiffStrengths.count
                        ? temporalDiffStrengths[nodeIdx] : 0.5
                    let tint: SIMD3<Float>
                    switch kind {
                    case .new:                tint = SIMD3(0.20, 0.82, 0.35)
                    case .grown:              tint = SIMD3(0.20, 0.55, 0.95)
                    case .shrunk:             tint = SIMD3(0.95, 0.72, 0.20)
                    case .deletedDescendants: tint = SIMD3(0.90, 0.25, 0.25)
                    case .none:               tint = .zero
                    }
                    let t = 0.25 + 0.45 * strength
                    baseColor.x += (tint.x - baseColor.x) * t
                    baseColor.y += (tint.y - baseColor.y) * t
                    baseColor.z += (tint.z - baseColor.z) * t
                }
            }
        }

        return baseColor
    }

    // MARK: - Internal Helpers

    /// Depth-based directory base color using subtle hue shifts.
    private func directoryBaseColor(depth: Int) -> SIMD3<Float> {
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
            scratchSizeByExt[child.extensionHash, default: 0] += child.fileSize
        }

        return scratchSizeByExt.max(by: { $0.value < $1.value })?.key
    }

    private func blend(_ a: SIMD4<Float>, _ b: SIMD4<Float>, factor t: Float) -> SIMD4<Float> {
        let clamped = max(0, min(1, t))
        return a + (b - a) * clamped
    }
}

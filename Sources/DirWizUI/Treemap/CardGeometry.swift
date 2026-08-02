import Foundation

/// How the treemap paints its rectangles.
///
/// Both styles consume the SAME `SquarifyLayout` output - this only changes painting, never
/// geometry, so zoom, breadcrumbs and the spatial index keep working off one set of rects.
public enum TreemapRenderStyle: String, CaseIterable, Sendable {
    /// Wijk/van de Wetering cushions: hierarchy is conveyed by *lighting* (ridges baked
    /// into each leaf's coefficients), so it costs zero pixels and survives extreme density.
    case cushion
    /// Rounded cards with gaps: hierarchy is conveyed by *geometry*, which reads better but
    /// spends pixels at every nesting level. Bounded by `CardBudget`.
    case cards

    public var displayName: String {
        switch self {
        case .cushion: return "Cushion"
        case .cards:   return "Cards"
        }
    }
}

/// Corner radius and gap for card style, as pure functions of a rect's smaller side.
///
/// The point is progressive degradation. A rect can't show rounded corners and a gap below
/// roughly `2 × (radius + gap)`, so instead of a hard cutoff where small rects vanish into
/// padding, both values scale down and reach zero - a shrinking rect loses its rounding,
/// then its gap, then renders as plain fill. It never becomes pure padding.
public enum CardGeometry {
    public static let maxRadius: Float = 6
    public static let maxGap: Float = 2

    /// Below this, a rect is drawn as plain fill: no radius, no gap.
    public static let minSideForDecoration: Float = 6

    /// Card style skips tiles below this. Deliberately sub-pixel: culling anything a user
    /// can actually see punches grey container holes through the map, and the colour cache
    /// already removed the cost that culling was introduced to pay for.
    public static let minVisibleSide: Float = 0.9

    public static func radius(minSide: Float) -> Float {
        guard minSide >= minSideForDecoration else { return 0 }
        return min(maxRadius, minSide * 0.12)
    }

    public static func gap(minSide: Float) -> Float {
        guard minSide >= minSideForDecoration else { return 0 }
        return min(maxGap, minSide * 0.06)
    }

    /// True when the rect is big enough to carry any card decoration at all.
    public static func isDecorated(minSide: Float) -> Bool {
        minSide >= minSideForDecoration
    }

    /// A directory only gets a header strip when the label would actually be legible;
    /// otherwise the strip would eat a child's space to show clipped text.
    public static let minWidthForHeader: Float = 76
    public static let minHeightForHeader: Float = 56
    public static let headerHeight: Float = 18

    /// Folders style paints containers as neutral chrome rather than in their dominant
    /// child's colour. A directory tinted bright magenta competes with the files inside it
    /// for attention and turns nested chains into stacked colour bands; a slate panel reads
    /// as structure and lets the files carry the only colour that means anything.
    ///
    /// Applied at instance-build time, NOT in the colour resolver, so the resolved-colour
    /// cache stays independent of render style (a style-dependent cache key would put the
    /// 70ms-per-toggle cost straight back).
    public static let containerFill = SIMD4<Float>(0.29, 0.31, 0.36, 1.0)

    /// Below this, a folder is drawn as ONE solid block and its contents are not drawn.
    ///
    /// Taken from SpaceMonger 1.4 (`FolderView.cpp`, `minsizes` density table, default row
    /// `{32, 24}`): it only subdivides a folder when `w > hmin && h > vmin`, otherwise the
    /// folder becomes a single labelled block. DirWiz's layout recurses down to a 1pt
    /// `minPixelSize`, which is right for cushions - lighting survives extreme density - but
    /// in Folders style it produces regions of unreadable confetti where rounding, gaps and
    /// frames all collapse into mush. A folder too small to show its contents usefully is
    /// better drawn as one block that says how big it is.
    public static let minSubdivideWidth: Float = 32
    public static let minSubdivideHeight: Float = 24

    public static func canSubdivide(width: Float, height: Float) -> Bool {
        width > minSubdivideWidth && height > minSubdivideHeight
    }

    /// Depth-varied container fill. SpaceMonger colours by nesting depth
    /// (`BoxColors[depth & 7]` with bright/dark variants) rather than by file type, which is
    /// what makes its nesting legible. DirWiz keeps extension colour for FILES - that is the
    /// WinDirStat inheritance and the point of the map - so depth only modulates the neutral
    /// chrome of folder panels, giving stacked levels separation without stealing meaning
    /// from the colours that carry data.
    ///
    /// The step is sized against what competes with it. These are sRGB values, so 0.021 per
    /// level was about 5 of 255 - while the shader's own top-left to bottom-right card
    /// gradient swings roughly 18% across every panel. The depth cue was quieter than the
    /// shading laid over it, so stacked folders read as one flat slab. 0.034 puts a level
    /// change near 9 of 255, above the gradient's local variation, while depth 7 still lands
    /// at 0.49 - a mid panel, not a light one, so file colour keeps its contrast.
    public static func containerFill(depth: Int) -> SIMD4<Float> {
        let step = Float(depth & 7) * 0.034
        return SIMD4<Float>(0.25 + step, 0.27 + step, 0.32 + step, 1.0)
    }

    /// Folders style only: bring a file's extension colour into the same tonal family as
    /// the folder surface without turning the extension key into grey.
    ///
    /// Cushion style has lighting to tie the map together - every tile carries the same
    /// parabolic shading, so a saturated tile still reads as part of one surface. Folders
    /// has no lighting, so a fully saturated blue sitting inside a graduated grey panel
    /// reads as a different picture pasted on top rather than as contents of that folder.
    ///
    /// A 75% chrome blend was an overcorrection: it retained only 25% of the production
    /// palette's channel spread, so red, blue, and green all read as greyish slate on the
    /// supplied multi-terabyte scan. Retain 60% instead. Folder panels now carry a quieter
    /// tint from their representative descendants (below), which supplies the visual bridge
    /// that the stronger leaf muting was trying to create by itself.
    public static let leafChromeBlend: Float = 0.40

    /// Expanded folder panels carry 30% of their representative descendant colour. The
    /// resolver's directory colour already carries 65% of the representative extension,
    /// so the visible panel carries about 19.5% of the raw signal: enough to avoid a hard
    /// grey-to-red/blue boundary without competing with the files inside it.
    public static let containerAccentStrength: Float = 0.30

    /// A collapsed folder stands in for its contents, so it should be as chromatic as a
    /// file tile rather than as quiet as an expanded panel. Its resolved directory colour
    /// already retains 65% of the representative extension; a 10% settle leaves 58.5%,
    /// deliberately aligned with direct leaves' 60%.
    public static let collapsedFolderChromeBlend: Float = 0.10

    public static func leafFill(_ base: SIMD4<Float>, containerDepth: Int = 0) -> SIMD4<Float> {
        let chrome = containerFill(depth: containerDepth)
        let neutral = (chrome.x + chrome.y + chrome.z) / 3
        let k = leafChromeBlend
        return SIMD4<Float>(
            base.x + (neutral - base.x) * k,
            base.y + (neutral - base.y) * k,
            base.z + (neutral - base.z) * k,
            base.w
        )
    }

    /// Subtle content tint for an expanded folder's structural panel.
    public static func folderContainerFill(
        representativeColor: SIMD4<Float>?,
        depth: Int
    ) -> SIMD4<Float> {
        let chrome = containerFill(depth: depth)
        guard let representativeColor else { return chrome }
        let t = containerAccentStrength
        return SIMD4<Float>(
            chrome.x + (representativeColor.x - chrome.x) * t,
            chrome.y + (representativeColor.y - chrome.y) * t,
            chrome.z + (representativeColor.z - chrome.z) * t,
            1.0
        )
    }

    /// Content-bearing colour for a folder too small to subdivide.
    public static func collapsedFolderFill(
        _ representativeColor: SIMD4<Float>,
        containerDepth: Int
    ) -> SIMD4<Float> {
        let chrome = containerFill(depth: containerDepth)
        let neutral = (chrome.x + chrome.y + chrome.z) / 3
        let k = collapsedFolderChromeBlend
        return SIMD4<Float>(
            representativeColor.x + (neutral - representativeColor.x) * k,
            representativeColor.y + (neutral - representativeColor.y) * k,
            representativeColor.z + (neutral - representativeColor.z) * k,
            representativeColor.w
        )
    }

    /// Representative palette color for UI surfaces that act as the treemap's visible key.
    /// Folders uses depth zero because one legend cannot represent every nested chrome shade;
    /// Cushion keeps the raw palette that its shared lighting integrates on the map.
    public static func paletteColor(
        _ base: SIMD4<Float>,
        for style: TreemapRenderStyle
    ) -> SIMD4<Float> {
        switch style {
        case .cushion: base
        case .cards: leafFill(base, containerDepth: 0)
        }
    }

    public static func headerHeight(width: Float, height: Float) -> Float {
        (width >= minWidthForHeader && height >= minHeightForHeader) ? headerHeight : 0
    }

    /// Padding a directory container keeps around its children so its own fill stays
    /// visible as a border. Scales with the container and reaches zero, for the same
    /// reason `radius`/`gap` do: a small container must not spend all its pixels on frame.
    /// 5, not 3: the pad IS the visible border between a folder and its contents, and at
    /// 3pt a deep stack of large containers showed almost no frame at all. Only containers
    /// at least 250pt on their short side reach this, since the `minSide * 0.02` term gates
    /// it, so small folders still spend their pixels on children rather than on frame.
    public static let maxContainerPad: Float = 5

    public static func containerPad(width: Float, height: Float) -> Float {
        let minSide = min(width, height)
        guard minSide >= minSideForDecoration * 3 else { return 0 }
        return min(maxContainerPad, minSide * 0.02)
    }

    /// The region a container's children are remapped into: its own rect, minus the
    /// padding on every side, minus a header strip on top when one is legible.
    ///
    /// Returns nil when the container is too small to give up anything - the children then
    /// fill it edge to edge exactly as they do in cushion style. That is the degradation
    /// floor: nesting decoration is the first thing sacrificed, never the child itself.
    public static func innerRect(
        x: Float, y: Float, width: Float, height: Float
    ) -> (x: Float, y: Float, width: Float, height: Float)? {
        let pad = containerPad(width: width, height: height)
        let header = headerHeight(width: width, height: height)
        guard pad > 0 || header > 0 else { return nil }
        let innerW = width - 2 * pad
        let innerH = height - 2 * pad - header
        // Never hand back a degenerate or inverted region.
        guard innerW >= minSideForDecoration, innerH >= minSideForDecoration else { return nil }
        return (x: x + pad, y: y + pad + header, width: innerW, height: innerH)
    }
}

/// Decides whether card style can honestly draw a given view.
///
/// Card style spends pixels per nesting level, so past some node count it can only produce
/// sub-pixel slivers. Rather than draw a lie, it either aggregates the tail or hands the
/// view back to cushion rendering - and the UI says which, matching the repo's existing
/// habit of surfacing the reason instead of silently degrading.
public enum CardBudget {
    /// Above this, card style cannot draw individual nodes legibly at typical viewport sizes.
    public static let maxDrawnNodes = 40_000
    /// Above this, card style is abandoned entirely for the view.
    ///
    /// Raised from 20,000 after measuring the real cost: 100k instances render in ~3ms on
    /// the GPU, and tiny tiles are now culled before they reach it. The old ceiling meant a
    /// 33k-instance volume scan silently fell back to cushion - the Cards button cost 70ms
    /// and changed nothing on screen.
    public static let fallbackNodeThreshold = 250_000

    public enum Decision: Equatable, Sendable {
        /// Draw every node as a card.
        case drawAll
        /// Draw the largest `limit` nodes; aggregate the rest per parent, and say so.
        case aggregate(limit: Int)
        /// Too dense for cards to be honest - render this view as cushions instead.
        case fallbackToCushion
    }

    public static func decide(nodeCount: Int) -> Decision {
        if nodeCount > fallbackNodeThreshold { return .fallbackToCushion }
        if nodeCount > maxDrawnNodes { return .aggregate(limit: maxDrawnNodes) }
        return .drawAll
    }
}


/// The card-style nesting transform, kept pure so it can be tested without a GPU.
///
/// Children are remapped into their parent container's padded interior, which is what makes
/// a directory read as a card holding other cards. It composes to any depth because the
/// layout always emits a parent before its children, so one forward pass suffices.
///
/// This is a DRAWING transform. It must never be fed back into `SquarifyLayout`; Folders
/// builds a separate `SpatialGrid` from the resulting placed rects so hits follow the tiles.
/// The shader-only gap remains absent from those rects, preserving clickable card edges.
public enum CardNesting {
    public struct Item: Sendable, Equatable {
        public var nodeIndex: UInt32
        public var parentIndex: UInt32
        public var x: Float, y: Float, width: Float, height: Float
        public var isContainer: Bool

        public init(nodeIndex: UInt32, parentIndex: UInt32,
                    x: Float, y: Float, width: Float, height: Float, isContainer: Bool) {
            self.nodeIndex = nodeIndex; self.parentIndex = parentIndex
            self.x = x; self.y = y; self.width = width; self.height = height
            self.isContainer = isContainer
        }
    }

    public struct Placed: Sendable, Equatable {
        public var nodeIndex: UInt32
        public var x: Float, y: Float, width: Float, height: Float
        /// A folder too small to subdivide: draw it as one solid block, in its own colour,
        /// standing in for everything inside it.
        public var collapsed: Bool = false
        /// Inside a collapsed folder, so not drawn at all.
        public var suppressed: Bool = false
    }

    /// `items` must be in layout order (parents before their children).
    public static func place(_ items: [Item]) -> [Placed] {
        // container node -> (rect it originally occupied, interior its children get)
        var boxes: [UInt32: (outer: Item, inner: (x: Float, y: Float, width: Float, height: Float))] = [:]
        var out: [Placed] = []
        out.reserveCapacity(items.count)

        // Folders whose contents are not drawn, plus everything beneath them. The layout
        // emits a parent before its children, so one forward pass propagates this.
        var hidden = Set<UInt32>()

        for item in items {
            if item.parentIndex != item.nodeIndex, hidden.contains(item.parentIndex) {
                hidden.insert(item.nodeIndex)
                out.append(Placed(nodeIndex: item.nodeIndex, x: item.x, y: item.y,
                                  width: item.width, height: item.height, suppressed: true))
                continue
            }

            var x = item.x, y = item.y, w = item.width, h = item.height
            if item.parentIndex != item.nodeIndex,
               let box = boxes[item.parentIndex], box.outer.width > 0, box.outer.height > 0 {
                let sx = box.inner.width / box.outer.width
                let sy = box.inner.height / box.outer.height
                x = box.inner.x + (x - box.outer.x) * sx
                y = box.inner.y + (y - box.outer.y) * sy
                w *= sx
                h *= sy
            }

            // SpaceMonger's rule: subdivide only while the folder can still show its
            // contents; otherwise draw it as one block and stop.
            var collapsed = false
            if item.isContainer {
                if CardGeometry.canSubdivide(width: w, height: h),
                   let inner = CardGeometry.innerRect(x: x, y: y, width: w, height: h) {
                    // Keyed on the ORIGINAL rect: children arrive in original coordinates,
                    // so mapping original -> inner is what composes. Using the remapped
                    // rect as `outer` would apply the parent's inset twice to every child.
                    boxes[item.nodeIndex] = (outer: item, inner: inner)
                } else {
                    collapsed = true
                    hidden.insert(item.nodeIndex)
                }
            }
            out.append(Placed(nodeIndex: item.nodeIndex, x: x, y: y, width: w, height: h,
                              collapsed: collapsed))
        }
        return out
    }
}

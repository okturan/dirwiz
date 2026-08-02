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

/// Native comparison set for choosing the final Folders colour treatment on real trees.
///
/// This is deliberately expressed as renderer inputs rather than screenshot filters: every
/// option runs through the same Metal instances, nesting, overlays, hit testing, and extension
/// palette as production. The numbered names make feedback unambiguous while the review is open.
public enum FoldersColorScheme: Int, CaseIterable, Identifiable, Sendable {
    case pearl = 1
    case frost
    case silver
    case graphite
    case midnight
    case sand
    case clay
    case sage
    case lavender
    case inkAndPaper

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .pearl:       return "Pearl"
        case .frost:       return "Frost"
        case .silver:      return "Silver"
        case .graphite:    return "Graphite"
        case .midnight:    return "Midnight"
        case .sand:        return "Sand"
        case .clay:        return "Clay"
        case .sage:        return "Sage"
        case .lavender:    return "Lavender"
        case .inkAndPaper: return "Ink & Paper"
        }
    }

    public var reviewLabel: String { "\(rawValue). \(displayName)" }

    public var explanation: String {
        switch self {
        case .pearl:       return "Light cool folders that darken inward"
        case .frost:       return "Ice-blue folders that lighten inward"
        case .silver:      return "Alternating mid-grey folder layers"
        case .graphite:    return "Dark neutral folders that lighten inward"
        case .midnight:    return "Deep navy folders that open into blue-grey"
        case .sand:        return "Light warm folders that darken inward"
        case .clay:        return "Earthy folders that lighten inward"
        case .sage:        return "Light muted-green folders that darken inward"
        case .lavender:    return "Light muted-violet folders that darken inward"
        case .inkAndPaper: return "Strong alternating dark and light folder layers"
        }
    }

    struct Recipe: Equatable, Sendable {
        /// One structural colour for every `depth & 7` value. An explicit table is
        /// intentional: a shared base-plus-step equation made ten numerically different
        /// recipes look like one dark scheme with ten strength settings.
        let chromeLevels: [SIMD3<Float>]
    }

    /// Static storage avoids allocating an eight-element Array for every visible folder
    /// while rebuilding a multi-million-item tree's Metal instances.
    private static let recipes: [Recipe] = [
            Recipe(chromeLevels: [
                SIMD3(0.78, 0.79, 0.82), SIMD3(0.73, 0.74, 0.78),
                SIMD3(0.68, 0.69, 0.73), SIMD3(0.63, 0.64, 0.68),
                SIMD3(0.58, 0.59, 0.63), SIMD3(0.53, 0.54, 0.58),
                SIMD3(0.48, 0.49, 0.53), SIMD3(0.43, 0.44, 0.48),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.52, 0.61, 0.72), SIMD3(0.57, 0.66, 0.76),
                SIMD3(0.62, 0.71, 0.80), SIMD3(0.67, 0.76, 0.84),
                SIMD3(0.72, 0.80, 0.87), SIMD3(0.77, 0.84, 0.90),
                SIMD3(0.81, 0.87, 0.92), SIMD3(0.85, 0.90, 0.94),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.51, 0.53, 0.57), SIMD3(0.66, 0.67, 0.70),
                SIMD3(0.47, 0.49, 0.53), SIMD3(0.70, 0.71, 0.74),
                SIMD3(0.43, 0.45, 0.49), SIMD3(0.74, 0.75, 0.78),
                SIMD3(0.39, 0.41, 0.45), SIMD3(0.78, 0.79, 0.82),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.20, 0.22, 0.26), SIMD3(0.24, 0.26, 0.30),
                SIMD3(0.28, 0.30, 0.34), SIMD3(0.32, 0.34, 0.38),
                SIMD3(0.36, 0.38, 0.42), SIMD3(0.40, 0.42, 0.46),
                SIMD3(0.44, 0.46, 0.50), SIMD3(0.48, 0.50, 0.54),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.13, 0.19, 0.29), SIMD3(0.18, 0.25, 0.35),
                SIMD3(0.23, 0.31, 0.41), SIMD3(0.28, 0.37, 0.47),
                SIMD3(0.33, 0.43, 0.53), SIMD3(0.38, 0.49, 0.59),
                SIMD3(0.43, 0.55, 0.65), SIMD3(0.48, 0.61, 0.71),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.76, 0.69, 0.58), SIMD3(0.72, 0.65, 0.54),
                SIMD3(0.68, 0.61, 0.50), SIMD3(0.64, 0.57, 0.46),
                SIMD3(0.60, 0.53, 0.42), SIMD3(0.56, 0.49, 0.38),
                SIMD3(0.52, 0.45, 0.34), SIMD3(0.48, 0.41, 0.30),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.43, 0.31, 0.29), SIMD3(0.47, 0.35, 0.32),
                SIMD3(0.51, 0.39, 0.35), SIMD3(0.55, 0.43, 0.38),
                SIMD3(0.59, 0.47, 0.41), SIMD3(0.63, 0.51, 0.44),
                SIMD3(0.67, 0.55, 0.47), SIMD3(0.71, 0.59, 0.50),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.64, 0.72, 0.65), SIMD3(0.60, 0.68, 0.61),
                SIMD3(0.56, 0.64, 0.57), SIMD3(0.52, 0.60, 0.53),
                SIMD3(0.48, 0.56, 0.49), SIMD3(0.44, 0.52, 0.45),
                SIMD3(0.40, 0.48, 0.41), SIMD3(0.36, 0.44, 0.37),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.69, 0.65, 0.76), SIMD3(0.65, 0.61, 0.72),
                SIMD3(0.61, 0.57, 0.68), SIMD3(0.57, 0.53, 0.64),
                SIMD3(0.53, 0.49, 0.60), SIMD3(0.49, 0.45, 0.56),
                SIMD3(0.45, 0.41, 0.52), SIMD3(0.41, 0.37, 0.48),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.16, 0.18, 0.22), SIMD3(0.72, 0.73, 0.76),
                SIMD3(0.23, 0.25, 0.29), SIMD3(0.78, 0.79, 0.82),
                SIMD3(0.30, 0.32, 0.36), SIMD3(0.68, 0.69, 0.72),
                SIMD3(0.37, 0.39, 0.43), SIMD3(0.82, 0.83, 0.86),
            ]),
    ]

    var recipe: Recipe { Self.recipes[rawValue - 1] }
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

    /// Complete depth palette for expanded folder panels. SpaceMonger also indexes a table
    /// with `depth & 7`; keeping the table explicit is load-bearing here. The first native
    /// comparison used one dark base plus a linear step and accidentally offered ten
    /// strength variants of the same hierarchy. Each current scheme owns all eight colours.
    public static func containerFill(
        depth: Int,
        scheme: FoldersColorScheme = .pearl
    ) -> SIMD4<Float> {
        let color = scheme.recipe.chromeLevels[depth & 7]
        return SIMD4<Float>(
            color.x,
            color.y,
            color.z,
            1.0
        )
    }

    /// File colour is data, not structural theme chrome. Two real-tree attempts to settle
    /// it toward folder grey produced either a grey wash or a subtree veil, so every review
    /// scheme now passes the production extension colour through unchanged.
    public static func leafFill(
        _ base: SIMD4<Float>,
        containerDepth: Int = 0,
        scheme: FoldersColorScheme = .pearl
    ) -> SIMD4<Float> {
        _ = containerDepth
        _ = scheme
        return base
    }

    /// Expanded folders are structure only. Descendant colour on a large nested panel is
    /// precisely the all-over veil the native screenshots rejected.
    public static func folderContainerFill(
        representativeColor: SIMD4<Float>?,
        depth: Int,
        scheme: FoldersColorScheme = .pearl
    ) -> SIMD4<Float> {
        _ = representativeColor
        return containerFill(depth: depth, scheme: scheme)
    }

    /// Content-bearing colour for a folder too small to subdivide.
    public static func collapsedFolderFill(
        _ representativeColor: SIMD4<Float>,
        containerDepth: Int,
        scheme: FoldersColorScheme = .pearl
    ) -> SIMD4<Float> {
        _ = containerDepth
        _ = scheme
        return representativeColor
    }

    /// Representative palette color for UI surfaces that act as the treemap's visible key.
    /// Folders uses depth zero because one legend cannot represent every nested chrome shade;
    /// Cushion keeps the raw palette that its shared lighting integrates on the map.
    public static func paletteColor(
        _ base: SIMD4<Float>,
        for style: TreemapRenderStyle,
        foldersScheme: FoldersColorScheme = .pearl
    ) -> SIMD4<Float> {
        _ = foldersScheme
        switch style {
        case .cushion, .cards: return base
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

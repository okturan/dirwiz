import Foundation

/// How the treemap paints its rectangles.
///
/// Both styles consume the SAME `SquarifyLayout` output — this only changes painting, never
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
/// padding, both values scale down and reach zero — a shrinking rect loses its rounding,
/// then its gap, then renders as plain fill. It never becomes pure padding.
public enum CardGeometry {
    public static let maxRadius: Float = 6
    public static let maxGap: Float = 2

    /// Below this, a rect is drawn as plain fill: no radius, no gap.
    public static let minSideForDecoration: Float = 6

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

    public static func headerHeight(width: Float, height: Float) -> Float {
        (width >= minWidthForHeader && height >= minHeightForHeader) ? headerHeight : 0
    }

    /// Padding a directory container keeps around its children so its own fill stays
    /// visible as a border. Scales with the container and reaches zero, for the same
    /// reason `radius`/`gap` do: a small container must not spend all its pixels on frame.
    public static let maxContainerPad: Float = 3

    public static func containerPad(width: Float, height: Float) -> Float {
        let minSide = min(width, height)
        guard minSide >= minSideForDecoration * 3 else { return 0 }
        return min(maxContainerPad, minSide * 0.02)
    }

    /// The region a container's children are remapped into: its own rect, minus the
    /// padding on every side, minus a header strip on top when one is legible.
    ///
    /// Returns nil when the container is too small to give up anything — the children then
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
/// view back to cushion rendering — and the UI says which, matching the repo's existing
/// habit of surfacing the reason instead of silently degrading.
public enum CardBudget {
    /// Above this, card style cannot draw individual nodes legibly at typical viewport sizes.
    public static let maxDrawnNodes = 4_000
    /// Above this, card style is abandoned entirely for the view.
    public static let fallbackNodeThreshold = 20_000

    public enum Decision: Equatable, Sendable {
        /// Draw every node as a card.
        case drawAll
        /// Draw the largest `limit` nodes; aggregate the rest per parent, and say so.
        case aggregate(limit: Int)
        /// Too dense for cards to be honest — render this view as cushions instead.
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
/// This is a DRAWING transform. It must never be fed back into `SquarifyLayout` or into
/// `SpatialGrid` — hit testing stays on untransformed layout rects, or clicks near a card's
/// edge would land on the wrong node.
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
    }

    /// `items` must be in layout order (parents before their children).
    public static func place(_ items: [Item]) -> [Placed] {
        // container node -> (rect it originally occupied, interior its children get)
        var boxes: [UInt32: (outer: Item, inner: (x: Float, y: Float, width: Float, height: Float))] = [:]
        var out: [Placed] = []
        out.reserveCapacity(items.count)

        for item in items {
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
            if item.isContainer,
               let inner = CardGeometry.innerRect(x: x, y: y, width: w, height: h) {
                // Keyed on the ORIGINAL rect: children arrive in original coordinates, so
                // mapping original -> inner is what composes. Using the remapped rect as
                // `outer` would apply the parent's own inset twice to every child.
                boxes[item.nodeIndex] = (outer: item, inner: inner)
            }
            out.append(Placed(nodeIndex: item.nodeIndex, x: x, y: y, width: w, height: h))
        }
        return out
    }
}

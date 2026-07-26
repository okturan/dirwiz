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

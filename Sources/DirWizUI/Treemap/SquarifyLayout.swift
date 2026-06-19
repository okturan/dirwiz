import Foundation
import DirWizCore

/// A positioned rectangle in the treemap.
public struct TreemapRect: Sendable {
    public let nodeIndex: UInt32
    public var x: Float
    public var y: Float
    public var width: Float
    public var height: Float
    public let depth: Int // nesting depth for cushion calculation

    /// Cached cushion coefficients (ax2, bx, ay2, by). Computed inline during layout.
    public var cachedCoefs: SIMD4<Float> = .zero

    /// True for directory background rects (drawn first so sub-pixel children expose dir color).
    /// These should not receive text labels since children are drawn on top.
    public var isBackground: Bool = false
}

/// Internal layout rectangle for squarify calculations.
private struct LayoutRect {
    var x: Float
    var y: Float
    var w: Float
    var h: Float

    var area: Float { w * h }
    var shortSide: Float { min(w, h) }
}

public struct SquarifyLayout {

    /// Layout a treemap for the subtree rooted at `rootIndex`.
    /// Takes a snapshot of nodes (plain array) to avoid lock contention with the scanner.
    /// Returns an array of TreemapRect for all visible leaf/small-directory nodes.
    public static func layout(
        nodes: [FileNode],
        rootIndex: UInt32,
        bounds: CGRect,
        maxDepth: Int = 20,
        minPixelSize: Float = 1.0
    ) -> [TreemapRect] {
        var result: [TreemapRect] = []
        result.reserveCapacity(min(nodes.count, 200_000))

        let rect = LayoutRect(
            x: Float(bounds.origin.x),
            y: Float(bounds.origin.y),
            w: Float(bounds.size.width),
            h: Float(bounds.size.height)
        )

        var ancestors: [(x: Float, y: Float, w: Float, h: Float)] = []
        layoutNode(
            index: rootIndex,
            rect: rect,
            depth: 0,
            ancestors: &ancestors,
            nodes: nodes,
            maxDepth: maxDepth,
            minPixelSize: minPixelSize,
            result: &result
        )

        return result
    }

    // MARK: - Private

    private static func nodeAt(_ index: UInt32, _ nodes: [FileNode]) -> FileNode? {
        let i = Int(index)
        guard i < nodes.count else { return nil }
        return nodes[i]
    }

    private static func childrenSortedBySize(of index: UInt32, _ nodes: [FileNode]) -> [UInt32] {
        let i = Int(index)
        guard i < nodes.count else { return [] }
        let node = nodes[i]
        guard node.firstChildIndex != FileNode.invalid else { return [] }
        let start = Int(node.firstChildIndex)
        let end = min(start + Int(node.childCount), nodes.count)
        guard start < end else { return [] }
        return (start..<end).map { UInt32($0) }
            .sorted { nodes[Int($0)].displaySize > nodes[Int($1)].displaySize }
    }

    /// Emit a TreemapRect if large enough to be visible.
    private static func emitRect(
        nodeIndex: UInt32, rect: LayoutRect, depth: Int,
        ancestors: [(x: Float, y: Float, w: Float, h: Float)],
        minPixelSize: Float, isBackground: Bool = false,
        result: inout [TreemapRect]
    ) {
        guard rect.w >= minPixelSize, rect.h >= minPixelSize else { return }
        result.append(TreemapRect(
            nodeIndex: nodeIndex,
            x: rect.x, y: rect.y,
            width: rect.w, height: rect.h,
            depth: depth,
            cachedCoefs: computeCoefs(rectX: rect.x, rectY: rect.y, rectW: rect.w, rectH: rect.h, ancestors: ancestors),
            isBackground: isBackground
        ))
    }

    /// Recursively layout a single node's children within the given rect.
    /// Uses inout ancestors with push/pop to avoid per-level array copies.
    private static func layoutNode(
        index: UInt32,
        rect: LayoutRect,
        depth: Int,
        ancestors: inout [(x: Float, y: Float, w: Float, h: Float)],
        nodes: [FileNode],
        maxDepth: Int,
        minPixelSize: Float,
        result: inout [TreemapRect]
    ) {
        guard let node = nodeAt(index, nodes) else { return }

        // Leaf file or bundle: emit as opaque rect.
        if !node.isDirectory || node.isBundle {
            emitRect(nodeIndex: index, rect: rect, depth: depth,
                     ancestors: ancestors, minPixelSize: minPixelSize, result: &result)
            return
        }

        // Directory at max depth or too small: emit as a single rect.
        if depth >= maxDepth || rect.w < minPixelSize || rect.h < minPixelSize {
            emitRect(nodeIndex: index, rect: rect, depth: depth,
                     ancestors: ancestors, minPixelSize: minPixelSize, result: &result)
            return
        }

        // Get children sorted by size descending.
        let childIndices = childrenSortedBySize(of: index, nodes)
        guard !childIndices.isEmpty else {
            emitRect(nodeIndex: index, rect: rect, depth: depth,
                     ancestors: ancestors, minPixelSize: minPixelSize, result: &result)
            return
        }

        // Emit the directory as a background rect before its children.
        // Children are drawn on top; any sub-pixel-culled children expose this
        // rect instead of the near-black clearColor.
        emitRect(nodeIndex: index, rect: rect, depth: depth,
                 ancestors: ancestors, minPixelSize: minPixelSize,
                 isBackground: true, result: &result)

        // Compute total size of children.
        let totalSize = childIndices.reduce(Float(0)) { sum, idx in
            sum + max(Float(nodeAt(idx, nodes)?.displaySize ?? 0), 1)
        }

        guard totalSize > 0, rect.area > 0 else { return }

        // Normalize areas to fit the target rectangle.
        let scaleFactor = rect.area / totalSize
        let children: [(index: UInt32, area: Float)] = childIndices.map { idx in
            let area = max(Float(nodeAt(idx, nodes)?.displaySize ?? 0), 1) * scaleFactor
            return (index: idx, area: area)
        }

        // Push this directory as an ancestor for its children.
        ancestors.append((x: rect.x, y: rect.y, w: rect.w, h: rect.h))

        squarify(
            children: children,
            rect: rect,
            depth: depth,
            ancestors: &ancestors,
            nodes: nodes,
            maxDepth: maxDepth,
            minPixelSize: minPixelSize,
            result: &result
        )

        ancestors.removeLast()
    }

    /// Core squarified treemap algorithm (iterative).
    /// Greedily fills rows: adds items while worst aspect ratio improves,
    /// then finalizes the row and continues with remaining space.
    private static func squarify(
        children: [(index: UInt32, area: Float)],
        rect: LayoutRect,
        depth: Int,
        ancestors: inout [(x: Float, y: Float, w: Float, h: Float)],
        nodes: [FileNode],
        maxDepth: Int,
        minPixelSize: Float,
        result: inout [TreemapRect]
    ) {
        let count = children.count
        var startIndex = 0
        var rect = rect

        while startIndex < count {
            // Only one item left: give it the whole remaining rect.
            if startIndex == count - 1 {
                layoutNode(
                    index: children[startIndex].index,
                    rect: rect,
                    depth: depth + 1,
                    ancestors: &ancestors,
                    nodes: nodes,
                    maxDepth: maxDepth,
                    minPixelSize: minPixelSize,
                    result: &result
                )
                return
            }

            let side = rect.shortSide
            guard side > 0 else { return }

            // Build the current row greedily.
            var rowArea: Float = children[startIndex].area
            var rowEnd = startIndex + 1
            var currentWorst = worstRatio(rowArea: rowArea, side: side, minItem: rowArea, maxItem: rowArea)
            var rowMinItem = rowArea
            var rowMaxItem = rowArea

            while rowEnd < count {
                let nextArea = children[rowEnd].area
                let newRowArea = rowArea + nextArea
                let newMin = min(rowMinItem, nextArea)
                let newMax = max(rowMaxItem, nextArea)
                let newWorst = worstRatio(rowArea: newRowArea, side: side, minItem: newMin, maxItem: newMax)

                if newWorst > currentWorst {
                    break // Adding this item makes the row worse; stop here.
                }

                rowArea = newRowArea
                rowMinItem = newMin
                rowMaxItem = newMax
                currentWorst = newWorst
                rowEnd += 1
            }

            // Layout the finalized row within the rect.
            let (rowRect, remainingRect) = layoutRow(
                rowArea: rowArea,
                rect: rect
            )

            // Place each item in the row.
            let rowLength = rowArea / rect.shortSide
            let horizontal = rect.w >= rect.h
            var offset: Float = horizontal ? rowRect.y : rowRect.x
            let rowEndEdge: Float = horizontal ? rowRect.y + rowRect.h : rowRect.x + rowRect.w

            for i in startIndex..<rowEnd {
                let isLastInRow = (i == rowEnd - 1)
                var itemLength = rowLength > 0 ? children[i].area / rowLength : 0

                // Snap the last item to the remaining space to prevent FP drift.
                if isLastInRow {
                    itemLength = rowEndEdge - offset
                }

                let itemRect: LayoutRect
                if horizontal {
                    itemRect = LayoutRect(x: rowRect.x, y: offset, w: rowLength, h: itemLength)
                } else {
                    itemRect = LayoutRect(x: offset, y: rowRect.y, w: itemLength, h: rowLength)
                }

                layoutNode(
                    index: children[i].index,
                    rect: itemRect,
                    depth: depth + 1,
                    ancestors: &ancestors,
                    nodes: nodes,
                    maxDepth: maxDepth,
                    minPixelSize: minPixelSize,
                    result: &result
                )

                offset += itemLength
            }

            // Continue with the remaining children in the leftover space.
            startIndex = rowEnd
            rect = remainingRect
        }
    }

    /// Compute worst aspect ratio for a row of items.
    /// Uses the formula: max(maxItem, rowArea^2 / (side^2 * minItem))
    /// divided by min(minItem, rowArea^2 / (side^2 * maxItem)).
    private static func worstRatio(rowArea: Float, side: Float, minItem: Float, maxItem: Float) -> Float {
        guard side > 0, minItem > 0, maxItem > 0, rowArea > 0 else {
            return Float.greatestFiniteMagnitude
        }
        let s2 = side * side
        let r2 = rowArea * rowArea
        // worst = max(s2 * maxItem / r2, r2 / (s2 * minItem))
        let a = s2 * maxItem / r2
        let b = r2 / (s2 * minItem)
        return max(a, b)
    }

    /// Split the rect into the row region and the remaining region.
    private static func layoutRow(
        rowArea: Float,
        rect: LayoutRect
    ) -> (row: LayoutRect, remaining: LayoutRect) {
        let side = rect.shortSide
        let rowLength = side > 0 ? rowArea / side : 0
        let horizontal = rect.w >= rect.h

        let rowRect: LayoutRect
        let remainingRect: LayoutRect

        if horizontal {
            // Row fills left strip of width rowLength.
            rowRect = LayoutRect(x: rect.x, y: rect.y, w: rowLength, h: rect.h)
            remainingRect = LayoutRect(x: rect.x + rowLength, y: rect.y, w: rect.w - rowLength, h: rect.h)
        } else {
            // Row fills top strip of height rowLength.
            rowRect = LayoutRect(x: rect.x, y: rect.y, w: rect.w, h: rowLength)
            remainingRect = LayoutRect(x: rect.x, y: rect.y + rowLength, w: rect.w, h: rect.h - rowLength)
        }

        return (rowRect, remainingRect)
    }
}

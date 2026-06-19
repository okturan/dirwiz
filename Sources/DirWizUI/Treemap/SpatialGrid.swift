import Foundation
import DirWizCore

/// A flat 2D grid that maps viewport regions to overlapping TreemapRect indices.
/// Enables O(1) cell lookup + small linear scan instead of O(n) over all rects.
struct SpatialGrid {
    private struct CellSpan {
        let minCol: Int
        let maxCol: Int
        let minRow: Int
        let maxRow: Int
    }

    private let cols: Int
    private let rows: Int
    private let cellWidth: Float
    private let cellHeight: Float
    /// CSR (Compressed Sparse Row) layout: offsets[cellIndex] to offsets[cellIndex+1] in indices array.
    private let offsets: [Int]
    private let indices: [Int]

    init(viewportWidth: Float, viewportHeight: Float, rects: [TreemapRect], gridSize: Int? = nil) {
        guard viewportWidth > 0, viewportHeight > 0, !rects.isEmpty else {
            self.cols = 0; self.rows = 0; self.cellWidth = 1; self.cellHeight = 1
            self.offsets = []; self.indices = []
            return
        }

        // Adaptive grid size based on rect count.
        let size = gridSize ?? max(16, min(128, Int(sqrt(Double(rects.count)))))
        self.cols = size
        self.rows = size
        self.cellWidth = viewportWidth / Float(size)
        self.cellHeight = viewportHeight / Float(size)

        let totalCells = size * size

        // Pass 1: Count entries per cell.
        var counts = Array(repeating: 0, count: totalCells)
        var validSpans: [(rectIndex: Int, span: CellSpan)] = []
        validSpans.reserveCapacity(rects.count)
        for i in 0..<rects.count {
            guard let span = Self.cellSpan(
                for: rects[i],
                cols: size,
                rows: size,
                cellWidth: cellWidth,
                cellHeight: cellHeight
            ) else { continue }
            validSpans.append((rectIndex: i, span: span))

            for row in span.minRow...span.maxRow {
                let rowOffset = row * size
                for col in span.minCol...span.maxCol {
                    counts[rowOffset + col] += 1
                }
            }
        }

        // Build offsets (prefix sum).
        var offsets = Array(repeating: 0, count: totalCells + 1)
        for i in 0..<totalCells {
            offsets[i + 1] = offsets[i] + counts[i]
        }

        // Pass 2: Fill indices.
        var indices = Array(repeating: 0, count: offsets[totalCells])
        var writePos = offsets
        for (rectIndex, span) in validSpans {
            for row in span.minRow...span.maxRow {
                let rowOffset = row * size
                for col in span.minCol...span.maxCol {
                    let cell = rowOffset + col
                    indices[writePos[cell]] = rectIndex
                    writePos[cell] += 1
                }
            }
        }

        self.offsets = offsets
        self.indices = indices
    }

    /// Find the deepest (last in layout order) rect containing the given point.
    func hitTest(point: (x: Float, y: Float), rects: [TreemapRect]) -> UInt32? {
        guard cols > 0, rows > 0 else { return nil }

        let col = Int(point.x / cellWidth)
        let row = Int(point.y / cellHeight)
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }

        let cell = row * cols + col
        let start = offsets[cell]
        let end = offsets[cell + 1]
        // Search in reverse so deeper/smaller rects (laid out later) are found first.
        for i in stride(from: end - 1, through: start, by: -1) {
            let idx = indices[i]
            let r = rects[idx]
            if point.x >= r.x && point.x < r.x + r.width &&
               point.y >= r.y && point.y < r.y + r.height {
                return r.nodeIndex
            }
        }
        return nil
    }

    private static func cellSpan(
        for rect: TreemapRect,
        cols: Int,
        rows: Int,
        cellWidth: Float,
        cellHeight: Float
    ) -> CellSpan? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        let minCol = max(0, Int(rect.x / cellWidth))
        let maxCol = min(cols - 1, Int((rect.x + rect.width - Float.ulpOfOne) / cellWidth))
        let minRow = max(0, Int(rect.y / cellHeight))
        let maxRow = min(rows - 1, Int((rect.y + rect.height - Float.ulpOfOne) / cellHeight))
        guard minCol <= maxCol, minRow <= maxRow else { return nil }
        return CellSpan(minCol: minCol, maxCol: maxCol, minRow: minRow, maxRow: maxRow)
    }
}

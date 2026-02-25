import Foundation

/// A flat 2D grid that maps viewport regions to overlapping TreemapRect indices.
/// Enables O(1) cell lookup + small linear scan instead of O(n) over all rects.
struct SpatialGrid {
    private let cols: Int
    private let rows: Int
    private let cellWidth: Float
    private let cellHeight: Float
    /// Flat array of rect indices per cell. cells[row * cols + col] = [indices].
    private var cells: [[Int]]

    init(viewportWidth: Float, viewportHeight: Float, rects: [TreemapRect], gridSize: Int = 64) {
        guard viewportWidth > 0, viewportHeight > 0, !rects.isEmpty else {
            self.cols = 0
            self.rows = 0
            self.cellWidth = 1
            self.cellHeight = 1
            self.cells = []
            return
        }

        self.cols = gridSize
        self.rows = gridSize
        self.cellWidth = viewportWidth / Float(gridSize)
        self.cellHeight = viewportHeight / Float(gridSize)
        self.cells = Array(repeating: [], count: gridSize * gridSize)

        for i in 0..<rects.count {
            let r = rects[i]
            guard r.width > 0, r.height > 0 else { continue }
            // Compute cell range this rect overlaps.
            let minCol = max(0, Int(r.x / cellWidth))
            let maxCol = min(gridSize - 1, Int((r.x + r.width - Float.ulpOfOne) / cellWidth))
            let minRow = max(0, Int(r.y / cellHeight))
            let maxRow = min(gridSize - 1, Int((r.y + r.height - Float.ulpOfOne) / cellHeight))

            guard minCol <= maxCol, minRow <= maxRow else { continue }

            for row in minRow...maxRow {
                let rowOffset = row * gridSize
                for col in minCol...maxCol {
                    self.cells[rowOffset + col].append(i)
                }
            }
        }
    }

    /// Find the deepest (last in layout order) rect containing the given point.
    func hitTest(point: (x: Float, y: Float), rects: [TreemapRect]) -> UInt32? {
        guard cols > 0, rows > 0 else { return nil }

        let col = Int(point.x / cellWidth)
        let row = Int(point.y / cellHeight)
        guard col >= 0, col < cols, row >= 0, row < rows else { return nil }

        let indices = cells[row * cols + col]
        // Search in reverse so deeper/smaller rects (laid out later) are found first.
        for i in stride(from: indices.count - 1, through: 0, by: -1) {
            let idx = indices[i]
            let r = rects[idx]
            if point.x >= r.x && point.x < r.x + r.width &&
               point.y >= r.y && point.y < r.y + r.height {
                return r.nodeIndex
            }
        }
        return nil
    }
}

import Testing
@testable import DirWizLib

@Suite("Spatial Grid Tests")
struct SpatialGridTests {

    @Test("hitTest returns last overlapping rect")
    func hitTestPrefersLastRect() {
        let rects = [
            TreemapRect(nodeIndex: 11, x: 0, y: 0, width: 50, height: 50, depth: 1),
            TreemapRect(nodeIndex: 22, x: 0, y: 0, width: 50, height: 50, depth: 2),
        ]
        let grid = SpatialGrid(viewportWidth: 100, viewportHeight: 100, rects: rects, gridSize: 8)

        let hit = grid.hitTest(point: (x: 25, y: 25), rects: rects)
        #expect(hit == 22)
    }

    @Test("hitTest ignores zero-sized rects")
    func hitTestSkipsDegenerateRects() {
        let rects = [
            TreemapRect(nodeIndex: 33, x: 20, y: 20, width: 0, height: 10, depth: 1),
            TreemapRect(nodeIndex: 44, x: 20, y: 20, width: 10, height: 0, depth: 1),
        ]
        let grid = SpatialGrid(viewportWidth: 100, viewportHeight: 100, rects: rects, gridSize: 8)

        let hit = grid.hitTest(point: (x: 20, y: 20), rects: rects)
        #expect(hit == nil)
    }
}

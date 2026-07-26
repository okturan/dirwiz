import Testing
import Metal
import Foundation
import simd
@testable import DirWizCore
@testable import DirWizUI

/// Card style is a *painting* change only: same `SquarifyLayout` output, same instance
/// buffer, one extra branch in the fragment shader. These tests pin the three ways that
/// could quietly stop being true.
@Suite("Card Style Tests")
struct CardStyleTests {

    // MARK: - Cushion output must be unchanged

    /// `styleMode` was carved out of the old `padding2` precisely so the uniform buffer
    /// keeps its 48-byte stride and the Swift↔Metal layout contract still holds. If this
    /// breaks, every uniform after `lightDir` is read at the wrong offset by the GPU.
    @Test("Uniform layout is unchanged at 48 bytes")
    func uniformStrideUnchanged() {
        #expect(MemoryLayout<CushionUniforms>.stride == 48)
        #expect(MemoryLayout<CushionInstance>.stride == 48)
        verifyCushionLayouts()
    }

    /// Every pre-existing construction site omits `styleMode`, so the default decides
    /// whether shipping this feature silently changed how the app already looked.
    @Test("Uniforms default to cushion, so existing render paths are untouched")
    func defaultStyleIsCushion() {
        let u = CushionUniforms(
            viewportSize: SIMD2<Float>(100, 100),
            ambient: 0.25,
            padding1: 0,
            lightDir: SIMD4<Float>(0, 0, 1, 0),
            hoveredIndex: -1,
            selectedIndex: -1
        )
        #expect(u.styleMode == 0, "styleMode 0 is the cushion branch")
        #expect(TreemapRenderStyle.cushion.rawValue == "cushion")
    }

    /// The shader is compiled from source at runtime, so a Metal syntax error in the new
    /// branch would never fail `swift build` — only a blank treemap on the user's machine.
    @Test("Shader source compiles and exposes both entry points")
    func shaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // CI without a GPU
        let library = try device.makeLibrary(source: CushionShaderSource.source, options: nil)
        #expect(library.makeFunction(name: "cushionVertexShader") != nil)
        #expect(library.makeFunction(name: "cushionFragmentShader") != nil)
    }

    /// The card branch must actually exist and be gated on styleMode — a shader that
    /// compiles but never takes the branch would render cushions in both modes.
    @Test("Shader branches on styleMode and discards outside the rounded box")
    func shaderHasGatedCardBranch() {
        let src = CushionShaderSource.source
        #expect(src.contains("uniforms.styleMode == 1"))
        #expect(src.contains("discard_fragment()"))
        #expect(src.contains("int    styleMode"), "Metal uniform struct must mirror the Swift one")
    }

    // MARK: - Geometry degrades instead of vanishing

    /// The whole point of scaling radius and gap with the rect: a shrinking card loses its
    /// rounding, then its gap, then draws as plain fill. It must never become pure padding,
    /// which is what a fixed inset would do to the small rects that dominate a real scan.
    @Test("Radius and gap shrink to zero rather than eating small rects")
    func geometryDegradesGracefully() {
        #expect(CardGeometry.radius(minSide: 200) == CardGeometry.maxRadius)
        #expect(CardGeometry.gap(minSide: 200) == CardGeometry.maxGap)

        // Just below the decoration floor: plain fill, no padding consumed.
        #expect(CardGeometry.radius(minSide: 5) == 0)
        #expect(CardGeometry.gap(minSide: 5) == 0)
        #expect(!CardGeometry.isDecorated(minSide: 5))
        #expect(CardGeometry.isDecorated(minSide: CardGeometry.minSideForDecoration))

        // Monotonic across the range, and never more than a fraction of the rect.
        var previousRadius: Float = -1
        for side in stride(from: Float(6), through: 300, by: 3) {
            let r = CardGeometry.radius(minSide: side)
            let g = CardGeometry.gap(minSide: side)
            #expect(r >= previousRadius, "radius must not decrease as the rect grows")
            previousRadius = r
            #expect(2 * (r + g) < side, "decoration must never consume the whole rect at side \(side)")
        }
    }

    @Test("A header strip only appears when the label would be legible")
    func headerOnlyWhenLegible() {
        #expect(CardGeometry.headerHeight(width: 200, height: 150) == CardGeometry.headerHeight)
        #expect(CardGeometry.headerHeight(width: 40, height: 150) == 0)
        #expect(CardGeometry.headerHeight(width: 200, height: 20) == 0)
    }

    // MARK: - Density budget

    @Test("Card budget aggregates then falls back as density rises")
    func budgetThresholds() {
        #expect(CardBudget.decide(nodeCount: 100) == .drawAll)
        #expect(CardBudget.decide(nodeCount: CardBudget.maxDrawnNodes) == .drawAll)
        #expect(CardBudget.decide(nodeCount: CardBudget.maxDrawnNodes + 1)
                == .aggregate(limit: CardBudget.maxDrawnNodes))
        #expect(CardBudget.decide(nodeCount: CardBudget.fallbackNodeThreshold) == .aggregate(limit: CardBudget.maxDrawnNodes))
        #expect(CardBudget.decide(nodeCount: CardBudget.fallbackNodeThreshold + 1) == .fallbackToCushion)
    }

    // MARK: - Hit testing is style-independent

    /// The known trap in this change: card style insets its *visual* rect, so it is tempting
    /// to inset the rects handed to `SpatialGrid` too. That would make clicks near a card's
    /// edge miss, and the gaps between siblings dead. The inset lives entirely in the
    /// fragment shader, so the grid keeps indexing full layout rects — pin that here.
    @Test("Hit testing uses full layout rects, so gaps and card edges stay clickable")
    func hitTestingIgnoresVisualInset() {
        // Two adjacent 60×60 siblings sharing the boundary at x = 60.
        let rects = [
            TreemapRect(nodeIndex: 1, x: 0, y: 0, width: 60, height: 60, depth: 1),
            TreemapRect(nodeIndex: 2, x: 60, y: 0, width: 60, height: 60, depth: 1),
        ]
        let grid = SpatialGrid(viewportWidth: 120, viewportHeight: 60, rects: rects, gridSize: 8)

        // At 60pt the visual card is inset by CardGeometry.gap; a point inside that inset
        // band paints as background but must still hit the node it belongs to.
        let gap = CardGeometry.gap(minSide: 60)
        #expect(gap > 0, "control: this rect is big enough that a naive inset would matter")

        #expect(grid.hitTest(point: (x: gap / 2, y: 30), rects: rects) == 1,
                "the left card's inset band still belongs to node 1")
        #expect(grid.hitTest(point: (x: 60 - gap / 2, y: 30), rects: rects) == 1,
                "the boundary-side inset band still belongs to node 1")
        #expect(grid.hitTest(point: (x: 60 + gap / 2, y: 30), rects: rects) == 2,
                "the gap between siblings is not dead space")
        #expect(grid.hitTest(point: (x: 30, y: 30), rects: rects) == 1)
    }

    /// Style is a user preference, not scan state — a new scan must not silently reset it.
    @Test("Render style survives resetForNewScan")
    @MainActor
    func stylePersistsAcrossScans() {
        let state = AppState()
        state.treemapRenderStyle = .cards
        state.resetForNewScan()
        #expect(state.treemapRenderStyle == .cards)
        state.treemapRenderStyle = .cushion   // restore the shared UserDefaults key
    }
}

/// Offscreen GPU rendering. Everything above checks the *inputs* to the shader; this
/// actually runs it and looks at pixels, which is the only way to know the card branch
/// draws something different from cushion and that cushion still draws what it did.
@Suite("Card Style Rendering Tests")
struct CardStyleRenderTests {

    private struct Rendered {
        let pixels: [UInt8]   // BGRA
        let width: Int
        let height: Int
        /// Alpha 0 means nothing was written: either discarded or never covered.
        func isBackground(x: Int, y: Int) -> Bool { pixels[(y * width + x) * 4 + 3] == 0 }
        func rgb(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
            let o = (y * width + x) * 4
            return (pixels[o], pixels[o + 1], pixels[o + 2])
        }
    }

    /// Renders one full-viewport instance with the real shader source and returns the pixels.
    private func render(styleMode: Int32, side: Int) throws -> Rendered? {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }   // CI without a GPU

        let library = try device.makeLibrary(source: CushionShaderSource.source, options: nil)
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = library.makeFunction(name: "cushionVertexShader")
        desc.fragmentFunction = library.makeFunction(name: "cushionFragmentShader")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: desc)

        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        texDesc.usage = [.renderTarget, .shaderRead]
        texDesc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: texDesc) else { return nil }

        // One mid-grey instance covering the whole viewport, with a plausible cushion ridge.
        var instance = CushionInstance(
            rect: SIMD4<Float>(0, 0, Float(side), Float(side)),
            coefs: SIMD4<Float>(-1.6, 1.6, -1.6, 1.6),
            color: SIMD4<Float>(0.5, 0.5, 0.5, 1)
        )
        let ld = normalize(SIMD3<Float>(0.5, 0.5, 1.0))
        var uniforms = CushionUniforms(
            viewportSize: SIMD2<Float>(Float(side), Float(side)),
            ambient: 0.25,
            padding1: 0,
            lightDir: SIMD4<Float>(ld.x, ld.y, ld.z, 0),
            hoveredIndex: -1,
            selectedIndex: -1,
            styleMode: styleMode
        )

        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = .clear
        // Fully transparent clear: any pixel the shader discards stays alpha 0.
        rp.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        rp.colorAttachments[0].storeAction = .store

        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return nil }
        enc.setRenderPipelineState(pipeline)
        enc.setVertexBytes(&instance, length: MemoryLayout<CushionInstance>.stride, index: 0)
        enc.setVertexBytes(&uniforms, length: MemoryLayout<CushionUniforms>.stride, index: 1)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<CushionUniforms>.stride, index: 1)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        pixels.withUnsafeMutableBytes { buf in
            texture.getBytes(buf.baseAddress!, bytesPerRow: side * 4,
                             from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        }
        return Rendered(pixels: pixels, width: side, height: side)
    }

    /// Card style's defining visual: rounded corners with the background showing through,
    /// and a gap inset on every edge. Cushion fills its rect corner to corner.
    @Test("Card style rounds its corners; cushion style does not")
    func cardRoundsCornersCushionDoesNot() throws {
        let side = 128
        guard let cushion = try render(styleMode: 0, side: side),
              let cards = try render(styleMode: 1, side: side) else { return }

        // Corner pixel: inside the rect for cushion, outside the rounded box for cards.
        #expect(!cushion.isBackground(x: 1, y: 1), "cushion fills its whole rect")
        #expect(cards.isBackground(x: 1, y: 1), "the card's corner must be cut away")

        // Both must still paint the middle — a card that discarded everything would also
        // pass the corner assertion above.
        #expect(!cushion.isBackground(x: side / 2, y: side / 2))
        #expect(!cards.isBackground(x: side / 2, y: side / 2))
    }

    /// Cushion conveys hierarchy by lighting, cards by geometry. If the card branch ever
    /// fell through to the cushion lighting, the two would look the same in the interior.
    @Test("The two styles shade their interior differently")
    func stylesDifferInShading() throws {
        let side = 128
        guard let cushion = try render(styleMode: 0, side: side),
              let cards = try render(styleMode: 1, side: side) else { return }

        var differing = 0
        for y in stride(from: 20, to: side - 20, by: 4) {
            for x in stride(from: 20, to: side - 20, by: 4) {
                if cushion.rgb(x: x, y: y) != cards.rgb(x: x, y: y) { differing += 1 }
            }
        }
        #expect(differing > 0, "card shading must not be identical to cushion shading")
    }

    /// A card small enough to lose its decoration renders as plain fill. This is the
    /// degradation promise: small rects stay visible instead of dissolving into padding.
    @Test("Below the decoration floor a card fills its rect like cushion does")
    func tinyCardIsPlainFill() throws {
        // 4pt is under CardGeometry.minSideForDecoration, so radius and gap are both 0.
        guard let tiny = try render(styleMode: 1, side: 4) else { return }
        for y in 0..<4 {
            for x in 0..<4 {
                #expect(!tiny.isBackground(x: x, y: y),
                        "a tiny card must draw every pixel, not shrink into padding (\(x),\(y))")
            }
        }
    }
}

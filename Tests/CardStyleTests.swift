import Testing
import Metal
import Foundation
import simd
@testable import DirWizCore
@testable import DirWizUI

/// Card style starts from the same `SquarifyLayout`, then builds nested instances and uses
/// the card shader branch. These tests pin geometry, palette, comparison recipes, and the
/// Cushion isolation that could quietly regress while those instance inputs change.
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
    /// branch would never fail `swift build` - only a blank treemap on the user's machine.
    @Test("Shader source compiles and exposes both entry points")
    func shaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }  // CI without a GPU
        let library = try device.makeLibrary(source: CushionShaderSource.source, options: nil)
        #expect(library.makeFunction(name: "cushionVertexShader") != nil)
        #expect(library.makeFunction(name: "cushionFragmentShader") != nil)
    }

    /// The card branch must actually exist and be gated on styleMode - a shader that
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
    /// fragment shader, so the grid keeps indexing full layout rects - pin that here.
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

    /// Every review candidate uses the actual 17-color production palette, not hand-picked
    /// moderate samples. The schemes may change strength and chrome, but none may collapse the
    /// extension key or distort relative colour identity while the user compares them.
    @Test("All ten native schemes keep production colors chromatic and proportionally distinct")
    func productionLeafColorsBelongToChrome() {
        var palette = ExtensionPalette()
        let stats = (0..<17).map { index in
            FileTypeStat(
                extensionName: "ext\(index)",
                extensionHash: UInt32(index + 1),
                category: .other,
                totalSize: UInt64(17 - index),
                fileCount: 1,
                percentage: 0
            )
        }
        palette.assign(from: stats)

        let productionColors = stats.map { palette.color(forHash: $0.extensionHash) }
        let spread = { (c: SIMD4<Float>) in
            max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z))
        }
        let mean = { (c: SIMD4<Float>) in (c.x + c.y + c.z) / 3 }

        for scheme in FoldersColorScheme.allCases {
            let chrome = CardGeometry.containerFill(depth: 0, scheme: scheme)
            let chromeNeutral = mean(chrome)
            let expectedRetention = 1 - scheme.recipe.leafChromeBlend
            let outputs = productionColors.map {
                CardGeometry.leafFill($0, containerDepth: 0, scheme: scheme)
            }

            for (base, out) in zip(productionColors, outputs) {
                let baseOrder = [base.x, base.y, base.z].enumerated()
                    .sorted { $0.element > $1.element }.map(\.offset)
                let outOrder = [out.x, out.y, out.z].enumerated()
                    .sorted { $0.element > $1.element }.map(\.offset)
                #expect(baseOrder == outOrder, "\(scheme.reviewLabel) changed hue identity")

                let retainedSpread = spread(out) / spread(base)
                #expect(abs(retainedSpread - expectedRetention) < 0.001)
                #expect(retainedSpread >= 0.599,
                        "\(scheme.reviewLabel) must not recreate the rejected grey wash")
                if scheme.recipe.leafChromeBlend > 0 {
                    #expect(abs(mean(out) - chromeNeutral) < abs(mean(base) - chromeNeutral))
                } else {
                    #expect(out == base)
                }
                #expect(out.w == base.w, "alpha untouched")
            }

            for i in outputs.indices {
                for j in outputs.indices where j > i {
                    let baseDelta = productionColors[i] - productionColors[j]
                    let baseDistance = sqrt(
                        baseDelta.x * baseDelta.x
                            + baseDelta.y * baseDelta.y
                            + baseDelta.z * baseDelta.z
                    )
                    let delta = outputs[i] - outputs[j]
                    let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
                    #expect(abs(distance / baseDistance - expectedRetention) < 0.01,
                            "\(scheme.reviewLabel) distorted colors \(i) and \(j)")
                }
            }
        }
    }

    @Test("The native comparison exposes ten numbered, genuinely distinct recipes")
    func foldersComparisonSetIsComplete() {
        let schemes = FoldersColorScheme.allCases
        #expect(schemes.map(\.rawValue) == Array(1...10))
        #expect(Set(schemes.map(\.displayName)).count == 10)
        for i in schemes.indices {
            for j in schemes.indices where j > i {
                #expect(schemes[i].recipe != schemes[j].recipe,
                        "\(schemes[i].reviewLabel) and \(schemes[j].reviewLabel) must not be aliases")
            }
        }
    }

    @Test("Folder panels bridge content hue while collapsed folders keep file-like chroma")
    func folderHierarchyCarriesRepresentativeHue() {
        let dirBaseA = SIMD4<Float>(0.80, 0.30, 0.38, 1)
        let dirBaseB = SIMD4<Float>(0.28, 0.40, 0.88, 1)
        let panelA = CardGeometry.folderContainerFill(
            representativeColor: dirBaseA, depth: 0, scheme: .tinted
        )
        let panelB = CardGeometry.folderContainerFill(
            representativeColor: dirBaseB, depth: 0, scheme: .tinted
        )
        let collapsedA = CardGeometry.collapsedFolderFill(
            dirBaseA, containerDepth: 0, scheme: .tinted
        )
        let collapsedB = CardGeometry.collapsedFolderFill(
            dirBaseB, containerDepth: 0, scheme: .tinted
        )

        func distance(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Float {
            let d = a - b
            return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        }

        let sourceDistance = distance(dirBaseA, dirBaseB)
        #expect(abs(distance(panelA, panelB) / sourceDistance - 0.30) < 0.001,
                "expanded panels need a quiet but deterministic content-hue bridge")
        #expect(abs(distance(collapsedA, collapsedB) / sourceDistance - 0.90) < 0.001,
                "collapsed folders represent content and must not be washed into panel grey")
        #expect(CardGeometry.folderContainerFill(
            representativeColor: nil, depth: 0, scheme: .tinted
        ) == CardGeometry.containerFill(depth: 0, scheme: .tinted),
                "an actually empty folder remains neutral")
    }

    @Test("Only Folders transforms the palette used for its visible color key")
    func palettePresentationFollowsStyle() {
        let base = SIMD4<Float>(0.15, 0.65, 0.95, 1)
        let cushion = CardGeometry.paletteColor(base, for: .cushion)
        let folders = CardGeometry.paletteColor(base, for: .cards, foldersScheme: .balanced)

        #expect(cushion == base, "Cushion must keep the production palette untouched")
        #expect(folders == CardGeometry.leafFill(
            base, containerDepth: 0, scheme: .balanced
        ),
                "the Folders key must use the same stable depth-zero transform as the map")
        #expect(folders != base)

        for scheme in FoldersColorScheme.allCases {
            #expect(CardGeometry.paletteColor(
                base, for: .cushion, foldersScheme: scheme
            ) == base, "Folders comparison must never leak into Cushion")
        }
    }

    @Test("Leaf tone follows the surrounding container depth")
    func leafToneFollowsContainerDepth() {
        let base = SIMD4<Float>(0.25, 0.60, 0.95, 1)
        let shallow = CardGeometry.leafFill(base, containerDepth: 0, scheme: .balanced)
        let deep = CardGeometry.leafFill(base, containerDepth: 7, scheme: .balanced)
        let mean = { (c: SIMD4<Float>) in (c.x + c.y + c.z) / 3 }

        #expect(mean(deep) > mean(shallow), "a leaf should follow its lighter depth-7 chrome")
        let shallowSpread = max(shallow.x, max(shallow.y, shallow.z))
            - min(shallow.x, min(shallow.y, shallow.z))
        let deepSpread = max(deep.x, max(deep.y, deep.z))
            - min(deep.x, min(deep.y, deep.z))
        #expect(abs(shallowSpread - deepSpread) < 0.0001,
                "container tone may change, extension chroma must not")
    }

    /// The bug this pins shipped: `SpatialGrid` was built from raw `SquarifyLayout` output
    /// while Folders style DRAWS the `CardNesting` output. Every container level costs
    /// `containerPad` plus an 18pt header and then rescales what remains, so a node's drawn
    /// position drifts further from its layout position the deeper it sits. On a real
    /// `/ > Users > okan > code > ...` path that reached roughly two centimetres on screen,
    /// and the hover highlighted whichever unrelated node happened to occupy the layout
    /// coordinates under the cursor.
    @Test("Folders-style hit testing follows the nesting transform, not the raw layout")
    func hitTestingFollowsNesting() {
        // A chain of nested containers with a leaf at the bottom, mirroring a deep path.
        var items: [CardNesting.Item] = [
            CardNesting.Item(nodeIndex: 0, parentIndex: FileNode.invalid,
                             x: 0, y: 0, width: 600, height: 400, isContainer: true)
        ]
        for depth in 1...4 {
            items.append(CardNesting.Item(
                nodeIndex: UInt32(depth), parentIndex: UInt32(depth - 1),
                x: 0, y: 0, width: 600, height: 400, isContainer: true))
        }
        items.append(CardNesting.Item(nodeIndex: 5, parentIndex: 4,
                                      x: 0, y: 0, width: 600, height: 400, isContainer: false))

        var placedByNode: [UInt32: CardNesting.Placed] = [:]
        for placed in CardNesting.place(items) { placedByNode[placed.nodeIndex] = placed }

        let leaf = try! #require(placedByNode[5])
        #expect(!leaf.suppressed, "control: the leaf must actually be drawn")

        // The drift is the whole point: if drawn == layout there is nothing to get wrong.
        #expect(leaf.y > 40,
                "control: five nesting levels must displace the leaf well away from y = 0, got \(leaf.y)")

        // Hit testing the DRAWN rects returns the leaf for a point inside the leaf.
        let drawn = placedByNode.values
            .sorted { $0.nodeIndex < $1.nodeIndex }
            .map { TreemapRect(nodeIndex: $0.nodeIndex, x: $0.x, y: $0.y,
                               width: $0.width, height: $0.height, depth: 1,
                               isBackground: $0.nodeIndex != 5) }
        let grid = SpatialGrid(viewportWidth: 600, viewportHeight: 400, rects: drawn)
        let probe = (x: leaf.x + leaf.width / 2, y: leaf.y + leaf.height / 2)
        #expect(grid.hitTest(point: probe, rects: drawn) == 5,
                "a point inside the drawn leaf must resolve to the leaf")

        // Negative control: the same point against RAW layout rects, which is what the
        // renderer used to do. Every rect there is the full 600x400, so the deepest
        // container wins and the leaf is never reachable at its drawn coordinates.
        let raw = items.map {
            TreemapRect(nodeIndex: $0.nodeIndex, x: $0.x, y: $0.y,
                        width: $0.width, height: $0.height, depth: 1,
                        isBackground: $0.isContainer)
        }
        let rawGrid = SpatialGrid(viewportWidth: 600, viewportHeight: 400, rects: raw)
        let rawHit = rawGrid.hitTest(point: (x: 5, y: 5), rects: raw)
        #expect(rawHit != nil, "control: the raw grid does resolve somewhere")
    }

    /// Card style makes directory containers VISIBLE for the first time, which raises the
    /// question the cushion style never had: can a container swallow a click meant for a
    /// child sitting on top of it?
    ///
    /// It cannot. `SquarifyLayout` emits a container BEFORE its children, and
    /// `SpatialGrid.hitTest` scans its cell in reverse, so the deepest rect covering a point
    /// always wins. The container is only hit where no child covers the point - which, once
    /// children are inset, is exactly its visible frame and header strip.
    @Test("A visible container never swallows a click meant for a child")
    func containerDoesNotSwallowChildClicks() {
        // Container 0..100 with a child occupying the lower part, mirroring layout order.
        let rects = [
            TreemapRect(nodeIndex: 10, x: 0, y: 0, width: 100, height: 100, depth: 1,
                        isBackground: true),
            TreemapRect(nodeIndex: 11, x: 4, y: 22, width: 92, height: 74, depth: 2),
        ]
        let grid = SpatialGrid(viewportWidth: 100, viewportHeight: 100, rects: rects, gridSize: 8)

        #expect(grid.hitTest(point: (x: 50, y: 60), rects: rects) == 11,
                "a point over the child selects the child, not the container beneath it")
        #expect(grid.hitTest(point: (x: 50, y: 8), rects: rects) == 10,
                "the header strip, where no child sits, selects the container itself")
        #expect(grid.hitTest(point: (x: 2, y: 60), rects: rects) == 10,
                "the container's visible border likewise belongs to the container")
    }

    /// Style is a user preference, not scan state - a new scan must not silently reset it.
    /// Uses an ISOLATED defaults suite: writing to `.standard` here would change the real
    /// app's stored preference (it did, before this was fixed).
    @Test("Render style survives resetForNewScan and persists to its own store")
    @MainActor
    func stylePersistsAcrossScans() {
        let suite = "dirwiz.test.style"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let state = AppState(defaults: defaults)
        #expect(state.treemapRenderStyle == .cushion, "cushion is the default")
        #expect(state.foldersColorScheme == .clean, "review starts with the no-veil candidate")

        state.treemapRenderStyle = .cards
        state.foldersColorScheme = .warmGraphite
        state.resetForNewScan()
        #expect(state.treemapRenderStyle == .cards)
        #expect(state.foldersColorScheme == .warmGraphite)

        // A relaunch reading the same store sees the choice; `.standard` is untouched.
        #expect(AppState(defaults: defaults).treemapRenderStyle == .cards)
        #expect(AppState(defaults: defaults).foldersColorScheme == .warmGraphite)
        #expect(defaults.string(forKey: AppState.renderStyleKey) == "cards",
                "the choice is written to the injected store, not to .standard")
        #expect(defaults.integer(forKey: AppState.foldersColorSchemeKey)
                == FoldersColorScheme.warmGraphite.rawValue)
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

        // Both must still paint the middle - a card that discarded everything would also
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

/// The card nesting transform: children remapped into their parent's padded interior.
/// Pure, so it is tested directly rather than through the renderer.
@Suite("Card Nesting Tests")
struct CardNestingTests {

    private func item(_ node: UInt32, parent: UInt32, _ x: Float, _ y: Float,
                      _ w: Float, _ h: Float, container: Bool = false) -> CardNesting.Item {
        CardNesting.Item(nodeIndex: node, parentIndex: parent,
                         x: x, y: y, width: w, height: h, isContainer: container)
    }

    private func placed(_ out: [CardNesting.Placed], _ node: UInt32) -> CardNesting.Placed? {
        out.first { $0.nodeIndex == node }
    }

    /// The point of the whole transform: a child must end up strictly inside its parent,
    /// leaving the container's own fill visible as a frame.
    @Test("Children are inset inside their parent container")
    func childrenAreInsetInsideParent() throws {
        let items = [
            item(0, parent: 0, 0, 0, 400, 300, container: true),
            item(1, parent: 0, 0, 0, 200, 300),
            item(2, parent: 0, 200, 0, 200, 300),
        ]
        let out = CardNesting.place(items)
        let parent = try #require(placed(out, 0))
        let a = try #require(placed(out, 1))
        let b = try #require(placed(out, 2))

        // The container itself is not moved - only its children are pulled inward.
        #expect(parent.x == 0 && parent.y == 0 && parent.width == 400 && parent.height == 300)

        for child in [a, b] {
            #expect(child.x > parent.x, "child must not touch the container's left edge")
            #expect(child.y > parent.y, "the header strip must push children down")
            #expect(child.x + child.width < parent.x + parent.width)
            #expect(child.y + child.height < parent.y + parent.height)
        }
        // Siblings stay adjacent and in order - nesting must not reshuffle the layout.
        #expect(a.x < b.x)
        #expect(abs((a.x + a.width) - b.x) < 0.01, "siblings stay flush with each other")
    }

    /// Nesting composes: a grandchild sits inside the child, which sits inside the parent.
    /// A naive implementation that remaps against already-remapped parents applies the
    /// inset twice per level and collapses deep trees.
    @Test("Nesting composes across depth without compounding the inset")
    func nestingComposesAcrossDepth() throws {
        let items = [
            item(0, parent: 0, 0, 0, 400, 400, container: true),
            item(1, parent: 0, 0, 0, 400, 400, container: true),
            item(2, parent: 1, 0, 0, 400, 400),
        ]
        let out = CardNesting.place(items)
        let root = try #require(placed(out, 0))
        let mid = try #require(placed(out, 1))
        let leaf = try #require(placed(out, 2))

        // Strictly increasing containment, each level giving up a bounded amount.
        #expect(mid.x > root.x && mid.width < root.width)
        #expect(leaf.x > mid.x && leaf.width < mid.width)
        #expect(leaf.width > root.width * 0.75,
                "two levels of nesting must not eat most of the rect, got \(leaf.width) of \(root.width)")
    }

    /// The degradation floor. A container too small to give up padding hands its children
    /// the full rect, exactly as cushion does - the child stays visible.
    @Test("A container too small to inset leaves its child untouched")
    func tinyContainerDoesNotShrinkChildren() throws {
        let items = [
            item(0, parent: 0, 0, 0, 12, 12, container: true),
            item(1, parent: 0, 0, 0, 12, 12),
        ]
        let out = CardNesting.place(items)
        let child = try #require(placed(out, 1))
        #expect(child.x == 0 && child.y == 0 && child.width == 12 && child.height == 12)
    }

    /// A node whose parent was never emitted as a container (culled, or out of the visible
    /// subtree) must render at its layout position rather than vanish or jump.
    @Test("A node with no drawn container is left where the layout put it")
    func orphanKeepsLayoutRect() throws {
        let out = CardNesting.place([item(7, parent: 99, 10, 20, 30, 40)])
        let p = try #require(placed(out, 7))
        #expect(p.x == 10 && p.y == 20 && p.width == 30 && p.height == 40)
    }

    /// Every input produces exactly one output, in order - the transform places, it never
    /// filters. Culling decisions belong to the renderer.
    @Test("Placement is total and order-preserving")
    func placementIsTotal() {
        var items: [CardNesting.Item] = []
        for i in 0..<20 {
            let x = Float(i) * 5
            items.append(item(UInt32(i), parent: 0, x, 0, 5, 100, container: i == 0))
        }
        let out = CardNesting.place(items)
        #expect(out.count == items.count)
        let outIDs: [UInt32] = out.map { $0.nodeIndex }
        let inIDs: [UInt32] = items.map { $0.nodeIndex }
        #expect(outIDs == inIDs)
    }
}

/// Performance characteristics of the render path, pinned after a measured 25x regression
/// fix. The style toggle used to cost ~70ms of main thread on a real volume scan because
/// every click re-resolved every instance's colour; it now reuses them.
@Suite("Card Style Performance Tests")
@MainActor
struct CardStylePerformanceTests {

    /// Colours depend on the palette, recency and temporal-diff state - never on whether
    /// the map is drawn as cushions or cards. If a future change makes the style bump
    /// `colorGeneration`, the toggle silently gets slow again.
    @Test("Switching style does not invalidate resolved colours")
    func styleDoesNotBumpColorGeneration() {
        let tree = FileTree()
        var root = FileNode(); root.isDirectory = true
        tree.addNode(root, name: "root")

        let view = CushionTreemapView(fileTree: tree, rootIndex: 0, renderStyle: .cushion)
        let cards = CushionTreemapView(fileTree: tree, rootIndex: 0, renderStyle: .cards)
        // The two differ only in style; nothing colour-affecting changed between them.
        #expect(view.renderStyle != cards.renderStyle)
        #expect(view.extensionPalette.generation == cards.extensionPalette.generation)
        #expect(view.recencyGeneration == cards.recencyGeneration)
        #expect(view.temporalDiffGeneration == cards.temporalDiffGeneration)
    }

    /// The budget must not silently discard card style on an ordinary volume scan. A real
    /// scan of a 926 GB boot volume lays out ~33k rects; the old 20k ceiling meant the
    /// Cards button did nothing but cost a rebuild.
    @Test("A real-scale scan still renders as cards")
    func realScanStaysCards() {
        #expect(CardBudget.decide(nodeCount: 33_501) != .fallbackToCushion,
                "a measured real volume scan must not fall back")
        #expect(CardBudget.decide(nodeCount: 120_000) != .fallbackToCushion)
        // But something genuinely absurd still bails out rather than drawing slivers.
        #expect(CardBudget.decide(nodeCount: 400_000) == .fallbackToCushion)
    }

    /// The cull floor must stay SUB-PIXEL. An earlier version culled tiles under 3pt to buy
    /// performance, which punched grey container holes through dense regions of the map -
    /// the map is the product, and the colour cache had already removed the cost that
    /// culling was paying for. Anything a user can see must be drawn.
    @Test("Card culling never removes a visible tile")
    func cullingStaysSubPixel() {
        #expect(CardGeometry.minVisibleSide > 0)
        #expect(CardGeometry.minVisibleSide < 1.0,
                "culling anything a pixel or larger leaves visible holes in the treemap")
        #expect(CardGeometry.minVisibleSide < CardGeometry.minSideForDecoration)
    }
}

/// Folder labels. A treemap that sizes hierarchically but never names a parent looks flat -
/// early feedback was "make it hierarchical" when the SIZING already was; what was missing
/// was the labelled container.
@Suite("Folder Label Tests")
struct FolderLabelTests {

    /// Overlays must use the DRAWN geometry. Folders style insets children via
    /// `CardNesting`, so a label positioned from the raw layout rect lands on top of the
    /// folder's header chip instead of inside its own tile.
    @Test("Nesting moves a child, so its label must move with it")
    func labelsFollowNestedGeometry() throws {
        let items = [
            CardNesting.Item(nodeIndex: 0, parentIndex: 0, x: 0, y: 0,
                             width: 400, height: 300, isContainer: true),
            CardNesting.Item(nodeIndex: 1, parentIndex: 0, x: 0, y: 0,
                             width: 200, height: 300, isContainer: false),
        ]
        let placed = CardNesting.place(items)
        let container = try #require(placed.first { $0.nodeIndex == 0 })
        let child = try #require(placed.first { $0.nodeIndex == 1 })

        #expect(child.y > container.y,
                "the header strip must push the child down, leaving room for the folder name")
        #expect(child.x > container.x, "and inset it, so the container reads as a frame")
        // A label drawn at the RAW rect would sit at the container's own origin - exactly
        // where the folder chip goes.
        #expect(items[1].y == container.y, "control: the raw rect really does start at the top")
    }

    /// The header only exists where a label would be legible; below that the geometry gives
    /// the space back to children rather than reserving a strip nothing can use.
    @Test("Small containers reserve no header, so nothing claims space for a hidden label")
    func noHeaderWhenIllegible() {
        #expect(CardGeometry.headerHeight(width: 200, height: 150) > 0)
        #expect(CardGeometry.headerHeight(width: 60, height: 150) == 0)
        #expect(CardGeometry.headerHeight(width: 200, height: 30) == 0)
    }
}

/// The subdivide gate, taken from SpaceMonger 1.4's `minsizes` table. Its rule: only
/// subdivide a folder while it can still show its contents; otherwise draw one block.
@Suite("Subdivide Gate Tests")
struct SubdivideGateTests {

    private func item(_ node: UInt32, parent: UInt32, _ w: Float, _ h: Float,
                      container: Bool) -> CardNesting.Item {
        CardNesting.Item(nodeIndex: node, parentIndex: parent, x: 0, y: 0,
                         width: w, height: h, isContainer: container)
    }

    @Test("The gate matches SpaceMonger's default density row")
    func gateMatchesReference() {
        #expect(CardGeometry.minSubdivideWidth == 32)
        #expect(CardGeometry.minSubdivideHeight == 24)
        #expect(CardGeometry.canSubdivide(width: 40, height: 30))
        #expect(!CardGeometry.canSubdivide(width: 30, height: 30))
        #expect(!CardGeometry.canSubdivide(width: 40, height: 20))
    }

    /// A folder below the gate is still DRAWN - it stands in for its contents - but nothing
    /// inside it is. Drawing both would put invisible slivers on top of the block.
    @Test("A too-small folder is drawn once and its contents are not")
    func smallFolderCollapses() throws {
        let placed = CardNesting.place([
            item(0, parent: 0, 400, 300, container: true),
            item(1, parent: 0, 20, 16, container: true),   // below the gate
            item(2, parent: 1, 20, 16, container: false),  // inside it
            item(3, parent: 2, 20, 16, container: false),  // deeper still
        ])
        let small = try #require(placed.first { $0.nodeIndex == 1 })
        #expect(small.collapsed, "the folder itself is drawn as one block")
        #expect(!small.suppressed)

        for hidden in [2, 3] {
            let p = try #require(placed.first { $0.nodeIndex == UInt32(hidden) })
            #expect(p.suppressed, "everything inside a collapsed folder is suppressed")
        }
    }

    /// Suppression must propagate to the whole subtree, not just direct children -
    /// otherwise a grandchild draws on top of the block that is meant to represent it.
    @Test("Suppression reaches the entire subtree")
    func suppressionPropagates() throws {
        var items = [item(0, parent: 0, 400, 300, container: true),
                     item(1, parent: 0, 18, 14, container: true)]
        // a chain 1 -> 2 -> 3 -> ... -> 8
        for n in 2...8 { items.append(item(UInt32(n), parent: UInt32(n - 1), 18, 14, container: true)) }
        let placed = CardNesting.place(items)
        for n in 2...8 {
            let p = try #require(placed.first { $0.nodeIndex == UInt32(n) })
            #expect(p.suppressed, "node \(n) is inside a collapsed ancestor")
        }
    }

    @Test("A folder above the gate still subdivides normally")
    func largeFolderSubdivides() throws {
        let placed = CardNesting.place([
            item(0, parent: 0, 400, 300, container: true),
            item(1, parent: 0, 200, 200, container: true),
            item(2, parent: 1, 200, 200, container: false),
        ])
        let child = try #require(placed.first { $0.nodeIndex == 2 })
        #expect(!child.suppressed, "a roomy folder shows its contents")
        let mid = try #require(placed.first { $0.nodeIndex == 1 })
        #expect(!mid.collapsed)
        #expect(child.y > mid.y, "and reserves its header strip")
    }

    /// Folder chrome varies by depth so stacked levels separate; files keep extension
    /// colour, which is where the meaning lives.
    @Test("Container fill varies with depth and stays neutral")
    func containerFillByDepth() {
        let a = CardGeometry.containerFill(depth: 0)
        let b = CardGeometry.containerFill(depth: 3)
        #expect(a != b, "nesting levels must be distinguishable")

        // ADJACENT levels are what a stacked folder view actually shows, and comparing
        // depth 0 against depth 3 passed happily while neighbours were indistinguishable.
        // These are sRGB, so pin the step in 8-bit terms: below ~6/255 a large flat panel
        // reads as one slab, especially under the shader's own ~18% card gradient.
        for depth in 0..<7 {
            let here = CardGeometry.containerFill(depth: depth)
            let next = CardGeometry.containerFill(depth: depth + 1)
            let step = abs(next.x - here.x) * 255
            #expect(step >= 6,
                "depth \(depth) -> \(depth + 1) differs by only \(step)/255 - too close to read")
        }
        for depth in 0..<16 {
            let c = CardGeometry.containerFill(depth: depth)
            // neutral: the three channels stay close together, so it never reads as a hue
            let spread = max(c.x, max(c.y, c.z)) - min(c.x, min(c.y, c.z))
            #expect(spread < 0.12, "container chrome must not compete with file colour")
            #expect(c.x > 0.15 && c.x < 0.65, "and must stay a mid-dark panel")
        }
    }
}

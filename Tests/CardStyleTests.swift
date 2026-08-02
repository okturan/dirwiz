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

    /// `styleMode` and `cardSurfaceMode` occupy the old padding precisely so the uniform
    /// buffer keeps its 48-byte stride and the Swift↔Metal layout contract still holds.
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
        #expect(u.cardSurfaceMode == 0, "old callers keep the legacy card reference")
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
        #expect(src.contains("int    cardSurfaceMode"))
        #expect(src.contains("isExpandedFolder"), "card instances must carry a folder-role marker")
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

    @Test("Six numbered surface profiles have distinct structural recipes")
    func surfaceComparisonSetIsComplete() {
        let surfaces = FoldersSurfaceStyle.allCases
        #expect(surfaces.map(\.rawValue) == Array(1...6))
        #expect(surfaces.map(\.reviewLabel) == [
            "1. Crisp", "2. Fine Lines", "3. Tinted Frames",
            "4. Color Headers", "5. Soft Cards", "6. Classic Bevel",
        ])
        #expect(Set(surfaces.map(\.recipe)).count == surfaces.count)
        #expect(FoldersSurfaceStyle.crisp.recipe.bevelStrength == 0)
        #expect(FoldersSurfaceStyle.fineLines.recipe.bevelStrength == 0)
        #expect(FoldersSurfaceStyle.tintedFrames.recipe.quietsExpandedFolders)
        #expect(FoldersSurfaceStyle.colorHeaders.recipe.usesColorHeader)
        #expect(FoldersSurfaceStyle.softCards.recipe.bevelStrength > 0)
        #expect(FoldersSurfaceStyle.classicBevel.recipe.bevelStrength
                > FoldersSurfaceStyle.softCards.recipe.bevelStrength)
    }

    @Test("Flat surfaces spend less space on repeated parent frames")
    func flatSurfacesReduceContainerPad() {
        let classic = CardGeometry.containerPad(
            width: 400, height: 300, surfaceStyle: .classicBevel)
        let crisp = CardGeometry.containerPad(
            width: 400, height: 300, surfaceStyle: .crisp)
        let fine = CardGeometry.containerPad(
            width: 400, height: 300, surfaceStyle: .fineLines)
        #expect(classic == CardGeometry.maxContainerPad)
        #expect(crisp < classic)
        #expect(fine < crisp)
        #expect(fine > 0, "even the tight profile keeps an explicit parent frame")
    }

    @Test("Folder title metadata yields to long names")
    func folderSizeAdmissionPrioritizesName() {
        #expect(CardGeometry.shouldShowFolderSize(width: 260, nameCharacterCount: 8))
        #expect(!CardGeometry.shouldShowFolderSize(width: 180, nameCharacterCount: 8))
        #expect(!CardGeometry.shouldShowFolderSize(width: 260, nameCharacterCount: 24))
    }

    // MARK: - Adaptive edge backbone

    /// The native six-surface finding this encodes: every FIXED edge weight fails
    /// somewhere - thin boundaries vanish into same-colour slabs at density, thick ones
    /// turn dense regions to ink. The backbone gives every profile the same floors,
    /// ceilings, and gates; profiles keep their character only at structural sizes.
    @Test("The adaptive edge backbone has floors, ceilings, and gated character")
    func adaptiveEdgeBackbone() {
        for surface in FoldersSurfaceStyle.allCases {
            // Floor: separation never fades out above line sizes...
            #expect(CardGeometry.adaptiveOutlineOpacity(minSide: 11, surface: surface) >= 0.4,
                    "\(surface.reviewLabel) must never fade its boundary to nothing")
            #expect(CardGeometry.seamInset(minSide: 10, surface: surface)
                    >= CardGeometry.seamFloorInset,
                    "\(surface.reviewLabel) must keep the guaranteed background seam")
            // ...and the ceiling: no structural ink at dense reading sizes.
            #expect(CardGeometry.adaptiveOutlineWidth(minSide: 14, surface: surface) <= 0.9,
                    "\(surface.reviewLabel) must not draw structural weight at density")
            #expect(CardGeometry.adaptiveBevelStrength(minSide: 12, surface: surface) == 0,
                    "bevels are structural-only")

            var previousOpacity: Float = 0
            for side in stride(from: Float(11), through: 200, by: 1) {
                let opacity = CardGeometry.adaptiveOutlineOpacity(
                    minSide: side, surface: surface)
                #expect(opacity + 0.0001 >= previousOpacity,
                        "\(surface.reviewLabel) boundary presence must not weaken as cards grow")
                previousOpacity = opacity
                let width = CardGeometry.adaptiveOutlineWidth(minSide: side, surface: surface)
                #expect(width >= 0.6 && width <= 1.5,
                        "\(surface.reviewLabel) width out of bounds at side \(side)")
            }
        }

        // Character survives untouched at structural sizes.
        #expect(CardGeometry.adaptiveOutlineWidth(minSide: 128, surface: .classicBevel) == 1.5)
        #expect(CardGeometry.adaptiveOutlineOpacity(minSide: 128, surface: .classicBevel) == 0.97)
        #expect(CardGeometry.adaptiveOutlineWidth(minSide: 128, surface: .fineLines) == 0.65)
        #expect(CardGeometry.adaptiveBevelStrength(minSide: 128, surface: .classicBevel) == 0.82)
        #expect(CardGeometry.adaptiveBevelStrength(minSide: 128, surface: .softCards) == 0.28)
        #expect(CardGeometry.adaptiveBevelStrength(minSide: 128, surface: .crisp) == 0)

        // The micro valley: bounded extent, off below the floor, yields to lines.
        #expect(CardGeometry.microShade(minSide: 2.9, edgeDistance: 0) == 0,
                "sub-3pt slivers keep the exact selected depth colour")
        #expect(CardGeometry.microShade(minSide: 5, edgeDistance: 0) == 1)
        #expect(CardGeometry.microShade(minSide: 5, edgeDistance: 2) == 0,
                "the valley never reaches a tile's centre")
        #expect(CardGeometry.microShade(minSide: 12, edgeDistance: 0) == 0,
                "once lines have room, the valley yields to them")
        let crossfade = CardGeometry.microShade(minSide: 9, edgeDistance: 0)
        #expect(crossfade > 0 && crossfade < 1)
    }

    /// The backbone lives twice: Swift for tests and tooling, MSL for pixels. A drifted
    /// constant would make every deterministic gate above vouch for the wrong shader.
    @Test("Adaptive edge constants are mirrored into the Metal source")
    func adaptiveConstantsMirrored() {
        let src = CushionShaderSource.source
        #expect(src.contains("smoothstep(7.0, 11.0, minSide)"), "lineRegime")
        #expect(src.contains("smoothstep(16.0, 48.0, minSide)"), "structuralBlend")
        #expect(src.contains("smoothstep(12.0, 32.0, minSide)"), "bevelGate")
        #expect(src.contains("0.45 * smoothstep(5.0, 8.0, minSide)"), "seam floor")
        #expect(src.contains("step(3.0, minSide)"), "micro floor")
        #expect(src.contains("mix(0.85, structuralWidth, structuralBlend)"), "reading width")
        #expect(src.contains("mix(0.50, structuralOpacity, structuralBlend)"),
                "reading opacity floor")
        #expect(src.contains("baseLinear * 0.45"), "self-shade boundary colour")
        #expect(src.contains("1.0 - 0.30 * microShade"), "micro strength")
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

    @Test("Density aggregates are anonymous Folders content owned by their parent")
    func aggregatePresentationContract() {
        let aggregate = TreemapRect(
            nodeIndex: 42,
            x: 0,
            y: 0,
            width: 200,
            height: 100,
            depth: 3,
            isAggregate: true,
            aggregateOwnerIndex: 7
        )

        #expect(aggregate.interactionNodeIndex == 7,
            "the bookkeeping anchor must not become a fabricated hit identity")
        #expect(!aggregate.qualifiesForLeafLabel,
            "the representative child's name must not label a whole sibling group")
        #expect(aggregate.isRenderable(in: .cards))
        #expect(!aggregate.isRenderable(in: .cushion),
            "Folders density repair must not alter Cushion's rendered rect set")

        var ordinary = aggregate
        ordinary.isAggregate = false
        ordinary.aggregateOwnerIndex = nil
        #expect(ordinary.interactionNodeIndex == 42)
        #expect(ordinary.qualifiesForLeafLabel)
        #expect(ordinary.isRenderable(in: .cushion))
    }

    /// The rejected builds mixed two semantic systems: neutral depth panels followed by raw
    /// extension leaves. SpaceMonger does not; both its default file and folder settings use
    /// the same depth table. Every native candidate must therefore own the complete map.
    @Test("All ten native schemes color every Folders card by depth")
    func foldersUsesOneColorSemantic() {
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
        for scheme in FoldersColorScheme.allCases {
            for depth in 0..<8 {
                let depthColor = CardGeometry.containerFill(depth: depth, scheme: scheme)
                for base in productionColors {
                    #expect(CardGeometry.leafFill(
                        base, depth: depth, scheme: scheme
                    ) == depthColor,
                        "\(scheme.reviewLabel) left a file on the unrelated extension palette")
                    #expect(CardGeometry.collapsedFolderFill(
                        base, depth: depth, scheme: scheme
                    ) == depthColor,
                        "\(scheme.reviewLabel) changed semantics at the collapse boundary")
                }
            }
            for base in productionColors {
                #expect(CardGeometry.paletteColor(
                    base, for: .cards, foldersScheme: scheme
                ) == base, "File Types remains a data list below the separate depth key")
                #expect(CardGeometry.paletteColor(
                    base, for: .cushion, foldersScheme: scheme
                ) == base, "the Folders comparison must never leak into Cushion")
            }
        }
    }

    @Test("The native comparison exposes ten genuinely distinct full hierarchy palettes")
    func foldersComparisonSetIsComplete() {
        let schemes = FoldersColorScheme.allCases
        let mean = { (c: SIMD3<Float>) in (c.x + c.y + c.z) / 3 }
        let distance = { (a: SIMD3<Float>, b: SIMD3<Float>) in
            let d = a - b
            return sqrt(d.x * d.x + d.y * d.y + d.z * d.z)
        }

        #expect(schemes.map(\.rawValue) == Array(1...10))
        #expect(Set(schemes.map(\.displayName)).count == 10)
        for scheme in schemes {
            #expect(scheme.recipe.chromeLevels.count == 8,
                    "\(scheme.reviewLabel) must own every depth colour")
            for i in scheme.recipe.chromeLevels.indices {
                if i + 1 < scheme.recipe.chromeLevels.count {
                    #expect(distance(
                        scheme.recipe.chromeLevels[i], scheme.recipe.chromeLevels[i + 1]
                    ) > 0.12,
                        "\(scheme.reviewLabel) depths \(i) and \(i + 1) read as one field")
                }
                for j in scheme.recipe.chromeLevels.indices where j > i {
                    #expect(scheme.recipe.chromeLevels[i] != scheme.recipe.chromeLevels[j],
                            "\(scheme.reviewLabel) repeats depth levels \(i) and \(j)")
                }
            }
        }
        for i in schemes.indices {
            for j in schemes.indices where j > i {
                #expect(schemes[i].recipe != schemes[j].recipe,
                        "\(schemes[i].reviewLabel) and \(schemes[j].reviewLabel) must not be aliases")
                #expect(distance(
                    schemes[i].recipe.chromeLevels[0], schemes[j].recipe.chromeLevels[0]
                ) > 0.06,
                        "\(schemes[i].reviewLabel) and \(schemes[j].reviewLabel) start alike")
            }
        }

        let outerLuminances = schemes.map { mean($0.recipe.chromeLevels[0]) }
        #expect((outerLuminances.max() ?? 0) - (outerLuminances.min() ?? 0) > 0.5,
                "the options must span genuinely light and dark outer surfaces")
        #expect(FoldersColorScheme.spaceMonger.recipe.chromeLevels == [
            SIMD3(1.00, 0.50, 0.50), SIMD3(1.00, 0.75, 0.50),
            SIMD3(1.00, 1.00, 0.00), SIMD3(0.50, 1.00, 0.50),
            SIMD3(0.50, 1.00, 1.00), SIMD3(0.75, 0.75, 1.00),
            SIMD3(0.75, 0.75, 0.75), SIMD3(1.00, 0.50, 1.00),
        ], "option 1 must be traceable to SpaceMonger's BoxColors base row")
        let mono = FoldersColorScheme.monochrome.recipe.chromeLevels.map(mean)
        #expect(mono[1] > mono[0] && mono[2] < mono[1] && mono[3] > mono[2],
                "Monochrome must still distinguish adjacent depth layers")
    }

    @Test("Expanded, collapsed, aggregate, and file roles share the selected depth color")
    func folderRolesDoNotChangeColorSemantics() {
        let dirBaseA = SIMD4<Float>(0.80, 0.30, 0.38, 1)
        let dirBaseB = SIMD4<Float>(0.28, 0.40, 0.88, 1)
        for scheme in FoldersColorScheme.allCases {
            for depth in 0..<8 {
                let chrome = CardGeometry.containerFill(depth: depth, scheme: scheme)
                #expect(CardGeometry.folderContainerFill(
                    representativeColor: dirBaseA, depth: depth, scheme: scheme
                ) == chrome)
                #expect(CardGeometry.folderContainerFill(
                    representativeColor: dirBaseB, depth: depth, scheme: scheme
                ) == chrome)
                #expect(CardGeometry.folderContainerFill(
                    representativeColor: nil, depth: depth, scheme: scheme
                ) == chrome, "empty folders must use structural colour")
                #expect(CardGeometry.collapsedFolderFill(
                    dirBaseA, depth: depth, scheme: scheme
                ) == chrome)
                #expect(CardGeometry.collapsedFolderFill(
                    dirBaseB, depth: depth, scheme: scheme
                ) == chrome)
                #expect(CardGeometry.leafFill(
                    dirBaseA, depth: depth, scheme: scheme
                ) == chrome)
                #expect(CardGeometry.leafFill(
                    dirBaseB, depth: depth, scheme: scheme
                ) == chrome)
            }
        }
    }

    @Test("Both visible color keys preserve the production palette")
    func palettePresentationFollowsStyle() {
        let base = SIMD4<Float>(0.15, 0.65, 0.95, 1)
        for scheme in FoldersColorScheme.allCases {
            #expect(CardGeometry.paletteColor(
                base, for: .cushion, foldersScheme: scheme
            ) == base)
            #expect(CardGeometry.paletteColor(
                base, for: .cards, foldersScheme: scheme
            ) == base)
        }
    }

    @Test("Folders file tone follows depth and ignores extension identity")
    func fileToneFollowsDepth() {
        let blue = SIMD4<Float>(0.25, 0.60, 0.95, 1)
        let red = SIMD4<Float>(0.95, 0.25, 0.30, 1)
        for scheme in FoldersColorScheme.allCases {
            for depth in 0..<8 {
                let expected = CardGeometry.containerFill(depth: depth, scheme: scheme)
                #expect(CardGeometry.leafFill(
                    blue, depth: depth, scheme: scheme
                ) == expected)
                #expect(CardGeometry.leafFill(
                    red, depth: depth, scheme: scheme
                ) == expected)
            }
        }
    }

    @Test("Every Folders palette chooses a readable leaf-label polarity")
    func foldersLabelContrast() {
        for scheme in FoldersColorScheme.allCases {
            for depth in 0..<8 {
                #expect(CardGeometry.preferredLabelContrast(
                    depth: depth, scheme: scheme
                ) >= 4.5,
                    "\(scheme.reviewLabel) depth \(depth) misses the text contrast floor")
            }
        }
        #expect(CardGeometry.prefersDarkLabel(depth: 2, scheme: .spaceMonger),
                "SpaceMonger's yellow card must not retain a white label")
        #expect(!CardGeometry.prefersDarkLabel(depth: 0, scheme: .inkAndPaper),
                "a near-black card needs a white label")
    }

    @Test("Folders depth colors retain recency and temporal overlays")
    func foldersDepthColorRetainsOverlays() {
        let base = CardGeometry.containerFill(depth: 2, scheme: .spaceMonger)
        let resolver = TreemapColorResolver(
            recencyFactors: [0.35],
            isRecencyOverlayEnabled: true,
            temporalDiffKinds: [TemporalDiffKind.grown.rawValue],
            temporalDiffStrengths: [1.0],
            isTemporalDiffEnabled: true
        )
        let overlaid = resolver.applyingOverlays(to: base, nodeIndex: 0)

        #expect(overlaid.w == 0.35)
        #expect(overlaid.x != base.x || overlaid.y != base.y || overlaid.z != base.z,
            "switching Folders to a depth palette must not disable the diff overlay")
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
        #expect(state.foldersColorScheme == .spaceMonger,
            "review starts with the source-traceable reference palette")
        #expect(state.foldersSurfaceStyle == .crisp,
            "new and invalid stores start on the bevel-free surface")

        state.treemapRenderStyle = .cards
        state.foldersColorScheme = .forest
        state.foldersSurfaceStyle = .tintedFrames
        state.resetForNewScan()
        #expect(state.treemapRenderStyle == .cards)
        #expect(state.foldersColorScheme == .forest)
        #expect(state.foldersSurfaceStyle == .tintedFrames)

        // A relaunch reading the same store sees the choice; `.standard` is untouched.
        #expect(AppState(defaults: defaults).treemapRenderStyle == .cards)
        #expect(AppState(defaults: defaults).foldersColorScheme == .forest)
        #expect(AppState(defaults: defaults).foldersSurfaceStyle == .tintedFrames)
        #expect(defaults.string(forKey: AppState.renderStyleKey) == "cards",
                "the choice is written to the injected store, not to .standard")
        #expect(defaults.integer(forKey: AppState.foldersColorSchemeKey)
                == FoldersColorScheme.forest.rawValue)
        #expect(defaults.integer(forKey: AppState.foldersSurfaceStyleKey)
                == FoldersSurfaceStyle.tintedFrames.rawValue)

        defaults.set(999, forKey: AppState.foldersSurfaceStyleKey)
        #expect(AppState(defaults: defaults).foldersSurfaceStyle == .crisp,
                "an invalid persisted review value must fail back to the flat default")
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
    private func render(
        styleMode: Int32,
        side: Int,
        color: SIMD4<Float> = SIMD4<Float>(0.5, 0.5, 0.5, 1),
        cardSurfaceMode: Int32 = 0,
        expandedFolder: Bool = false
    ) throws -> Rendered? {
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
        var coefs = SIMD4<Float>(-1.6, 1.6, -1.6, 1.6)
        if styleMode == 1 {
            coefs.w = expandedFolder ? 1 : 0
        }
        var instance = CushionInstance(
            rect: SIMD4<Float>(0, 0, Float(side), Float(side)),
            coefs: coefs,
            color: color
        )
        let ld = normalize(SIMD3<Float>(0.5, 0.5, 1.0))
        var uniforms = CushionUniforms(
            viewportSize: SIMD2<Float>(Float(side), Float(side)),
            ambient: 0.25,
            padding1: 0,
            lightDir: SIMD4<Float>(ld.x, ld.y, ld.z, 0),
            hoveredIndex: -1,
            selectedIndex: -1,
            styleMode: styleMode,
            cardSurfaceMode: cardSurfaceMode
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

    /// The reference renderer does not rely on a neighbouring depth colour to describe a
    /// box. It draws a black outline, then a bright top/left and dark bottom/right bevel.
    /// This pixel gate proves that renderer-wide treatment survives every palette choice.
    @Test("Cards have a stable dark boundary and directional bevel contrast")
    func cardBoundaryAndBevel() throws {
        let side = 128
        guard let card = try render(
            styleMode: 1,
            side: side,
            color: SIMD4<Float>(1.0, 1.0, 0.0, 1)
        ) else { return }

        func energy(_ pixel: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(pixel.b) + Int(pixel.g) + Int(pixel.r)
        }

        let centre = energy(card.rgb(x: 64, y: 64))
        let outline = energy(card.rgb(x: 2, y: 64))
        let top = energy(card.rgb(x: 64, y: 5))
        let bottom = energy(card.rgb(x: 64, y: 122))
        let left = energy(card.rgb(x: 5, y: 64))
        let right = energy(card.rgb(x: 122, y: 64))

        #expect(outline + 180 < centre,
                "the boundary must stay dark even around a bright yellow card")
        #expect(top > bottom + 40, "top bevel must be brighter than bottom bevel")
        #expect(left > right + 40, "left bevel must be brighter than right bevel")
    }

    @Test("Crisp has a flat symmetric interior without a directional bevel")
    func crispIsFlat() throws {
        let side = 128
        guard let crisp = try render(
            styleMode: 1,
            side: side,
            color: SIMD4<Float>(0.25, 0.65, 0.95, 1),
            cardSurfaceMode: Int32(FoldersSurfaceStyle.crisp.rawValue)
        ) else { return }

        func energy(_ pixel: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(pixel.b) + Int(pixel.g) + Int(pixel.r)
        }
        let top = energy(crisp.rgb(x: 64, y: 5))
        let bottom = energy(crisp.rgb(x: 64, y: 122))
        let left = energy(crisp.rgb(x: 5, y: 64))
        let right = energy(crisp.rgb(x: 122, y: 64))
        #expect(abs(top - bottom) <= 4, "Crisp must not imply a top light source")
        #expect(abs(left - right) <= 4, "Crisp must not imply a left light source")
    }

    @Test("Quiet-frame surfaces alter expanded folders but not occupied blocks")
    func quietFramesUseRoleMarker() throws {
        let side = 128
        let color = SIMD4<Float>(1.0, 0.50, 0.50, 1)
        let mode = Int32(FoldersSurfaceStyle.tintedFrames.rawValue)
        guard let folder = try render(
            styleMode: 1, side: side, color: color,
            cardSurfaceMode: mode, expandedFolder: true),
              let leaf = try render(
                styleMode: 1, side: side, color: color,
                cardSurfaceMode: mode, expandedFolder: false),
              let crispLeaf = try render(
                styleMode: 1, side: side, color: color,
                cardSurfaceMode: Int32(FoldersSurfaceStyle.crisp.rawValue),
                expandedFolder: false) else { return }

        func energy(_ pixel: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(pixel.b) + Int(pixel.g) + Int(pixel.r)
        }
        #expect(energy(folder.rgb(x: 64, y: 64)) + 80
                < energy(leaf.rgb(x: 64, y: 64)),
                "only expanded-folder chrome should become quiet")
        #expect(leaf.rgb(x: 64, y: 64) == crispLeaf.rgb(x: 64, y: 64),
                "leaf depth colour must not depend on a quiet-frame profile")
    }

    @Test("Color Headers reserves depth color for the title band")
    func colorHeadersSeparateTitleFromBody() throws {
        let side = 128
        guard let card = try render(
            styleMode: 1,
            side: side,
            color: SIMD4<Float>(0.50, 1.0, 1.0, 1),
            cardSurfaceMode: Int32(FoldersSurfaceStyle.colorHeaders.rawValue),
            expandedFolder: true
        ) else { return }

        func energy(_ pixel: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(pixel.b) + Int(pixel.g) + Int(pixel.r)
        }
        #expect(energy(card.rgb(x: 64, y: 10))
                > energy(card.rgb(x: 64, y: 64)) + 90,
                "the title row must keep the selected depth color over quiet chrome")
    }

    @Test("All six surface profiles produce distinct card output")
    func surfaceProfilesArePixelDistinct() throws {
        var results: [(FoldersSurfaceStyle, [UInt8])] = []
        for surface in FoldersSurfaceStyle.allCases {
            guard let rendered = try render(
                styleMode: 1,
                side: 128,
                color: SIMD4<Float>(0.50, 1.0, 1.0, 1),
                cardSurfaceMode: Int32(surface.rawValue),
                expandedFolder: true
            ) else { return }
            results.append((surface, rendered.pixels))
        }
        for i in results.indices {
            for j in results.indices where j > i {
                #expect(results[i].1 != results[j].1,
                        "\(results[i].0.reviewLabel) and \(results[j].0.reviewLabel) rendered identically")
            }
        }
    }

    @Test("Folders surface uniform is pixel-inert in Cushion")
    func cushionIgnoresSurfaceMode() throws {
        guard let crisp = try render(
            styleMode: 0, side: 128,
            cardSurfaceMode: Int32(FoldersSurfaceStyle.crisp.rawValue)),
              let classic = try render(
                styleMode: 0, side: 128,
                cardSurfaceMode: Int32(FoldersSurfaceStyle.classicBevel.rawValue)) else { return }
        #expect(crisp.pixels == classic.pixels,
                "surface selection must not enter Cushion shading")
    }

    /// Below line sizes a card stays fully occupied, but from the 3pt micro floor up it
    /// darkens toward its own edge: same-depth siblings share EXACT colours, so without
    /// this valley a dense field of equal tiles reads as one false slab. The centre keeps
    /// the exact colour - the valley is multiplicative shade, never ink.
    @Test("A tiny card stays occupied and separates itself with a soft edge valley")
    func tinyCardKeepsOccupiedColorWithValley() throws {
        let side = 5
        guard let tiny = try render(styleMode: 1, side: side) else { return }
        for y in 0..<side {
            for x in 0..<side {
                #expect(!tiny.isBackground(x: x, y: y),
                        "a tiny card must draw every pixel, not shrink into padding (\(x),\(y))")
            }
        }
        func energy(_ p: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(p.b) + Int(p.g) + Int(p.r)
        }
        let centre = tiny.rgb(x: 2, y: 2)
        let edge = tiny.rgb(x: 0, y: 2)
        #expect(abs(Int(centre.r) - 127) <= 2, "the centre keeps the exact fill colour")
        #expect(energy(centre) - energy(edge) >= 15, "the edge valley must be visible")
        #expect(edge.r >= 90, "the valley is a shade of the fill, never black ink")
    }

    /// The user-visible failure the adaptive backbone fixes, half one: thin fixed lines
    /// vanished at density. Reading-size tiles now separate with a darker shade of their
    /// OWN colour at a floored opacity - present, hue-preserving, and never black.
    @Test("Reading-size boundaries keep the card's own hue and never vanish")
    func readingBoundariesAreSelfShaded() throws {
        let side = 14
        guard let card = try render(
            styleMode: 1, side: side,
            color: SIMD4<Float>(1.0, 0.50, 0.50, 1),
            cardSurfaceMode: Int32(FoldersSurfaceStyle.crisp.rawValue)
        ) else { return }
        func energy(_ p: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(p.b) + Int(p.g) + Int(p.r)
        }
        let centre = energy(card.rgb(x: side / 2, y: side / 2))
        var darkest = 3 * 255
        var darkestRed = 255
        for x in 0..<4 where !card.isBackground(x: x, y: side / 2) {
            let p = card.rgb(x: x, y: side / 2)
            if energy(p) < darkest { darkest = energy(p); darkestRed = Int(p.r) }
        }
        #expect(darkest < centre - 20, "separation must exist at reading sizes")
        #expect(darkestRed >= 150, "the boundary is a shade of red, not black structural ink")
    }

    /// Half two of the same failure: thick treatments made dense regions unclear. The
    /// dual bevel is a structural treatment now - a dense Classic tile has no light
    /// source at all, while the 128pt control above keeps the full reference bevel.
    @Test("Directional bevels are admitted only at structural sizes")
    func bevelIsStructuralOnly() throws {
        let side = 12
        guard let dense = try render(
            styleMode: 1, side: side,
            color: SIMD4<Float>(0.50, 1.0, 1.0, 1),
            cardSurfaceMode: Int32(FoldersSurfaceStyle.classicBevel.rawValue)
        ) else { return }
        func energy(_ p: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
            Int(p.b) + Int(p.g) + Int(p.r)
        }
        let top = energy(dense.rgb(x: 6, y: 2))
        let bottom = energy(dense.rgb(x: 6, y: 9))
        let left = energy(dense.rgb(x: 2, y: 6))
        let right = energy(dense.rgb(x: 9, y: 6))
        #expect(abs(top - bottom) <= 8, "no light source may appear on a dense Classic tile")
        #expect(abs(left - right) <= 8, "no directional shadow either")
    }

    /// Structure needs decisiveness where it has room: the same profile must draw a
    /// clearly stronger boundary on a large card than on a dense tile.
    @Test("Boundaries strengthen from reading to structural sizes")
    func structuralBoundaryIsStrongerThanReading() throws {
        func darkestEdge(_ r: Rendered) -> Int {
            var darkest = 3 * 255
            for x in 0..<6 where !r.isBackground(x: x, y: r.height / 2) {
                let p = r.rgb(x: x, y: r.height / 2)
                darkest = min(darkest, Int(p.b) + Int(p.g) + Int(p.r))
            }
            return darkest
        }
        guard let reading = try render(
            styleMode: 1, side: 14,
            color: SIMD4<Float>(1.0, 0.50, 0.50, 1),
            cardSurfaceMode: Int32(FoldersSurfaceStyle.crisp.rawValue)),
              let structural = try render(
                styleMode: 1, side: 128,
                color: SIMD4<Float>(1.0, 0.50, 0.50, 1),
                cardSurfaceMode: Int32(FoldersSurfaceStyle.crisp.rawValue)) else { return }
        #expect(darkestEdge(structural) < darkestEdge(reading) - 60,
                "large cards must carry a decisively stronger boundary than dense tiles")
    }

    /// The floor is profile-independent: no surface choice may lose separation at dense
    /// sizes, and none may paint it as heavy ink. Separation is either a background seam
    /// pixel or a visible self-shade darkening.
    @Test("Every profile keeps visible separation at dense sizes without black ink")
    func densityFloorHoldsForEveryProfile() throws {
        for surface in FoldersSurfaceStyle.allCases {
            guard let card = try render(
                styleMode: 1, side: 10,
                color: SIMD4<Float>(0.50, 1.0, 1.0, 1),
                cardSurfaceMode: Int32(surface.rawValue)
            ) else { return }
            func energy(_ p: (b: UInt8, g: UInt8, r: UInt8)) -> Int {
                Int(p.b) + Int(p.g) + Int(p.r)
            }
            let centre = energy(card.rgb(x: 5, y: 5))
            var separated = false
            var minEnergy = 3 * 255
            for x in 0..<3 {
                if card.isBackground(x: x, y: 5) { separated = true; continue }
                minEnergy = min(minEnergy, energy(card.rgb(x: x, y: 5)))
            }
            if minEnergy < centre - 20 { separated = true }
            #expect(separated,
                    "\(surface.reviewLabel) lost its separation floor at dense sizes")
            if minEnergy < 3 * 255 {
                #expect(minEnergy > centre / 3,
                        "\(surface.reviewLabel) still paints dense boundaries as heavy ink")
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

    @Test("Surface changes nesting only, while preserving complete display rectangles")
    func surfaceControlsPublishedNesting() throws {
        let items = [
            item(0, parent: 0, 0, 0, 400, 300, container: true),
            item(1, parent: 0, 0, 0, 400, 300),
        ]
        let crisp = try #require(placed(
            CardNesting.place(items, surfaceStyle: .crisp), 1))
        let classic = try #require(placed(
            CardNesting.place(items, surfaceStyle: .classicBevel), 1))

        #expect(crisp.x < classic.x)
        #expect(crisp.width > classic.width)
        #expect(crisp.y < classic.y,
                "both reserve the same title row; only repeated frame padding changes")

        let rect = TreemapRect(nodeIndex: crisp.nodeIndex, x: crisp.x, y: crisp.y,
                               width: crisp.width, height: crisp.height, depth: 1)
        let grid = SpatialGrid(viewportWidth: 400, viewportHeight: 300, rects: [rect])
        #expect(grid.hitTest(
            point: (x: crisp.x + 0.1, y: crisp.y + crisp.height / 2),
            rects: [rect]
        ) == crisp.nodeIndex,
        "the complete post-nesting rect remains clickable; shader inset never enters the grid")
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

    /// Option 1 is no longer an invented neutral ramp. It is the reference sequence from
    /// SpaceMonger, whose default file and folder settings both select `BoxColors` by depth.
    @Test("Default SpaceMonger fill has a distinct color at every adjacent depth")
    func containerFillByDepth() {
        let a = CardGeometry.containerFill(depth: 0)
        let b = CardGeometry.containerFill(depth: 3)
        #expect(a != b, "nesting levels must be distinguishable")

        // Adjacent levels are what a stacked folder view actually shows. Pin full RGB
        // distance rather than one-channel drift so multi-hue schemes are measured honestly.
        for depth in 0..<7 {
            let here = CardGeometry.containerFill(depth: depth)
            let next = CardGeometry.containerFill(depth: depth + 1)
            let delta = next - here
            let distance = sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
            #expect(distance > 0.12,
                "depth \(depth) -> \(depth + 1) is too close to read")
        }
        #expect(CardGeometry.containerFill(depth: 0)
                == CardGeometry.containerFill(depth: 8),
            "the eight-color source palette cycles by depth")
    }
}

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

    /// Product vocabulary, matching the treemap toolbar toggle exactly - the raw values
    /// ("cushion"/"cards") stay stable persistence identifiers.
    public var displayName: String {
        switch self {
        case .cushion: return "Cushions"
        case .cards:   return "Folders"
        }
    }
}

/// Native comparison set for choosing the final Folders colour treatment on real trees.
///
/// This is deliberately expressed as renderer inputs rather than screenshot filters: every
/// option runs through the same Metal instances, nesting, overlays, and hit testing as production.
/// The numbered names make feedback unambiguous while the review is open.
public enum FoldersColorScheme: Int, CaseIterable, Identifiable, Sendable {
    case spaceMonger = 1
    case ocean
    case forest
    case sunset
    case spectrum
    case candy
    case earth
    case nord
    case monochrome
    case inkAndPaper

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .spaceMonger: return "SpaceMonger"
        case .ocean:       return "Ocean"
        case .forest:      return "Forest"
        case .sunset:      return "Sunset"
        case .spectrum:    return "Spectrum"
        case .candy:       return "Candy"
        case .earth:       return "Earth"
        case .nord:        return "Nord"
        case .monochrome:  return "Monochrome"
        case .inkAndPaper: return "Ink & Paper"
        }
    }

    public var reviewLabel: String { "\(rawValue). \(displayName)" }

    public var explanation: String {
        switch self {
        case .spaceMonger: return "The original SpaceMonger depth sequence"
        case .ocean:       return "Navy, blue, cyan, and teal depth layers"
        case .forest:      return "Pine, leaf, moss, earth, and sage layers"
        case .sunset:      return "Plum through magenta, red, orange, and gold"
        case .spectrum:    return "A high-contrast full-spectrum depth cycle"
        case .candy:       return "Bright playful hues with strong adjacent contrast"
        case .earth:       return "Clay, sand, olive, teal, and slate layers"
        case .nord:        return "Muted cool hues with a restrained red accent"
        case .monochrome:  return "Alternating neutral light and dark layers"
        case .inkAndPaper: return "Alternating ink-dark and paper-light tinted layers"
        }
    }

    struct Recipe: Hashable, Sendable {
        /// One map colour for every `depth & 7` value. An explicit table is
        /// intentional: a shared base-plus-step equation made ten numerically different
        /// recipes look like one dark scheme with ten strength settings.
        let chromeLevels: [SIMD3<Float>]
    }

    /// Static storage avoids allocating an eight-element Array for every visible node
    /// while rebuilding a multi-million-item tree's Metal instances.
    private static let recipes: [Recipe] = [
            Recipe(chromeLevels: [
                // SpaceMonger 1.4's BoxColors base row, normalized from 8-bit RGB.
                SIMD3(1.00, 0.50, 0.50), SIMD3(1.00, 0.75, 0.50),
                SIMD3(1.00, 1.00, 0.00), SIMD3(0.50, 1.00, 0.50),
                SIMD3(0.50, 1.00, 1.00), SIMD3(0.75, 0.75, 1.00),
                SIMD3(0.75, 0.75, 0.75), SIMD3(1.00, 0.50, 1.00),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.10, 0.22, 0.45), SIMD3(0.12, 0.42, 0.72),
                SIMD3(0.12, 0.66, 0.86), SIMD3(0.08, 0.55, 0.58),
                SIMD3(0.24, 0.76, 0.66), SIMD3(0.40, 0.64, 0.90),
                SIMD3(0.25, 0.36, 0.68), SIMD3(0.10, 0.68, 0.72),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.10, 0.34, 0.22), SIMD3(0.34, 0.54, 0.20),
                SIMD3(0.58, 0.66, 0.22), SIMD3(0.18, 0.62, 0.30),
                SIMD3(0.58, 0.44, 0.18), SIMD3(0.38, 0.24, 0.16),
                SIMD3(0.48, 0.66, 0.46), SIMD3(0.20, 0.48, 0.38),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.30, 0.12, 0.42), SIMD3(0.52, 0.18, 0.56),
                SIMD3(0.76, 0.20, 0.52), SIMD3(0.90, 0.25, 0.40),
                SIMD3(0.92, 0.38, 0.24), SIMD3(0.94, 0.56, 0.20),
                SIMD3(0.90, 0.72, 0.20), SIMD3(0.66, 0.28, 0.50),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.10, 0.58, 0.78), SIMD3(0.22, 0.34, 0.78),
                SIMD3(0.48, 0.22, 0.76), SIMD3(0.78, 0.18, 0.62),
                SIMD3(0.90, 0.24, 0.32), SIMD3(0.94, 0.52, 0.16),
                SIMD3(0.72, 0.76, 0.16), SIMD3(0.14, 0.68, 0.40),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.82, 0.30, 0.64), SIMD3(0.46, 0.30, 0.82),
                SIMD3(0.12, 0.68, 0.82), SIMD3(0.94, 0.48, 0.20),
                SIMD3(0.20, 0.72, 0.42), SIMD3(0.30, 0.46, 0.90),
                SIMD3(0.88, 0.72, 0.18), SIMD3(0.88, 0.22, 0.38),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.40, 0.24, 0.16), SIMD3(0.68, 0.34, 0.22),
                SIMD3(0.78, 0.62, 0.34), SIMD3(0.50, 0.54, 0.24),
                SIMD3(0.24, 0.50, 0.44), SIMD3(0.30, 0.38, 0.46),
                SIMD3(0.66, 0.46, 0.34), SIMD3(0.46, 0.62, 0.52),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.31, 0.36, 0.46), SIMD3(0.36, 0.51, 0.64),
                SIMD3(0.30, 0.61, 0.60), SIMD3(0.48, 0.63, 0.49),
                SIMD3(0.60, 0.53, 0.68), SIMD3(0.43, 0.55, 0.72),
                SIMD3(0.55, 0.58, 0.62), SIMD3(0.70, 0.40, 0.42),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.20, 0.21, 0.23), SIMD3(0.72, 0.73, 0.75),
                SIMD3(0.32, 0.33, 0.35), SIMD3(0.84, 0.85, 0.87),
                SIMD3(0.42, 0.43, 0.45), SIMD3(0.64, 0.65, 0.67),
                SIMD3(0.26, 0.27, 0.29), SIMD3(0.90, 0.91, 0.93),
            ]),
            Recipe(chromeLevels: [
                SIMD3(0.10, 0.12, 0.16), SIMD3(0.84, 0.80, 0.72),
                SIMD3(0.16, 0.20, 0.27), SIMD3(0.76, 0.84, 0.82),
                SIMD3(0.23, 0.16, 0.25), SIMD3(0.86, 0.76, 0.80),
                SIMD3(0.17, 0.24, 0.22), SIMD3(0.82, 0.84, 0.72),
            ]),
    ]

    var recipe: Recipe { Self.recipes[rawValue - 1] }
}

/// How Folders turns the selected depth colours into cards and folder chrome.
///
/// Colour and surface are deliberately independent while the native comparison is open:
/// a palette answers which hues identify depth, while this value controls edge weight,
/// bevel, parent-frame treatment, and nesting pad. Numbered labels keep screenshots and
/// feedback unambiguous.
public enum FoldersSurfaceStyle: Int, CaseIterable, Identifiable, Sendable {
    case crisp = 1
    case fineLines
    case tintedFrames
    case colorHeaders
    case softCards
    case classicBevel

    public var id: Int { rawValue }

    public var displayName: String {
        switch self {
        case .crisp:          return "Crisp"
        case .fineLines:      return "Fine Lines"
        case .tintedFrames:   return "Tinted Frames"
        case .colorHeaders:   return "Color Headers"
        case .softCards:      return "Soft Cards"
        case .classicBevel:   return "Classic Bevel"
        }
    }

    public var reviewLabel: String { "\(rawValue). \(displayName)" }

    public var explanation: String {
        switch self {
        case .crisp:
            return "Flat cards, compact parent frames, and a clear one-pixel edge"
        case .fineLines:
            return "Tight nesting with the thinnest depth-tinted boundaries"
        case .tintedFrames:
            return "Quiet parent chrome with unchanged depth colors inside"
        case .colorHeaders:
            return "Quiet parent bodies with depth color reserved for folder titles"
        case .softCards:
            return "A restrained edge and shallow directional relief"
        case .classicBevel:
            return "The full SpaceMonger-inspired outline and dual bevel reference"
        }
    }

    struct Recipe: Hashable, Sendable {
        let containerPadScale: Float
        let visualInsetScale: Float
        /// STRUCTURAL-regime boundary values: what this profile draws on structurally
        /// large cards. Micro and reading-size cards share the adaptive backbone in
        /// `CardGeometry` instead - a profile has no say below structural sizes.
        let outlineWidth: Float
        let outlineOpacity: Float
        let bevelStrength: Float
        let quietsExpandedFolders: Bool
        let usesColorHeader: Bool
    }

    var recipe: Recipe {
        switch self {
        case .crisp:
            return Recipe(containerPadScale: 0.65, visualInsetScale: 0.55,
                          outlineWidth: 0.95, outlineOpacity: 0.82,
                          bevelStrength: 0, quietsExpandedFolders: false,
                          usesColorHeader: false)
        case .fineLines:
            return Recipe(containerPadScale: 0.35, visualInsetScale: 0.35,
                          outlineWidth: 0.65, outlineOpacity: 0.62,
                          bevelStrength: 0, quietsExpandedFolders: false,
                          usesColorHeader: false)
        case .tintedFrames:
            return Recipe(containerPadScale: 0.65, visualInsetScale: 0.55,
                          outlineWidth: 0.90, outlineOpacity: 0.76,
                          bevelStrength: 0, quietsExpandedFolders: true,
                          usesColorHeader: false)
        case .colorHeaders:
            return Recipe(containerPadScale: 0.65, visualInsetScale: 0.45,
                          outlineWidth: 0.90, outlineOpacity: 0.72,
                          bevelStrength: 0, quietsExpandedFolders: true,
                          usesColorHeader: true)
        case .softCards:
            return Recipe(containerPadScale: 0.65, visualInsetScale: 0.75,
                          outlineWidth: 0.90, outlineOpacity: 0.55,
                          bevelStrength: 0.28, quietsExpandedFolders: false,
                          usesColorHeader: false)
        case .classicBevel:
            return Recipe(containerPadScale: 1.00, visualInsetScale: 1.00,
                          outlineWidth: 1.50, outlineOpacity: 0.97,
                          bevelStrength: 0.82, quietsExpandedFolders: false,
                          usesColorHeader: false)
        }
    }
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

    /// Complete depth palette for every Folders card. SpaceMonger indexes the same table
    /// with `depth & 7` for files and folders. Keeping the table explicit is load-bearing:
    /// the first native comparison offered ten variants of one nearly monochrome ramp.
    public static func containerFill(
        depth: Int,
        scheme: FoldersColorScheme = .spaceMonger
    ) -> SIMD4<Float> {
        let color = scheme.recipe.chromeLevels[depth & 7]
        return SIMD4<Float>(
            color.x,
            color.y,
            color.z,
            1.0
        )
    }

    /// Selects whichever of black or white has the greater WCAG contrast against the
    /// flat centre of a Folders card. SpaceMonger's bright reference palette uses dark
    /// labels; keeping DirWiz labels unconditionally white made yellow, cyan, and light
    /// grey cards difficult to read even after their boundaries were repaired.
    public static func prefersDarkLabel(
        depth: Int,
        scheme: FoldersColorScheme = .spaceMonger
    ) -> Bool {
        let background = scheme.recipe.chromeLevels[depth & 7]
        let luminance = relativeLuminance(background)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return blackContrast >= whiteContrast
    }

    /// Contrast delivered by `prefersDarkLabel`, exposed internally for a deterministic
    /// all-palettes gate rather than relying on labels looking acceptable in one screenshot.
    static func preferredLabelContrast(
        depth: Int,
        scheme: FoldersColorScheme = .spaceMonger
    ) -> Float {
        let background = scheme.recipe.chromeLevels[depth & 7]
        let luminance = relativeLuminance(background)
        let blackContrast = (luminance + 0.05) / 0.05
        let whiteContrast = 1.05 / (luminance + 0.05)
        return max(blackContrast, whiteContrast)
    }

    private static func relativeLuminance(_ color: SIMD3<Float>) -> Float {
        func linearized(_ channel: Float) -> Float {
            if channel <= 0.04045 { return channel / 12.92 }
            return pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearized(color.x)
            + 0.7152 * linearized(color.y)
            + 0.0722 * linearized(color.z)
    }

    /// SpaceMonger's default color model is one depth palette for both folders and files.
    /// Using unrelated extension colors only for the leaves caused every candidate to share
    /// the same abrupt panel-to-red/blue transition. Cushion remains the file-type view.
    public static func leafFill(
        _ base: SIMD4<Float>,
        depth: Int = 0,
        scheme: FoldersColorScheme = .spaceMonger
    ) -> SIMD4<Float> {
        _ = base
        return containerFill(depth: depth, scheme: scheme)
    }

    /// Expanded folders and their direct contents share one depth sequence. This makes the
    /// color transition describe nesting instead of changing semantics at the leaf boundary.
    public static func folderContainerFill(
        representativeColor: SIMD4<Float>?,
        depth: Int,
        scheme: FoldersColorScheme = .spaceMonger
    ) -> SIMD4<Float> {
        _ = representativeColor
        return containerFill(depth: depth, scheme: scheme)
    }

    /// A collapsed folder keeps the depth colour it would have had if expanded. Its area is
    /// occupied content, but it must not reintroduce an unrelated extension-color system.
    public static func collapsedFolderFill(
        _ representativeColor: SIMD4<Float>,
        depth: Int,
        scheme: FoldersColorScheme = .spaceMonger
    ) -> SIMD4<Float> {
        _ = representativeColor
        return containerFill(depth: depth, scheme: scheme)
    }

    /// File Types rows keep their category swatches for filtering and size comparison.
    /// Folders displays a separate eight-swatch depth key above those rows.
    public static func paletteColor(
        _ base: SIMD4<Float>,
        for style: TreemapRenderStyle,
        foldersScheme: FoldersColorScheme = .spaceMonger
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

    public static func containerPad(
        width: Float,
        height: Float,
        surfaceStyle: FoldersSurfaceStyle = .classicBevel
    ) -> Float {
        let minSide = min(width, height)
        guard minSide >= minSideForDecoration * 3 else { return 0 }
        let sourcePad = min(maxContainerPad, minSide * 0.02)
        return sourcePad * surfaceStyle.recipe.containerPadScale
    }

    /// The region a container's children are remapped into: its own rect, minus the
    /// padding on every side, minus a header strip on top when one is legible.
    ///
    /// Returns nil when the container is too small to give up anything - the children then
    /// fill it edge to edge exactly as they do in cushion style. That is the degradation
    /// floor: nesting decoration is the first thing sacrificed, never the child itself.
    public static func innerRect(
        x: Float, y: Float, width: Float, height: Float,
        surfaceStyle: FoldersSurfaceStyle = .classicBevel
    ) -> (x: Float, y: Float, width: Float, height: Float)? {
        let pad = containerPad(width: width, height: height, surfaceStyle: surfaceStyle)
        let header = headerHeight(width: width, height: height)
        guard pad > 0 || header > 0 else { return nil }
        let innerW = width - 2 * pad
        let innerH = height - 2 * pad - header
        // Never hand back a degenerate or inverted region.
        guard innerW >= minSideForDecoration, innerH >= minSideForDecoration else { return nil }
        return (x: x + pad, y: y + pad + header, width: innerW, height: innerH)
    }

    /// Folder metadata is secondary to the folder name. A pure admission rule keeps the
    /// view deterministic and ensures a long name never competes with its size in a narrow
    /// 18-point title row.
    public static func shouldShowFolderSize(width: Float, nameCharacterCount: Int) -> Bool {
        width >= 210 && nameCharacterCount <= 18
    }

    // MARK: - Adaptive edge backbone

    /// What KIND of boundary a card carries is decided by its drawn size, not by the
    /// selected surface. The native six-surface review found every fixed weight failing
    /// somewhere: thin boundaries vanish between same-depth siblings (which share EXACT
    /// colours, so a faded line merges them into one false slab), while thick outlines
    /// and mid-size bevels turn dense regions into ink. The numbered surfaces therefore
    /// style only the STRUCTURAL end of one shared backbone:
    ///
    ///   < 3pt      exact flat fill - slivers keep the exact selected depth colour
    ///   3..~7pt    multiplicative self-shade valley toward the tile's own edge
    ///   ~7..16pt   hairline in a darker shade of the card's OWN colour at a floored
    ///              opacity, plus a guaranteed minimum background seam
    ///   16..48pt   blend toward the profile's structural colour/width/opacity; bevels
    ///              are admitted on their own 12->32pt ramp
    ///
    /// Every constant here is mirrored literally in `CushionShaderSource` (pinned by the
    /// mirrored-constant test); the shader is what actually paints.
    static let microShadeFloor: Float = 3
    static let microShadeStrength: Float = 0.30
    static let readingOutlineWidth: Float = 0.85
    static let readingOutlineOpacity: Float = 0.50
    static let readingShadeFactor: Float = 0.45
    static let seamFloorInset: Float = 0.45

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// 0 below ~7pt, where a line has no room; 1 from 11pt, where lines carry separation.
    static func lineRegime(minSide: Float) -> Float {
        smoothstep(7, 11, minSide)
    }

    /// 0 at reading sizes; 1 once the profile's structural character fully applies.
    static func structuralBlend(minSide: Float) -> Float {
        smoothstep(16, 48, minSide)
    }

    /// Directional bevels are a structural treatment; at density they read as mush.
    static func bevelGate(minSide: Float) -> Float {
        smoothstep(12, 32, minSide)
    }

    static func structuralOutlineWidth(minSide: Float, surface: FoldersSurfaceStyle) -> Float {
        if surface == .classicBevel { return min(1.5, max(0.75, minSide * 0.025)) }
        return surface.recipe.outlineWidth
    }

    static func adaptiveOutlineWidth(minSide: Float, surface: FoldersSurfaceStyle) -> Float {
        let blend = structuralBlend(minSide: minSide)
        let structural = structuralOutlineWidth(minSide: minSide, surface: surface)
        return readingOutlineWidth + (structural - readingOutlineWidth) * blend
    }

    static func adaptiveOutlineOpacity(minSide: Float, surface: FoldersSurfaceStyle) -> Float {
        let blend = structuralBlend(minSide: minSide)
        let mixed = readingOutlineOpacity
            + (surface.recipe.outlineOpacity - readingOutlineOpacity) * blend
        return mixed * lineRegime(minSide: minSide)
    }

    static func adaptiveBevelStrength(minSide: Float, surface: FoldersSurfaceStyle) -> Float {
        surface.recipe.bevelStrength * bevelGate(minSide: minSide)
    }

    /// The effective shader gap, including the floor that guarantees same-colour siblings
    /// a background seam even where a profile's own inset rounds to nothing (Fine Lines
    /// at Retina density did exactly that).
    static func seamInset(minSide: Float, surface: FoldersSurfaceStyle) -> Float {
        let decorate: Float = minSide >= minSideForDecoration ? 1 : 0
        let profile = decorate * min(maxGap, minSide * 0.06)
            * surface.recipe.visualInsetScale
        return max(profile, seamFloorInset * smoothstep(5, 8, minSide))
    }

    /// Strength of the sub-line valley at a given distance inside the drawn edge.
    static func microShade(minSide: Float, edgeDistance: Float) -> Float {
        guard minSide >= microShadeFloor else { return 0 }
        let extent = min(max(minSide * 0.25, 0.75), 1.25)
        return (1 - lineRegime(minSide: minSide))
            * (1 - smoothstep(0, extent, edgeDistance))
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
    public static func place(
        _ items: [Item],
        surfaceStyle: FoldersSurfaceStyle = .classicBevel
    ) -> [Placed] {
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
                   let inner = CardGeometry.innerRect(
                       x: x, y: y, width: w, height: h,
                       surfaceStyle: surfaceStyle
                   ) {
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

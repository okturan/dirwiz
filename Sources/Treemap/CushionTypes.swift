import Foundation

// MARK: - GPU Data Structures

/// Per-instance data matching the Metal shader struct layout.
struct CushionInstance {
    var rect: SIMD4<Float>   // x, y, width, height in pixels
    var coefs: SIMD4<Float>  // parabolic cushion coefficients [ax2, bx, ay2, by]
    var color: SIMD4<Float>  // base RGBA
}

/// Uniform buffer matching the Metal shader struct layout.
/// IMPORTANT: float3/SIMD3 is padded to 16 bytes in Metal but not guaranteed in Swift structs.
/// Using SIMD4<Float> for lightDir ensures identical layout on both sides.
struct CushionUniforms {
    var viewportSize: SIMD2<Float>
    var ambient: Float
    var padding1: Float
    var lightDir: SIMD4<Float>   // w unused; matches Metal float4 layout exactly
    var hoveredIndex: Int32
    var selectedIndex: Int32 = -1
    var padding2: (Float, Float) = (0, 0)  // 8-byte tail padding; keep stride 48
}

// MARK: - Cushion Coefficient Calculation

/// Cushion shading constants.
enum CushionConstants {
    static let H: Float = 0.40   // initial ridge height
    static let F: Float = 0.90   // depth falloff factor
}

/// Add a parabolic ridge for one nesting level (flat param version).
/// The ridge creates a bump across the ancestor rectangle, normalized to the leaf's [0..1] space.
func addRidge(_ coefs: inout SIMD4<Float>,
              rectX: Float, rectY: Float, rectW: Float, rectH: Float,
              ancestorX: Float, ancestorY: Float, ancestorW: Float, ancestorH: Float,
              h: Float) {
    guard rectW > 0, rectH > 0 else { return }

    // Map ancestor bounds into the leaf rect's [0..1] parametric space.
    let x1 = (ancestorX - rectX) / rectW
    let x2 = (ancestorX + ancestorW - rectX) / rectW
    let y1 = (ancestorY - rectY) / rectH
    let y2 = (ancestorY + ancestorH - rectY) / rectH

    let dx = x2 - x1
    let dy = y2 - y1

    guard dx > 0, dy > 0 else { return }

    // Horizontal ridge: parabola in x direction.
    let invDx2 = 1.0 / (dx * dx)
    coefs.x += -4.0 * h * invDx2
    coefs.y += 4.0 * h * (x1 + x2) * invDx2

    // Vertical ridge: parabola in y direction.
    let invDy2 = 1.0 / (dy * dy)
    coefs.z += -4.0 * h * invDy2
    coefs.w += 4.0 * h * (y1 + y2) * invDy2
}

/// Compute cushion coefficients inline from flat rect + ancestor array.
/// Used by SquarifyLayout during layout to avoid storing ancestors on TreemapRect.
func computeCoefs(
    rectX: Float, rectY: Float, rectW: Float, rectH: Float,
    ancestors: [(x: Float, y: Float, w: Float, h: Float)]
) -> SIMD4<Float> {
    var coefs = SIMD4<Float>.zero
    for (level, anc) in ancestors.enumerated() {
        let h = CushionConstants.H * powf(CushionConstants.F, Float(level))
        addRidge(&coefs,
                 rectX: rectX, rectY: rectY, rectW: rectW, rectH: rectH,
                 ancestorX: anc.x, ancestorY: anc.y, ancestorW: anc.w, ancestorH: anc.h,
                 h: h)
    }
    return coefs
}

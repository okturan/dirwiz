import Foundation
import MetalKit

// MARK: - GPU Data Structures

/// Per-instance data matching the Metal shader struct layout.
struct CushionInstance {
    var rect: SIMD4<Float>   // x, y, width, height in pixels
    var coefs: SIMD4<Float>  // parabolic cushion coefficients [ax2, bx, ay2, by]
    var color: SIMD4<Float>  // base RGBA
}

/// Uniform buffer matching the Metal shader struct layout.
struct CushionUniforms {
    var viewportSize: SIMD2<Float>
    var ambient: Float
    var padding1: Float
    var lightDir: SIMD3<Float>
    var hoveredIndex: Int32
}

// MARK: - Cushion Coefficient Calculation

/// Cushion shading constants.
enum CushionConstants {
    static let H: Float = 0.40   // initial ridge height
    static let F: Float = 0.90   // depth falloff factor
}

/// Accumulate parabolic ridge cushion coefficients from ancestor rectangles.
/// Each nesting level adds a parabolic ridge in both x and y directions.
func computeCushionCoefficients(for rect: TreemapRect) -> SIMD4<Float> {
    var coefs = SIMD4<Float>(0, 0, 0, 0)

    // Process each ancestor level.
    for (level, ancestor) in rect.ancestors.enumerated() {
        let h = CushionConstants.H * powf(CushionConstants.F, Float(level))
        addRidge(&coefs, rect: rect, ancestorX: ancestor.x, ancestorY: ancestor.y,
                 ancestorW: ancestor.w, ancestorH: ancestor.h, h: h)
    }

    return coefs
}

/// Add a parabolic ridge for one nesting level.
/// The ridge creates a bump across the ancestor rectangle, normalized to the leaf's [0..1] space.
func addRidge(_ coefs: inout SIMD4<Float>, rect: TreemapRect,
              ancestorX: Float, ancestorY: Float,
              ancestorW: Float, ancestorH: Float, h: Float) {
    guard rect.width > 0, rect.height > 0 else { return }

    // Map ancestor bounds into the leaf rect's [0..1] parametric space.
    let x1 = (ancestorX - rect.x) / rect.width
    let x2 = (ancestorX + ancestorW - rect.x) / rect.width
    let y1 = (ancestorY - rect.y) / rect.height
    let y2 = (ancestorY + ancestorH - rect.y) / rect.height

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

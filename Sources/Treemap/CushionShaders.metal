#include <metal_stdlib>
using namespace metal;

// MARK: - Data Structures

/// Per-instance data for a single treemap rectangle.
struct CushionInstance {
    float4 rect;   // x, y, width, height (in pixel coordinates)
    float4 coefs;  // Parabolic cushion coefficients [ax2, bx, ay2, by]
    float4 color;  // Base RGBA color
};

/// Uniform buffer shared across all instances.
struct CushionUniforms {
    float2 viewportSize;
    float  ambient;
    float  padding1;
    float3 lightDir;
    float  padding2;
};

// MARK: - Vertex Shader

struct VertexOut {
    float4 position [[position]];
    float2 rectPos;     // position within the rect [0..1]
    float4 coefs;       // cushion coefficients
    float4 baseColor;   // base RGBA color
    float2 rectSize;    // width, height of the rect in pixels
};

vertex VertexOut cushionVertexShader(
    uint vertexID       [[vertex_id]],
    uint instanceID     [[instance_id]],
    const device CushionInstance* instances [[buffer(0)]],
    constant CushionUniforms& uniforms     [[buffer(1)]]
) {
    CushionInstance inst = instances[instanceID];

    // Generate quad corners from vertex ID (triangle strip: 0,1,2,3).
    //  0 -- 1
    //  |  / |
    //  2 -- 3
    float2 corner;
    corner.x = (vertexID & 1) == 0 ? 0.0 : 1.0;
    corner.y = (vertexID & 2) == 0 ? 0.0 : 1.0;

    // Pixel position of this corner.
    float px = inst.rect.x + corner.x * inst.rect.z;
    float py = inst.rect.y + corner.y * inst.rect.w;

    // Transform pixel coordinates to clip space.
    float clipX = (px / uniforms.viewportSize.x) * 2.0 - 1.0;
    float clipY = 1.0 - (py / uniforms.viewportSize.y) * 2.0;

    VertexOut out;
    out.position = float4(clipX, clipY, 0.0, 1.0);
    out.rectPos = corner;  // [0..1] within the rect
    out.coefs = inst.coefs;
    out.baseColor = inst.color;
    out.rectSize = float2(inst.rect.z, inst.rect.w);

    return out;
}

// MARK: - Fragment Shader

fragment float4 cushionFragmentShader(
    VertexOut in [[stage_in]],
    constant CushionUniforms& uniforms [[buffer(1)]]
) {
    // Parametric position within rect [0..1].
    float px = in.rectPos.x;
    float py = in.rectPos.y;

    // Compute cushion surface normal from parabolic coefficients.
    // Surface: z = coefs.x * px^2 + coefs.y * px + coefs.z * py^2 + coefs.w * py
    // Normal = (-dz/dpx, -dz/dpy, 1)
    float nx = -(2.0 * in.coefs.x * px + in.coefs.y);
    float ny = -(2.0 * in.coefs.z * py + in.coefs.w);
    float nz = 1.0;

    float3 normal = normalize(float3(nx, ny, nz));
    float3 lightDir = normalize(uniforms.lightDir);

    // Lambertian shading.
    float diffuse = max(0.0, dot(normal, lightDir));
    float intensity = uniforms.ambient + (1.0 - uniforms.ambient) * diffuse;

    float4 finalColor = float4(in.baseColor.rgb * intensity, in.baseColor.a);

    // 1px border: darken pixels within 0.5px of the rect edge.
    float edgeX = min(px * in.rectSize.x, (1.0 - px) * in.rectSize.x);
    float edgeY = min(py * in.rectSize.y, (1.0 - py) * in.rectSize.y);
    float edgeDist = min(edgeX, edgeY);

    if (edgeDist < 0.5) {
        float borderFactor = edgeDist / 0.5; // 0 at edge, 1 at 0.5px in
        finalColor.rgb *= mix(0.3, 1.0, borderFactor);
    }

    return finalColor;
}

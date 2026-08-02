/// Metal shader source compiled at runtime via device.makeLibrary(source:).
/// This avoids the SPM limitation where .metal files aren't compiled into .metallib.
enum CushionShaderSource {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct CushionInstance {
        float4 rect;
        float4 coefs;
        float4 color;
    };

    struct CushionUniforms {
        float2 viewportSize;
        float  ambient;
        float  padding1;
        float4 lightDir;      // w unused; matches Swift SIMD4<Float> layout exactly
        int    hoveredIndex;
        int    selectedIndex;
        int    styleMode;      // 0 = cushion, 1 = card
        float  padding2;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 rectPos;
        float4 coefs;
        float4 baseColor;
        float2 rectSize;
        int    instanceID;
    };

    // sRGB -> linear
    inline float3 srgbToLinear(float3 c) {
        return pow(c, float3(2.2));
    }

    // linear -> sRGB
    inline float3 linearToSrgb(float3 c) {
        return pow(c, float3(1.0 / 2.2));
    }

    vertex VertexOut cushionVertexShader(
        uint vertexID       [[vertex_id]],
        uint instanceID     [[instance_id]],
        const device CushionInstance* instances [[buffer(0)]],
        constant CushionUniforms& uniforms     [[buffer(1)]]
    ) {
        CushionInstance inst = instances[instanceID];
        float2 corner;
        corner.x = (vertexID & 1) == 0 ? 0.0 : 1.0;
        corner.y = (vertexID & 2) == 0 ? 0.0 : 1.0;
        float px = inst.rect.x + corner.x * inst.rect.z;
        float py = inst.rect.y + corner.y * inst.rect.w;
        float clipX = (px / uniforms.viewportSize.x) * 2.0 - 1.0;
        float clipY = 1.0 - (py / uniforms.viewportSize.y) * 2.0;
        VertexOut out;
        out.position = float4(clipX, clipY, 0.0, 1.0);
        out.rectPos = corner;
        out.coefs = inst.coefs;
        out.baseColor = inst.color;
        out.rectSize = float2(inst.rect.z, inst.rect.w);
        out.instanceID = int(instanceID);
        return out;
    }

    fragment float4 cushionFragmentShader(
        VertexOut in [[stage_in]],
        constant CushionUniforms& uniforms [[buffer(1)]]
    ) {
        float px = in.rectPos.x;
        float py = in.rectPos.y;

        // Gamma-correct: sRGB -> linear
        float3 baseLinear = srgbToLinear(in.baseColor.rgb);

        float3 litColor;
        float edgeDist;

        if (uniforms.styleMode == 1) {
            // ---- Card style -------------------------------------------------------
            // Hierarchy is drawn (containers + gaps), not lit, so no cushion normal.
            // Keep the interior flat. Structure comes from a stable dark outline plus
            // directional bevel edges, matching the contrast roles in SpaceMonger's
            // DrawBox + DrawDualBox path instead of washing the whole tile with a gradient.
            litColor = baseLinear;

            // Rounded-box SDF in pixel space. Radius and inset scale with the rect's
            // smaller side and reach zero for small rects, so a shrinking card loses its
            // rounding, then its gap, then draws as plain fill - it never becomes pure
            // padding (mirrors CardGeometry on the Swift side).
            float2 halfSize = in.rectSize * 0.5;
            float  minSide  = min(in.rectSize.x, in.rectSize.y);
            float  decorate = step(6.0, minSide);
            float  radius   = decorate * min(6.0, minSide * 0.12);
            float  inset    = decorate * min(2.0, minSide * 0.06);

            float2 p = (in.rectPos - 0.5) * in.rectSize;
            float2 b = max(halfSize - inset - radius, float2(0.0));
            float2 d = abs(p) - b;
            float  sdf = length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - radius;

            // Cut the corners and the gap. Nothing is drawn outside the rounded box, so
            // the view's background shows through between siblings.
            if (sdf > 0.0) { discard_fragment(); }

            // Distance to the card's own edge drives hover/selection outlines below.
            edgeDist = -sdf;

            // Large cards get an explicit boundary independent of the colours on either
            // side. The treatment fades in between 6 and 12px so dense tiny tiles keep
            // their occupied colour instead of turning into an all-outline black field.
            float edgeDecoration = smoothstep(6.0, 12.0, minSide);
            float outlineWidth = edgeDecoration
                * min(1.5, max(0.75, minSide * 0.025));
            float bevelWidth = edgeDecoration
                * min(2.25, max(0.75, minSide * 0.035));

            // Distances from the four straight edges, after the visual gap. Rounded
            // corners are still governed by the SDF above; these only choose whether an
            // inside bevel faces the virtual light (top/left) or shadow (bottom/right).
            float leftDistance   = px * in.rectSize.x - inset;
            float rightDistance  = (1.0 - px) * in.rectSize.x - inset;
            float topDistance    = py * in.rectSize.y - inset;
            float bottomDistance = (1.0 - py) * in.rectSize.y - inset;
            float bevelStart = outlineWidth + 0.35;
            float lightEdge = 1.0 - smoothstep(
                bevelStart, bevelStart + bevelWidth, min(leftDistance, topDistance));
            float darkEdge = 1.0 - smoothstep(
                bevelStart, bevelStart + bevelWidth, min(rightDistance, bottomDistance));
            float signedBevel = lightEdge - darkEdge;

            float3 brightColor = mix(baseLinear, float3(1.0), 0.34);
            float3 darkColor = baseLinear * 0.52;
            litColor = mix(litColor, brightColor, max(signedBevel, 0.0) * 0.82);
            litColor = mix(litColor, darkColor, max(-signedBevel, 0.0) * 0.82);

            // SpaceMonger uses a black box outside its coloured bevel. Put that role
            // inside the card's drawn area so CardGeometry and hit testing remain exact.
            float outlineAlpha = edgeDecoration * (
                1.0 - smoothstep(max(0.0, outlineWidth - 0.45),
                                 outlineWidth + 0.45, edgeDist));
            litColor = mix(litColor, float3(0.004), outlineAlpha * 0.97);
        } else {
            // ---- Cushion style (unchanged) ----------------------------------------
            // Compute cushion surface normal from parabolic coefficients.
            float nx = -(2.0 * in.coefs.x * px + in.coefs.y);
            float ny = -(2.0 * in.coefs.z * py + in.coefs.w);
            float nz = 1.0;
            float3 N = normalize(float3(nx, ny, nz));

            // Lighting vectors.
            float3 lightDir = normalize(uniforms.lightDir.xyz);
            float3 viewDir = float3(0.0, 0.0, 1.0);

            // Diffuse (Lambertian).
            float diffuse = max(0.0, dot(N, lightDir));

            // Specular (Blinn-Phong).
            float3 H = normalize(lightDir + viewDir);
            float spec = pow(max(dot(N, H), 0.0), 48.0);
            float specIntensity = 0.15;

            // Combined lighting.
            float intensity = uniforms.ambient + (1.0 - uniforms.ambient) * diffuse;
            litColor = baseLinear * intensity + float3(specIntensity * spec);

            // Anti-aliased borders using smoothstep.
            float edgeX = min(px * in.rectSize.x, (1.0 - px) * in.rectSize.x);
            float edgeY = min(py * in.rectSize.y, (1.0 - py) * in.rectSize.y);
            edgeDist = min(edgeX, edgeY);
            float borderFactor = smoothstep(0.0, 1.5, edgeDist);
            litColor *= mix(0.25, 1.0, borderFactor);
        }

        // Selection highlight: brighten selected instance (GPU-side, avoids CPU buffer rebuild).
        if (in.instanceID == uniforms.selectedIndex) {
            litColor += float3(0.15);
        }

        // Hover glow: brighten hovered instance and add outline.
        if (in.instanceID == uniforms.hoveredIndex) {
            // Bright outline: 2px from edge.
            if (edgeDist < 2.0) {
                float outlineAlpha = 1.0 - smoothstep(0.5, 2.0, edgeDist);
                litColor = mix(litColor, float3(1.0, 1.0, 1.0), outlineAlpha * 0.6);
            }
            litColor += float3(0.12);
        }

        // Recency heatmap: desaturate stale files toward dark grayscale.
        // recencyFactor is encoded in baseColor.a: 1.0 = recent, 0.0 = stale.
        float recencyFactor = in.baseColor.a;
        if (recencyFactor < 0.99) {
            float luma = dot(litColor, float3(0.299, 0.587, 0.114));
            float3 staleColor = float3(luma) * 0.30;
            litColor = mix(staleColor, litColor, recencyFactor);
        }

        // Clamp and gamma-correct: linear -> sRGB.
        float3 result = linearToSrgb(clamp(litColor, 0.0, 1.0));

        return float4(result, 1.0);
    }
    """
}

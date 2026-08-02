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
        int    cardSurfaceMode; // 1...6; 0 keeps legacy card callers on Classic Bevel
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
            // Palette and surface are independent. Palette supplies `baseLinear`; the
            // numbered surface controls chrome, edge weight, and optional bevel. Zero is
            // accepted as Classic Bevel so old offscreen callers keep their reference.
            int surfaceMode = uniforms.cardSurfaceMode;
            if (surfaceMode < 1 || surfaceMode > 6) { surfaceMode = 6; }

            // `coefs.w` is a role marker only in the card path. Cushion retains the real
            // coefficient. A value of one means an expanded folder; leaves, aggregates,
            // and collapsed folders remain zero and keep the unmodified depth colour.
            bool isExpandedFolder = in.coefs.w > 0.5 && in.coefs.w < 1.5;

            litColor = baseLinear;
            if (isExpandedFolder && (surfaceMode == 3 || surfaceMode == 4)) {
                float luma = dot(baseLinear, float3(0.2126, 0.7152, 0.0722));
                float chroma = surfaceMode == 3 ? 0.28 : 0.16;
                litColor = mix(float3(luma), baseLinear, chroma) * 0.55;

                // Color Headers keeps the body quiet but restores the selected depth
                // colour in the 18-point title row that CardNesting already reserved.
                float yInPixels = py * in.rectSize.y;
                if (surfaceMode == 4 && yInPixels <= min(18.0, in.rectSize.y)) {
                    litColor = baseLinear;
                }
            }

            // Rounded-box SDF in pixel space. Radius and inset scale with the rect's
            // smaller side and reach zero for small rects, so a shrinking card loses its
            // rounding, then its gap, then draws as plain fill - it never becomes pure
            // padding (mirrors CardGeometry on the Swift side).
            float2 halfSize = in.rectSize * 0.5;
            float  minSide  = min(in.rectSize.x, in.rectSize.y);
            float  decorate = step(6.0, minSide);
            float insetScale = 1.0;
            float radiusScale = 1.0;
            if (surfaceMode == 1) { insetScale = 0.55; radiusScale = 0.65; }
            if (surfaceMode == 2) { insetScale = 0.35; radiusScale = 0.35; }
            if (surfaceMode == 3) { insetScale = 0.55; radiusScale = 0.65; }
            if (surfaceMode == 4) { insetScale = 0.45; radiusScale = 0.55; }
            if (surfaceMode == 5) { insetScale = 0.75; radiusScale = 0.80; }
            float  radius = decorate * min(6.0, minSide * 0.12) * radiusScale;
            float  inset = decorate * min(2.0, minSide * 0.06) * insetScale;

            // Guaranteed seam floor. Same-depth siblings share EXACT colours, so a gap
            // that rounds to nothing merges them into one false slab (Fine Lines at
            // Retina density did exactly that). Mirrored by CardGeometry.seamInset.
            inset = max(inset, 0.45 * smoothstep(5.0, 8.0, minSide));

            float2 p = (in.rectPos - 0.5) * in.rectSize;
            float2 b = max(halfSize - inset - radius, float2(0.0));
            float2 d = abs(p) - b;
            float  sdf = length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0) - radius;

            // Cut the corners and the gap. Nothing is drawn outside the rounded box, so
            // the view's background shows through between siblings.
            if (sdf > 0.0) { discard_fragment(); }

            // Distance to the card's own edge drives hover/selection outlines below.
            edgeDist = -sdf;

            // ---- Adaptive edge backbone (mirrored by CardGeometry) ----------------
            // A card's drawn size decides what KIND of boundary it can carry; the
            // numbered surface styles only the structural end. Micro tiles get a soft
            // self-shade valley - lines have no room there and near-black ink turns
            // dense regions to mush. Reading sizes get a hairline in a darker shade of
            // the card's OWN colour at a floored opacity, so thin boundaries never
            // vanish. From ~16pt the boundary blends toward the profile's structural
            // character, and directional bevels are admitted only on the 12->32pt ramp.
            float lineRegime = smoothstep(7.0, 11.0, minSide);
            float structuralBlend = smoothstep(16.0, 48.0, minSide);
            float bevelGate = smoothstep(12.0, 32.0, minSide);

            float structuralWidth = 0.95;
            float structuralOpacity = 0.82;
            float bevelStrength = 0.0;
            float bevelWidth = 0.0;
            if (surfaceMode == 2) {
                structuralWidth = 0.65; structuralOpacity = 0.62;
            } else if (surfaceMode == 3) {
                structuralWidth = 0.90; structuralOpacity = 0.76;
            } else if (surfaceMode == 4) {
                structuralWidth = 0.90; structuralOpacity = 0.72;
            } else if (surfaceMode == 5) {
                structuralWidth = 0.90; structuralOpacity = 0.55;
                bevelWidth = 1.20; bevelStrength = 0.28;
            } else if (surfaceMode == 6) {
                structuralWidth = min(1.5, max(0.75, minSide * 0.025));
                structuralOpacity = 0.97;
                bevelWidth = min(2.25, max(0.75, minSide * 0.035));
                bevelStrength = 0.82;
            }
            bevelStrength *= bevelGate;
            bevelWidth *= bevelGate;

            float outlineWidth = mix(0.85, structuralWidth, structuralBlend);
            float outlineOpacity = mix(0.50, structuralOpacity, structuralBlend)
                * lineRegime;

            // Distances from the four straight edges, after the visual gap. Rounded
            // corners are still governed by the SDF above; these only choose whether an
            // inside bevel faces the virtual light (top/left) or shadow (bottom/right).
            float leftDistance   = px * in.rectSize.x - inset;
            float rightDistance  = (1.0 - px) * in.rectSize.x - inset;
            float topDistance    = py * in.rectSize.y - inset;
            float bottomDistance = (1.0 - py) * in.rectSize.y - inset;
            if (bevelStrength > 0.0) {
                float bevelStart = outlineWidth + 0.35;
                float lightEdge = 1.0 - smoothstep(
                    bevelStart, bevelStart + bevelWidth, min(leftDistance, topDistance));
                float darkEdge = 1.0 - smoothstep(
                    bevelStart, bevelStart + bevelWidth, min(rightDistance, bottomDistance));
                float signedBevel = lightEdge - darkEdge;
                float brightMix = surfaceMode == 6 ? 0.34 : 0.20;
                float darkScale = surfaceMode == 6 ? 0.52 : 0.72;
                float3 brightColor = mix(litColor, float3(1.0), brightMix);
                float3 darkColor = litColor * darkScale;
                litColor = mix(litColor, brightColor,
                               max(signedBevel, 0.0) * bevelStrength);
                litColor = mix(litColor, darkColor,
                               max(-signedBevel, 0.0) * bevelStrength);
            }

            // The outline stays inside the drawn rectangle, so the complete pre-gap rect
            // remains the hit target. Reading-size boundaries are a darker shade of the
            // card's own colour, so dense same-hue fields separate without accumulating
            // black ink; structural boundaries blend toward the profile character (Fine
            // Lines stays depth-tinted, the other profiles use a neutral near-black).
            float3 structuralColor = surfaceMode == 2
                ? baseLinear * 0.10
                : float3(0.004);
            float3 outlineColor = mix(baseLinear * 0.45, structuralColor, structuralBlend);
            float outlineAlpha =
                1.0 - smoothstep(max(0.0, outlineWidth - 0.45),
                                 outlineWidth + 0.45, edgeDist);
            litColor = mix(litColor, outlineColor, outlineAlpha * outlineOpacity);

            // Below line sizes, separation comes from a soft valley toward the card's
            // own edge - the same job cushion lighting does at density, done
            // multiplicatively so tile centres keep the exact selected depth colour.
            // Off below the 3pt micro floor so slivers stay exact flat fill.
            float microExtent = clamp(minSide * 0.25, 0.75, 1.25);
            float microShade = step(3.0, minSide) * (1.0 - lineRegime)
                * (1.0 - smoothstep(0.0, microExtent, edgeDist));
            litColor *= (1.0 - 0.30 * microShade);
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

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
        // padding to 16-byte alignment handled by Metal automatically
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
        float3 litColor = baseLinear * intensity + float3(specIntensity * spec);

        // Anti-aliased borders using smoothstep.
        float edgeX = min(px * in.rectSize.x, (1.0 - px) * in.rectSize.x);
        float edgeY = min(py * in.rectSize.y, (1.0 - py) * in.rectSize.y);
        float edgeDist = min(edgeX, edgeY);
        float borderFactor = smoothstep(0.0, 1.5, edgeDist);
        litColor *= mix(0.25, 1.0, borderFactor);

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

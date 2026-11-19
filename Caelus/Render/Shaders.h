// Shaders.h — the Metal source for the globe, compiled at launch.
//
// Compiling from source keeps the build a plain Makefile: no .metallib to keep
// in sync, and the shaders live next to the renderer that depends on them.

#pragma once

static const char* kCaelusShaderSource = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct FrameUniforms {
    float4x4 viewProjection;
    float4 sunDirection;    // xyz: Earth → Sun, scene space
    float4 cameraPosition;  // xyz: eye
};

struct PointUniforms {
    float4x4 viewProjection;
    float4 color;
    float pointSize;
    float pad0, pad1, pad2;
};

struct EarthVertex {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 uv;
};

struct EarthOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float3 worldPosition;
};

vertex EarthOut earth_vertex(uint vid [[vertex_id]],
                             const device EarthVertex* vertices [[buffer(0)]],
                             constant FrameUniforms& uniforms [[buffer(1)]]) {
    EarthVertex v = vertices[vid];
    EarthOut out;
    out.position = uniforms.viewProjection * float4(v.position, 1.0);
    out.normal = v.normal;
    out.uv = v.uv;
    out.worldPosition = v.position;
    return out;
}

// Day texture, night lights, and a specular highlight — the Swift app's SceneKit
// surface shader, rewritten for a single pass.
fragment float4 earth_fragment(EarthOut in [[stage_in]],
                               constant FrameUniforms& uniforms [[buffer(1)]],
                               texture2d<float> dayTexture [[texture(0)]],
                               texture2d<float> nightTexture [[texture(1)]],
                               texture2d<float> specularTexture [[texture(2)]],
                               sampler linearSampler [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float3 sun = normalize(uniforms.sunDirection.xyz);
    float3 view = normalize(uniforms.cameraPosition.xyz - in.worldPosition);

    float ndl = dot(n, sun);

    float3 day = dayTexture.sample(linearSampler, in.uv).rgb;
    float3 night = nightTexture.sample(linearSampler, in.uv).rgb;
    float specular = specularTexture.sample(linearSampler, in.uv).r;

    // 1 on the night side, 0 in daylight, with a soft twilight band.
    float dark = smoothstep(0.10, -0.18, ndl);
    float lift = smoothstep(-0.35, 0.25, ndl);

    float3 diffuse = day * mix(0.10, 1.0, lift);
    float3 emission = night * dark * 1.15;

    float3 halfway = normalize(sun + view);
    float gloss = pow(saturate(dot(n, halfway)), 48.0) * specular * 0.55 * saturate(ndl * 2.0);

    float3 color = diffuse + emission + gloss * float3(1.0, 0.97, 0.92);
    color += float3(0.010, 0.016, 0.030);  // a whisper of ambient
    return float4(color, 1.0);
}

// A limb glow that only appears where the atmosphere is lit.
fragment float4 atmosphere_fragment(EarthOut in [[stage_in]],
                                   constant FrameUniforms& uniforms [[buffer(1)]]) {
    float3 n = normalize(in.normal);
    float3 view = normalize(uniforms.cameraPosition.xyz - in.worldPosition);
    float facing = saturate(dot(n, view));

    float rim = pow(1.0 - facing, 3.0);
    float edge = smoothstep(0.0, 0.42, facing);
    float glow = rim * edge;

    float3 sun = normalize(uniforms.sunDirection.xyz);
    float lit = smoothstep(-0.45, 0.32, dot(n, sun));

    float3 cool = float3(0.06, 0.17, 0.38);
    float3 warm = float3(0.36, 0.66, 1.00);
    float3 tint = mix(cool, warm, lit);

    return float4(tint * glow * (0.16 + 1.35 * lit), 1.0);
}

struct PointOut {
    float4 position [[position]];
    float pointSize [[point_size]];
    float4 color;
};

vertex PointOut satellite_vertex(uint vid [[vertex_id]],
                                 const device float4* positions [[buffer(0)]],
                                 constant PointUniforms& uniforms [[buffer(1)]]) {
    PointOut out;
    float4 p = positions[vid];
    if (isnan(p.x) || isnan(p.y) || isnan(p.z)) {
        out.position = float4(0.0, 0.0, 0.0, 0.0);
        out.pointSize = 1.0;
        out.color = float4(0.0);
        return out;
    }
    out.position = uniforms.viewProjection * float4(p.xyz, 1.0);
    out.pointSize = uniforms.pointSize;
    out.color = uniforms.color;
    return out;
}

fragment float4 satellite_fragment(PointOut in [[stage_in]],
                                   float2 pointCoord [[point_coord]]) {
    // Square point sprites read as pixels; a soft disc reads as a light.
    float2 offset = pointCoord * 2.0 - 1.0;
    float distance = length(offset);
    float mask = smoothstep(1.0, 0.55, distance);
    float core = 0.72 + 0.55 * smoothstep(0.7, 0.0, distance);
    float4 color = in.color;
    color.a *= mask * core;
    return color;
}

struct StarVertex {
    packed_float3 position;
    packed_float4 color;
    float size;
};

vertex PointOut star_vertex(uint vid [[vertex_id]],
                            const device StarVertex* stars [[buffer(0)]],
                            constant FrameUniforms& uniforms [[buffer(1)]]) {
    StarVertex star = stars[vid];
    PointOut out;
    out.position = uniforms.viewProjection * float4(star.position, 1.0);
    out.pointSize = star.size;
    out.color = star.color;
    return out;
}

struct LineVertex {
    packed_float3 position;
    packed_float4 color;
};

struct LineOut {
    float4 position [[position]];
    float4 color;
};

vertex LineOut line_vertex(uint vid [[vertex_id]],
                           const device LineVertex* vertices [[buffer(0)]],
                           constant FrameUniforms& uniforms [[buffer(1)]]) {
    LineVertex v = vertices[vid];
    LineOut out;
    out.position = uniforms.viewProjection * float4(v.position, 1.0);
    out.color = v.color;
    return out;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    return in.color;
}
)METAL";

#include <metal_stdlib>
using namespace metal;

struct UpBind {
    float4 region;     // source px: x, y, w, h
    float2 texSize;    // physical size of the upscaled texture
    float factor;
    float blend;       // 0 = ignore the upscaled texture
};

struct ContentParams {
    float4 contentRect;   // canvas px: x, y, w, h (the full source at zoom 1)
    float4 radii;         // tl, tr, br, bl (canvas px)
    float2 camCenter;     // source px
    float2 srcSize;
    float magnification;  // canvas px per source px
    float pad;
    int2 canvasSize;
    UpBind up;
};

static inline float sdRoundBox(float2 p, float2 b, float4 r) {
    float2 rr = (p.x > 0.0) ? float2(r.y, r.z) : float2(r.x, r.w);   // (top, bottom) for this side
    float rad = (p.y > 0.0) ? rr.y : rr.x;
    float2 q = abs(p) - b + rad;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - rad;
}

/// Catmull-Rom with the 5-fetch bilinear optimisation. uv is normalised; levelSize is the size of the sampled mip.
static inline float4 catmull(texture2d<float> tex, sampler s, float2 uv, float2 levelSize, float lod) {
    float2 sp = uv * levelSize;
    float2 tc = floor(sp - 0.5) + 0.5;
    float2 f = sp - tc;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = f2 - 0.5 * (f3 + f);
    float2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    float2 w3 = 0.5 * (f3 - f2);
    float2 w2 = 1.0 - w0 - w1 - w3;
    float2 w12 = w1 + w2;
    float2 tc0 = (tc - 1.0) / levelSize;
    float2 tc3 = (tc + 2.0) / levelSize;
    float2 tc12 = (tc + w2 / w12) / levelSize;
    float4 r = tex.sample(s, float2(tc12.x, tc0.y), level(lod)) * (w12.x * w0.y)
             + tex.sample(s, float2(tc0.x, tc12.y), level(lod)) * (w0.x * w12.y)
             + tex.sample(s, float2(tc12.x, tc12.y), level(lod)) * (w12.x * w12.y)
             + tex.sample(s, float2(tc3.x, tc12.y), level(lod)) * (w3.x * w12.y)
             + tex.sample(s, float2(tc12.x, tc3.y), level(lod)) * (w12.x * w3.y);
    float sum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return r / sum;
}

/// Source sample at source-px position p. Minification blends bicubic between two mip levels.
static inline float4 sampleSource(texture2d<float> tex, sampler s, float2 p, float M) {
    float2 sz = float2(tex.get_width(), tex.get_height());
    float2 uv = p / sz;
    float maxL = float(tex.get_num_mip_levels() - 1);
    float lod = clamp(log2(max(1.0 / max(M, 1e-4), 1.0)), 0.0, maxL);
    float l0 = floor(lod), fr = lod - l0;
    float4 a = catmull(tex, s, uv, sz / exp2(l0), l0);
    if (fr < 1e-3 || l0 + 1.0 > maxL) return a;
    return mix(a, catmull(tex, s, uv, sz / exp2(l0 + 1.0), l0 + 1.0), fr);
}

static inline float4 sampleUp(texture2d<float> up, sampler s, constant UpBind& U, float2 p) {
    float2 q = (p - U.region.xy) * U.factor;
    q = clamp(q, float2(0.5), U.region.zw * U.factor - 0.5);
    return catmull(up, s, q / U.texSize, U.texSize, 0.0);
}

static inline float3 sampleContent(texture2d<float> src, texture2d<float> up, sampler s, constant UpBind& U, float2 p, float M) {
    float3 base = sampleSource(src, s, p, M).rgb;
    if (U.blend <= 0.0) return base;
    return mix(base, sampleUp(up, s, U, p).rgb, U.blend);
}

kernel void fx_content(texture2d<float, access::read> backdrop [[texture(0)]],
                       texture2d<float, access::write> canvas [[texture(1)]],
                       texture2d<float> source [[texture(2)]],
                       texture2d<float> upTex [[texture(3)]],
                       constant ContentParams& P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.canvasSize.x || int(gid.y) >= P.canvasSize.y) return;
    float4 base = backdrop.read(gid);
    float2 q = float2(gid) + 0.5;
    float2 ctr = P.contentRect.xy + 0.5 * P.contentRect.zw;
    float cov = saturate(0.5 - sdRoundBox(q - ctr, 0.5 * P.contentRect.zw, P.radii));
    if (cov <= 0.0) { canvas.write(base, gid); return; }
    float2 p = P.camCenter + (q - ctr) / P.magnification;
    constexpr sampler s(filter::linear, mip_filter::linear, address::clamp_to_edge);
    float3 col = sampleContent(source, upTex, s, P.up, p, P.magnification);
    canvas.write(float4(mix(base.rgb, col, cov), mix(base.a, 1.0, cov)), gid);
}
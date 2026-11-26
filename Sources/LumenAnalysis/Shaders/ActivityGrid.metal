#include <metal_stdlib>
using namespace metal;

constant uint kGridW = 48;
constant uint kGridH = 27;
constant uint kLumaW = 192;
constant uint kLumaH = 108;

kernel void lumen_luma_down(texture2d<float, access::sample> src [[texture(0)]],
                            texture2d<float, access::write>  dst [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= kLumaW || gid.y >= kLumaH) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 step = 1.0 / float2(kLumaW, kLumaH);
    const float2 base = float2(gid) * step;
    float3 acc = float3(0.0);
    for (uint j = 0; j < 8; ++j) {
        for (uint i = 0; i < 8; ++i) {
            float2 uv = base + step * (float2(i, j) + 0.5) / 8.0;
            acc += src.sample(s, uv).rgb;
        }
    }
    dst.write(float4(acc / 64.0, 1.0), gid);
}

kernel void lumen_activity_diff(texture2d<float, access::read> cur  [[texture(0)]],
                                texture2d<float, access::read> lagA [[texture(1)]],
                                texture2d<float, access::read> lagB [[texture(2)]],
                                device uchar* out [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= kGridW || gid.y >= kGridH) return;
    float eA = 0.0, eB = 0.0;
    for (uint j = 0; j < 4; ++j) {
        for (uint i = 0; i < 4; ++i) {
            uint2 p = gid * 4 + uint2(i, j);
            const float3 c = cur.read(p).rgb;
            const float3 a = fabs(c - lagA.read(p).rgb);
            const float3 b = fabs(c - lagB.read(p).rgb);
            // Luma-equivalent changes still register; isoluminant color
            // changes no longer disappear before attention classification.
            eA = max(eA, max(a.r, max(a.g, a.b)));
            eB = max(eB, max(b.r, max(b.g, b.b)));
        }
    }
    float e = max(eA, eB * 1.5);
    out[gid.y * kGridW + gid.x] = uchar(clamp(e * 255.0 * 4.0, 0.0, 255.0));
}

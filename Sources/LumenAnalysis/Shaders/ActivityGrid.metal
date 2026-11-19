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
    float acc = 0.0;
    for (uint j = 0; j < 8; ++j) {
        for (uint i = 0; i < 8; ++i) {
            float2 uv = base + step * (float2(i, j) + 0.5) / 8.0;
            acc += dot(src.sample(s, uv).rgb, float3(0.2126, 0.7152, 0.0722));
        }
    }
    dst.write(float4(acc / 64.0), gid);
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
            float c = cur.read(p).r;
            eA = max(eA, fabs(c - lagA.read(p).r));
            eB = max(eB, fabs(c - lagB.read(p).r));
        }
    }
    float e = max(eA, eB * 1.5);
    out[gid.y * kGridW + gid.x] = uchar(clamp(e * 255.0 * 4.0, 0.0, 255.0));
}

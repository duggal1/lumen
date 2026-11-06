#include <metal_stdlib>
using namespace metal;

constant float3 kLuma = float3(0.2126, 0.7152, 0.0722);

static inline float lanczos2(float r) {
    if (r < 1e-4) return 1.0;
    if (r >= 2.0) return 0.0;
    float x = M_PI_F * r;
    return (sin(x) / x) * (sin(0.5 * x) / (0.5 * x));
}

struct DirectedParams { int2 srcOrigin; int2 srcSize; int2 outSize; float scale; float sharp; };

/// Edge-directed upsample. A structure tensor over the 4x4 patch gives the edge direction; a Lanczos2 kernel is squeezed across
/// the edge and stretched along it, then the result is clamped to the inner 2x2 range (no ringing).
kernel void up_directed(texture2d<float, access::read> src [[texture(0)]],
                        texture2d<float, access::write> dst [[texture(1)]],
                        constant DirectedParams& P [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.outSize.x || int(gid.y) >= P.outSize.y) return;
    float2 u = (float2(gid) + 0.5) / P.scale - 0.5;
    int2 i0 = int2(floor(u));
    float2 f = u - float2(i0);

    float3 c[4][4]; float l[4][4];
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            int2 q = clamp(i0 + int2(i - 1, j - 1), int2(0), P.srcSize - 1) + P.srcOrigin;
            c[j][i] = src.read(uint2(q)).rgb;
            l[j][i] = dot(c[j][i], kLuma);
        }
    }
    float3 J = float3(0.0);
    for (int j = 1; j <= 2; ++j) {
        for (int i = 1; i <= 2; ++i) {
            float gx = 0.5 * (l[j][i + 1] - l[j][i - 1]);
            float gy = 0.5 * (l[j + 1][i] - l[j - 1][i]);
            float w = ((i == 2) ? f.x : 1.0 - f.x) * ((j == 2) ? f.y : 1.0 - f.y);
            J += w * float3(gx * gx, gx * gy, gy * gy);
        }
    }
    float ang = 0.5 * atan2(2.0 * J.y, J.x - J.z);
    float2 n = float2(cos(ang), sin(ang));
    float2 t = float2(-n.y, n.x);
    float tr = J.x + J.z;
    float mag = sqrt(max(tr, 0.0));
    float coh = sqrt(max((J.x - J.z) * (J.x - J.z) + 4.0 * J.y * J.y, 0.0)) / (tr + 1e-6);
    float anis = coh * smoothstep(0.02, 0.12, mag);
    float sAcross = 1.0 + anis * P.sharp * 0.7;
    float sAlong = 1.0 - anis * 0.45;

    float3 acc = float3(0.0); float wsum = 0.0;
    for (int j = 0; j < 4; ++j) {
        for (int i = 0; i < 4; ++i) {
            float2 d = float2(float(i - 1) - f.x, float(j - 1) - f.y);
            float r = length(float2(dot(d, n) * sAcross, dot(d, t) * sAlong));
            float w = lanczos2(r);
            acc += w * c[j][i]; wsum += w;
        }
    }
    float3 res = acc / (abs(wsum) > 1e-4 ? wsum : 1.0);
    float3 mn = min(min(c[1][1], c[1][2]), min(c[2][1], c[2][2]));
    float3 mx = max(max(c[1][1], c[1][2]), max(c[2][1], c[2][2]));
    dst.write(float4(clamp(res, mn, mx), 1.0), gid);
}

struct ShockParams { int2 size; float strength; float edgeLo; float edgeHi; float k; };

/// Shock filter: pushes each pixel on an edge toward the brightest/darkest *neighbour pixel* (never a new colour), steepening
/// edges without overshoot. Flat areas and noise are gated out by the gradient threshold.
kernel void up_shock(texture2d<float, access::read> src [[texture(0)]],
                     texture2d<float, access::write> dst [[texture(1)]],
                     constant ShockParams& P [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.size.x || int(gid.y) >= P.size.y) return;
    float3 c[3][3]; float l[3][3];
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            int2 q = clamp(int2(gid) + int2(i - 1, j - 1), int2(0), P.size - 1);
            c[j][i] = src.read(uint2(q)).rgb;
            l[j][i] = dot(c[j][i], kLuma);
        }
    }
    float gx = 0.5 * (l[1][2] - l[1][0]);
    float gy = 0.5 * (l[2][1] - l[0][1]);
    float mag = sqrt(gx * gx + gy * gy);
    float Ixx = l[1][2] - 2.0 * l[1][1] + l[1][0];
    float Iyy = l[2][1] - 2.0 * l[1][1] + l[0][1];
    float Ixy = 0.25 * (l[2][2] - l[2][0] - l[0][2] + l[0][0]);
    float Inn = (gx * gx * Ixx + 2.0 * gx * gy * Ixy + gy * gy * Iyy) / (mag * mag + 1e-8);
    float s = -tanh(Inn * P.k);
    float w = P.strength * smoothstep(P.edgeLo, P.edgeHi, mag) * abs(s);

    float3 hi = c[1][1], lo = c[1][1]; float lh = l[1][1], ll = l[1][1];
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            if (l[j][i] > lh) { lh = l[j][i]; hi = c[j][i]; }
            if (l[j][i] < ll) { ll = l[j][i]; lo = c[j][i]; }
        }
    }
    float3 target = s > 0.0 ? hi : lo;
    dst.write(float4(mix(c[1][1], target, w), 1.0), gid);
}

struct SharpParams { int2 size; float amount; float pad; };

/// Contrast-adaptive sharpen, backed off in high-contrast areas and clamped to the local 3x3 range (no halos).
kernel void up_sharpen(texture2d<float, access::read> src [[texture(0)]],
                       texture2d<float, access::write> dst [[texture(1)]],
                       constant SharpParams& P [[buffer(0)]],
                       uint2 gid [[thread_position_in_grid]])
{
    if (int(gid.x) >= P.size.x || int(gid.y) >= P.size.y) return;
    float3 c[3][3];
    float3 mn = float3(1.0), mx = float3(0.0);
    for (int j = 0; j < 3; ++j) {
        for (int i = 0; i < 3; ++i) {
            int2 q = clamp(int2(gid) + int2(i - 1, j - 1), int2(0), P.size - 1);
            c[j][i] = src.read(uint2(q)).rgb;
            mn = min(mn, c[j][i]); mx = max(mx, c[j][i]);
        }
    }
    float3 blur = (c[0][1] + c[2][1] + c[1][0] + c[1][2] + 4.0 * c[1][1]) * 0.125;
    float range = max(max(mx.r - mn.r, mx.g - mn.g), mx.b - mn.b);
    float adapt = 1.0 - smoothstep(0.25, 0.7, range);
    float3 o = c[1][1] + P.amount * adapt * 2.0 * (c[1][1] - blur);
    dst.write(float4(clamp(o, mn, mx), 1.0), gid);
}
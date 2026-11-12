#include <metal_stdlib>
using namespace metal;

constexpr sampler linClamp(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::nearest);
constexpr sampler linMip(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
constant float2 kMesh[6] = { float2(.15, .20), float2(.85, .15), float2(.5, .5), float2(.2, .85), float2(.8, .8), float2(.5, .02) };

struct QuadU { float4 rect; float2 canvas; };
struct VO { float4 pos [[position]]; float2 px; float2 q; };

vertex VO quadVS(uint vid [[vertex_id]], constant QuadU &u [[buffer(0)]]) {
    float2 c = float2(vid & 1, vid >> 1);
    float2 px = u.rect.xy + c * u.rect.zw;
    VO o;
    o.pos = float4(px.x / u.canvas.x * 2.0 - 1.0, 1.0 - px.y / u.canvas.y * 2.0, 0.0, 1.0);
    o.px = px; o.q = c;
    return o;
}

// Continuous-corner rounded rect: superellipse (n=4) in the corner region, straight edges elsewhere.
static float sdSquircle(float2 p, float2 h, float r) {
    r = max(min(r, min(h.x, h.y)), 0.5);
    float2 q = abs(p) - (h - r);
    if (q.x > 0.0 && q.y > 0.0) {
        float k = pow(pow(q.x / r, 4.0) + pow(q.y / r, 4.0), 0.25);
        return (k - 1.0) * r;
    }
    return max(q.x, q.y) - r;
}
static float rectMask(float2 px, float4 rect, float r) {
    float2 h = rect.zw * 0.5;
    float d = sdSquircle(px - (rect.xy + h), h, r);
    return clamp(0.5 - d / max(fwidth(d), 1e-3), 0.0, 1.0);
}

// ---- Backdrop (cached): dither / wallpaper / gradient / mesh / solid + two-layer shadow
struct BackdropU { float4 content; float2 canvas; float angle; int count; int kind;
                   float radius; float shadow; float scale; float cell; float density; int hasWall; float time; float4 pointer;
                   float wallBlur; float imgAlpha; float imgContrast; float imgBright; };

float3 blurredWall(texture2d<float> tex, float2 uv, float2 texSize, float radiusPx) {
    if (radiusPx <= 0.5) return tex.sample(linClamp, uv).rgb;
    float sigma = radiusPx * 0.5, step = max(sigma * 0.5, 0.5);
    float lod = clamp(log2(step), 0.0, float(tex.get_num_mip_levels() - 1));
    float3 sum = float3(0.0); float ws = 0.0;
    for (int y = -6; y <= 6; ++y) for (int x = -6; x <= 6; ++x) {
        float2 offset = float2(x, y) * step;
        float weight = exp(-dot(offset, offset) / (2.0 * sigma * sigma));
        sum += tex.sample(linMip, clamp(uv + offset / texSize, 0.0, 1.0), level(lod)).rgb * weight;
        ws += weight;
    }
    return sum / ws;
}

constant float kBayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

static float bayer2(float2 a) { a = floor(a); return fract(a.x / 2.0 + a.y * a.y * 0.75); }
static float bayer4(float2 a) { return bayer2(0.5 * a) * 0.25 + bayer2(a); }
static float bayer8(float2 a) { return bayer4(0.5 * a) * 0.25 + bayer2(a); }
static float fieldHash(int x, int y, int z) {
    uint h = uint(x) * 0x27d4eb2du ^ uint(y) * 0x165667b1u ^ uint(z) * 0x1b873593u;
    h = (h ^ (h >> 15)) * 0x85ebca6bu;
    h = (h ^ (h >> 13)) * 0xc2b2ae35u;
    return float(h ^ (h >> 16)) * (1.0 / 4294967296.0);
}
static float fieldNoise(float3 p) {
    int3 i = int3(floor(p));
    float3 f = fract(p); f = f * f * (3.0 - 2.0 * f);
    float a = mix(mix(fieldHash(i.x, i.y, i.z), fieldHash(i.x + 1, i.y, i.z), f.x),
                  mix(fieldHash(i.x, i.y + 1, i.z), fieldHash(i.x + 1, i.y + 1, i.z), f.x), f.y);
    float b = mix(mix(fieldHash(i.x, i.y, i.z + 1), fieldHash(i.x + 1, i.y, i.z + 1), f.x),
                  mix(fieldHash(i.x, i.y + 1, i.z + 1), fieldHash(i.x + 1, i.y + 1, i.z + 1), f.x), f.y);
    return mix(a, b, f.z);
}

fragment float4 backdropFS(VO in [[stage_in]], constant BackdropU &u [[buffer(0)]], constant float4 *cols [[buffer(1)]],
                           texture2d<float> wall [[texture(0)]]) {
    float2 uv = in.px / u.canvas;
    float3 c = cols[0].rgb;
    if (u.kind == 6) {
        float cell = max(1.0, u.cell);
        float2 grid = floor(in.px / cell);
        float2 p = (grid * cell) / u.canvas;
        p.x *= u.canvas.x / u.canvas.y;
        if (u.pointer.z > 0.001) {
            float2 dm = p - float2(u.pointer.x * u.canvas.x / u.canvas.y, u.pointer.y);
            p += dm * exp(-dot(dm, dm) * 10.0) * 0.22 * u.pointer.z;
        }
        float v = u.density + 0.20 * sin(dot(p, normalize(float2(0.55, 1.0))) * 5.2 - u.time * 0.11)
                            + 0.12 * sin(dot(p, normalize(float2(1.0, 0.28))) * 8.4 + u.time * 0.07);
        c = v > bayer8(grid) ? cols[1].rgb : cols[0].rgb;
    } else if (u.kind == 7) {
        float pitch = max(3.0, u.cell);
        float2 grid = floor(in.px / pitch);
        float step = pitch / u.canvas.y;
        float nx = grid.x * step * 1.4, ny = grid.y * step * 2.6;
        // Coherent field: Bayer-ordered density with a slow diagonal wave.
        // One continuous pattern, no hash gaps or clipped dashes.
        float wave = 0.5 + 0.5 * sin(dot(float2(nx, ny), normalize(float2(0.55, 1.0))) * 6.0 - u.time * 0.05);
        float density = clamp(wave * u.density * 1.6, 0.0, 1.0);
        c = density > bayer8(grid) ? cols[1].rgb : cols[0].rgb;
    } else if (u.kind == 3) {
        // Two flat tones ordered-dithered under a slow diagonal wave. Display-rate phase; export always sends 0.
        float cell = max(2.0, u.cell);
        float2 g = floor(in.px / cell);
        int ix = int(g.x) & 3, iy = int(g.y) & 3;
        float t = (kBayer[iy * 4 + ix] + 0.5) / 16.0;
        float2 d = float2(cos(u.angle), sin(u.angle));
        float s = dot(uv - 0.5, d) / max(abs(d.x) + abs(d.y), 1e-3) + 0.5;
        float wave = 0.5 + 0.5 * sin((s * 3.0 - u.time * 0.35) * 6.2831853);
        float field = smoothstep(0.08, 0.92, wave);
        float ink = field * clamp(u.density * 1.8, 0.0, 1.0);
        c = ink > t ? cols[1].rgb : cols[0].rgb;
    } else if (u.kind == 5) {
        // Canvas: a flat two-tone pixel weave. Static, so it reads as paper rather than motion.
        float cell = max(4.0, u.cell);
        float2 g = floor(in.px / cell);
        float alt = fmod(g.x + g.y, 2.0);
        c = mix(cols[0].rgb, cols[1].rgb, alt * 0.14);
    } else if (u.kind == 4 && u.hasWall == 1) {
        // macOS wallpaper, filled like cover.
        float2 ts = float2(wall.get_width(), wall.get_height());
        float s = max(u.canvas.x / ts.x, u.canvas.y / ts.y);
        float2 off = (u.canvas - ts * s) * 0.5;
        c = blurredWall(wall, (in.px - off) / (ts * s), ts * s, u.wallBlur);
    } else if (u.kind == 8 && u.hasWall == 1) {
        // User photo, filled like cover (no letterboxing).
        // wallBlur is a radius in canvas pixels (0 sharp .. 60 soft);
        // imgAlpha 0..1, imgContrast 0..2 around 0.18 grey, imgBright 0..2 additive.
        float2 ts = float2(wall.get_width(), wall.get_height());
        float s = max(u.canvas.x / ts.x, u.canvas.y / ts.y);
        float2 off = (u.canvas - ts * s) * 0.5;
        c = blurredWall(wall, (in.px - off) / (ts * s), ts * s, u.wallBlur);
        c = clamp((c - 0.18) * u.imgContrast + 0.18 + (u.imgBright - 1.0) * 0.25, 0.0, 1.0);
        c *= u.imgAlpha;
    } else if (u.kind == 0 && u.count > 1) {
        float2 d = float2(cos(u.angle), sin(u.angle));
        float t = dot(uv - 0.5, d) / (abs(d.x) + abs(d.y)) + 0.5;
        float f = clamp(t, 0.0, 1.0) * float(u.count - 1);
        int i = min(int(f), u.count - 2);
        c = mix(cols[i].rgb, cols[i + 1].rgb, f - float(i));
    } else if (u.kind == 1) {
        float3 acc = float3(0.0); float ws = 0.0;
        for (int i = 0; i < 6; i++) {
            float2 dv = (uv - kMesh[i]) * float2(u.canvas.x / u.canvas.y, 1.0);
            float w = exp(-dot(dv, dv) * 7.0);
            acc += cols[i % max(u.count, 1)].rgb * w; ws += w;
        }
        c = acc / max(ws, 1e-4);
    }
    float2 h = u.content.zw * 0.5, ctr = u.content.xy + h;
    float s = u.scale;
    float d1 = sdSquircle(in.px - (ctr + float2(0.0, 2.0 * s)), h, u.radius);
    float d2 = sdSquircle(in.px - (ctr + float2(0.0, 22.0 * s)), h, u.radius);
    float a1 = 0.30 * (1.0 - smoothstep(-8.0 * s, 8.0 * s, d1));
    float a2 = 0.45 * (1.0 - smoothstep(-40.0 * s, 40.0 * s, d2));
    float a = 1.0 - (1.0 - a1 * u.shadow) * (1.0 - a2 * u.shadow);
    return float4(c * (1.0 - a), 1.0);
}

// ---- High-quality resampling: Catmull-Rom (5 taps) at one mip level.
// SMOOTHNESS: the corner taps of the 4x4 kernel carry <2% of the energy and
// renormalizing after dropping them is visually indistinguishable, so this
// halves the texture fetches in the preview's hottest shader.
static float3 catmull5(texture2d<float> t, float2 uv, uint lv) {
    float2 sz = float2(t.get_width(lv), t.get_height(lv));
    float2 sp = uv * sz;
    float2 tc = floor(sp - 0.5) + 0.5;
    float2 f = sp - tc;
    float2 f2 = f * f, f3 = f2 * f;
    float2 w0 = f2 - 0.5 * (f3 + f);
    float2 w1 = 1.5 * f3 - 2.5 * f2 + 1.0;
    float2 w3 = 0.5 * (f3 - f2);
    float2 w2 = 1.0 - w0 - w1 - w3;
    float2 w12 = w1 + w2;
    float2 p0 = (tc - 1.0) / sz, p3 = (tc + 2.0) / sz, p12 = (tc + w2 / w12) / sz;
    float L = float(lv);
    float3 r = t.sample(linClamp, float2(p12.x, p0.y),  level(L)).rgb * (w12.x * w0.y)
             + t.sample(linClamp, float2(p0.x,  p12.y), level(L)).rgb * (w0.x  * w12.y)
             + t.sample(linClamp, float2(p12.x, p12.y), level(L)).rgb * (w12.x * w12.y)
             + t.sample(linClamp, float2(p3.x,  p12.y), level(L)).rgb * (w3.x  * w12.y)
             + t.sample(linClamp, float2(p12.x, p3.y),  level(L)).rgb * (w12.x * w3.y);
    float sum = w12.x * w0.y + w0.x * w12.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
    return r / max(sum, 1e-4);
}
static float3 sampleMip(texture2d<float> t, float2 uv, float minif) {
    float maxL = float(t.get_num_mip_levels() - 1);
    float L = clamp(log2(max(minif, 1.0)), 0.0, maxL);
    float l0 = floor(L), f = L - l0;
    float3 a = catmull5(t, uv, uint(l0));
    if (f > 0.001 && l0 + 1.0 <= maxL) a = mix(a, catmull5(t, uv, uint(l0) + 1u), f);
    return max(a, float3(0.0));
}

// ---- Content (camera-transformed source inside the rounded mask)
// `tilt` is (yaw, pitch) in degrees. A small perspective divide is enough to
// sell depth without ever sampling outside the source: the warp is clamped so
// the visible rectangle can never exceed the original frame.
struct ContentU { float4 content; float2 src; float2 cam; float scale; float radius; float border; float p; float2 tilt; float4 radii; };

// Standard rounded box with one radius per corner (tl, tr, br, bl). Only used
// when the four corners actually differ; the squircle path stays for uniform
// corners so existing looks do not change.
static float sdCorners(float2 p, float2 h, float4 r) {
    float rr = (p.x < 0.0) ? ((p.y < 0.0) ? r.x : r.w) : ((p.y < 0.0) ? r.y : r.z);
    rr = clamp(rr, 0.5, min(h.x, h.y));
    float2 q = abs(p) - h + rr;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - rr;
}

fragment float4 contentFS(VO in [[stage_in]], constant ContentU &u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 h = u.content.zw * 0.5;
    float4 R = u.radii;
    float d = (R.x == R.y && R.y == R.z && R.z == R.w)
        ? sdSquircle(in.px - (u.content.xy + h), h, R.x)
        : sdCorners(in.px - (u.content.xy + h), h, R);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float2 view = u.src / u.scale;
    float2 n = (in.px - u.content.xy) / u.content.zw - 0.5;
    if (abs(u.tilt.x) + abs(u.tilt.y) > 0.001) {
        float ky = tan(clamp(u.tilt.x, -18.0, 18.0) * 0.01745329252);
        float kx = tan(clamp(u.tilt.y, -18.0, 18.0) * 0.01745329252);
        n = clamp(float2(n.x * (1.0 + ky * n.y * 2.0), n.y * (1.0 + kx * n.x * 2.0)),
                  float2(-0.5), float2(0.5));
    }
    float2 sp = u.cam + n * view;
    float3 rgb = sampleMip(src, sp / u.src, view.x / u.content.z);
    if (u.border > 0.5) rgb = mix(rgb, float3(1.0), 0.08 * clamp(0.5 + (d + 1.0) / w, 0.0, 1.0));
    return float4(rgb * a, a);
}

// ---- Glass loupe: a circular window that re-samples the source at a higher
// magnification than the camera. Coverage is the same source pixels the user
// sees, so a loupe can never reveal content that the camera pass hides.
struct LoupeU {
    float4 glass;    // centre x,y (canvas px), radius, border width
    float4 source;   // target source x,y, source width,height
    float2 zoom;     // camera scale, loupe magnification
    float opacity;
    float round;     // 1 = circle, 0 = rounded rect
    float radius;    // corner radius for the rect case
};
fragment float4 loupeFS(VO in [[stage_in]], constant LoupeU &u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 p = in.px, c = u.glass.xy;
    float R = max(u.glass.z, 1.0);
    float d = u.round > 0.5 ? length(p - c) - R
                            : sdSquircle(p - c, float2(R), u.radius);
    float aa = max(fwidth(d), 1e-3);
    float inside = clamp(0.5 - d / aa, 0.0, 1.0);
    // Soft drop shadow just outside the rim.
    float shadowA = exp(-pow(max(d, 0.0) / (R * 0.25 + 1.0), 1.5)) * 0.4 * u.opacity;
    if (inside <= 0.001 && shadowA < 0.004) return float4(0.0);
    float2 n = (p - c) / (2.0 * R);
    float2 view = u.source.zw / max(u.zoom.x * u.zoom.y, 0.01);
    float2 sp = u.source.xy + clamp(n, float2(-0.5), float2(0.5)) * view;
    float3 rgb = src.sample(linClamp, clamp(sp / u.source.zw, 0.0, 1.0)).rgb;
    // Rim: a crisp light edge reads as glass against any background.
    float ringW = max(u.glass.w, 1.0);
    float rim = smoothstep(R - ringW * 1.6, R - ringW * 0.4, length(p - c));
    float3 edge = mix(rgb, float3(1.0), rim * 0.6);
    float alpha = inside * u.opacity;
    return float4(edge * alpha, alpha + shadowA * (1.0 - inside));
}

struct SourceMask { float4 rect; float4 block; };

static float sdBox(float2 p, float2 h, float radius) {
    float2 q = abs(p) - h + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}
static float4 readPx(texture2d<float, access::read> texture, float2 p) {
    return texture.read(uint2(clamp(p, float2(0.0), float2(texture.get_width() - 1, texture.get_height() - 1))));
}
static float4 cellMean(texture2d<float, access::read> texture, float4 rect, float cell, float2 index) {
    float2 lo = rect.xy + 0.5, hi = max(lo, rect.xy + rect.zw - 0.5), centre = rect.xy + (index + 0.5) * cell;
    return (readPx(texture, clamp(centre + float2(-0.25, -0.25) * cell, lo, hi))
          + readPx(texture, clamp(centre + float2(0.25, -0.25) * cell, lo, hi))
          + readPx(texture, clamp(centre + float2(-0.25, 0.25) * cell, lo, hi))
          + readPx(texture, clamp(centre + float2(0.25, 0.25) * cell, lo, hi))) * 0.25;
}

kernel void pixelateMask(texture2d<float, access::read> source [[texture(0)]],
                         texture2d<float, access::write> target [[texture(1)]],
                         constant SourceMask *masks [[buffer(0)]],
                         constant uint &count [[buffer(1)]],
                         uint2 gid [[thread_position_in_grid]]) {
    uint2 size(source.get_width(), source.get_height());
    if (any(gid >= size)) return;
    float2 p = float2(gid) + 0.5;
    float4 color = source.read(gid);
    for (uint index = 0; index < count; ++index) {
        float4 rect = masks[index].rect;
        float2 halfSize = rect.zw * 0.5, centre = rect.xy + halfSize;
        float radius = min(masks[index].block.z, min(halfSize.x, halfSize.y));
        float distance = sdBox(p - centre, halfSize, radius);
        float coverage = saturate(0.5 - distance);
        if (coverage <= 0.0) continue;
        float cell = max(masks[index].block.x, 4.0);
        float4 fill;
        if (masks[index].block.y > 1.5) {
            float2 grid = (p - rect.xy) / cell - 0.5, i0 = floor(grid), fraction = grid - i0;
            fill = mix(mix(cellMean(source, rect, cell, i0), cellMean(source, rect, cell, i0 + float2(1, 0)), fraction.x),
                       mix(cellMean(source, rect, cell, i0 + float2(0, 1)), cellMean(source, rect, cell, i0 + float2(1, 1)), fraction.x), fraction.y);
        } else if (masks[index].block.y > 0.5) {
            float2 offset = float2(8.0);
            float4 background = (readPx(source, rect.xy - offset)
                + readPx(source, float2(rect.x + rect.z + offset.x, rect.y - offset.y))
                + readPx(source, float2(rect.x - offset.x, rect.y + rect.w + offset.y))
                + readPx(source, rect.xy + rect.zw + offset)) * 0.25;
            float rim = 1.0 - smoothstep(0.0, 1.5, abs(distance + 0.75));
            fill = float4(background.rgb * (0.88 - 0.10 * rim), 1.0);
        } else {
            fill = cellMean(source, rect, cell, floor((p - rect.xy) / cell));
        }
        color = mix(color, fill, coverage);
    }
    target.write(color, gid);
}

// ---- Cursor sprite (premultiplied atlas, mip-mapped)
struct CursorU { float4 content; float radius; float opacity; uint layer; float p; };
fragment float4 cursorFS(VO in [[stage_in]], constant CursorU &u [[buffer(0)]], texture2d_array<float> atlas [[texture(0)]]) {
    float4 c = atlas.sample(linMip, in.q, u.layer);
    return c * (u.opacity * rectMask(in.px, u.content, u.radius));
}

// ---- Click ripple: expanding front refracts the source video under it,
// no flat fill. Front radius eases out; amplitude decays (critically damped,
// no overshoot). Center is the exact corrected click position from Part 1.
struct RingU { float4 content; float4 color; float2 center; float radius; float progress; float cr; int mode;
               float2 cam; float scale; float2 srcSize; };
fragment float4 ringFS(VO in [[stage_in]], constant RingU &u [[buffer(0)]],
                       texture2d<float> src [[texture(0)]]) {
    float p = clamp(u.progress, 0.0, 1.0), e = 1.0 - pow(1.0 - p, 3.0);
    float r = mix(0.25, 1.0, e) * u.radius * 0.9, wd = mix(0.16, 0.025, e) * u.radius;
    float2 delta = in.px - u.center;
    float distance = length(delta);
    float dd = abs(distance - r) - wd * 0.5;
    float ring = clamp(0.5 - dd / max(fwidth(dd), 1e-3), 0.0, 1.0);
    float ink = ring;
    if (u.mode == 1) { // Pulse: a filled, expanding focus disc
        ink = 0.45 * (1.0 - smoothstep(r - 2.0, r + 2.0, distance));
    } else if (u.mode == 2) { // Burst: short radial rays at the clicked pixel
        float rays = pow(abs(cos(atan2(delta.y, delta.x) * 6.0)), 18.0);
        float band = 1.0 - smoothstep(wd * 0.5, wd * 2.0, abs(distance - r));
        ink = max(ring * 0.3, rays * band);
    } else if (u.mode == 3) { // Glass: translucent bloom + rim
        float bloom = clamp(1.0 - pow(distance / max(r, 1.0), 2.2), 0.0, 1.0);
        float rim = ring * 0.5;
        float glow = exp(-distance * distance / max(r * r * 0.4, 1.0));
        ink = clamp(bloom * 0.35 + rim * 0.65 + glow * 0.25, 0.0, 1.0);
        float a = ink * pow(1.0 - p, 1.2) * u.color.a * rectMask(in.px, u.content, u.cr);
        return float4(mix(float3(1.0), u.color.rgb, 0.25) * a + float3(0.15) * glow * pow(1.0 - p, 2.0) * u.color.a, a);
    } else if (u.mode == 0) {
        // Liquid-glass ripple. A travelling wave refracts the already-composited
        // frame (masks included — never the raw source) with a soft specular
        // crest. No hard ring, no flat fill, no full-disc tint.
        float x = 6.5 * p;
        float e = 1.0 - exp(-x) * (1.0 + x);                 // 0 → ~0.99, no overshoot
        float R = u.radius * (0.18 + 0.82 * e);
        float fade = pow(1.0 - p, 1.25);
        float2 d = in.px - u.center;
        float r = max(length(d), 1e-3);
        float2 dir = d / r;
        // The band widens with the front so the wave stays soft as it grows.
        float bandW = max(R * 0.34, 6.0);
        float xr = (r - R) / bandW;
        float band = exp(-xr * xr);
        float wave = sin(5.2 * (r - R) / bandW);
        float2 q = in.px - dir * (band * wave * 16.0 * fade);
        float3 base = src.sample(linClamp, clamp(q / u.srcSize, 0.0, 1.0), level(0.0)).rgb;
        float crest = exp(-pow((r - R) / (bandW * 0.55), 2.0));
        float shade = exp(-pow((r - R - bandW * 0.75) / (bandW * 0.5), 2.0));
        // A lens edge reads as glass only if it has both a highlight and a
        // slight shade just behind it; a single bright ring reads as paint.
        // No interior fill: the wave itself is the effect.
        float3 col = base + float3(0.16) * (crest * 0.8) - float3(0.05) * shade;
        col = mix(col, u.color.rgb, clamp(u.color.a, 0.0, 1.0) * band * 0.5);
        // Where the wave displaces pixels, this pass must own them outright;
        // where it does not, alpha falls to zero and the scene shows through.
        float a = clamp(band * 2.0, 0.0, 1.0) * fade;
        a *= rectMask(in.px, u.content, u.cr);
        return float4(col * a, a);
    }
    float a = ink * pow(1.0 - p, 1.5) * u.color.a * rectMask(in.px, u.content, u.cr);
    return float4(u.color.rgb * a, a);
}

// ---- Webcam bubble (shadow + mask + border in one quad)
struct WebU {
    float4 crop; float4 bubble;
    float radius; float shape; float mirror; float border;
    float shadow; float bw; float minif; float margin;
    float opacity; float maskMode; float matteMix; float detail;
    float4 canvasColor;
};
fragment float4 webFS(VO in [[stage_in]], constant WebU &u [[buffer(0)]],
                       texture2d<float> tex [[texture(0)]],
                       texture2d<float> maskA [[texture(1)]],
                       texture2d<float> maskB [[texture(2)]],
                       texture2d<float> wallpaper [[texture(3)]]) {
    float2 h = u.bubble.zw * 0.5, p = in.px - (u.bubble.xy + h);
    float d = u.shape < 0.5 ? length(p) - min(h.x, h.y) : sdSquircle(p, h, u.radius);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    float2 q = (p + h) / u.bubble.zw;
    float2 uvw = u.crop.xy + float2(u.mirror > 0.5 ? 1.0 - q.x : q.x, q.y) * u.crop.zw;

    // Catmull-Rom preserves edges when displaying a lower-resolution webcam
    // in a 4K composition. The constrained high-pass improves acutance, but
    // does not pretend to recover detail absent from the original recording.
    float3 rgb = sampleMip(tex, uvw, u.minif);
    if (u.detail > 0.001) {
        float2 tx = 1.0 / float2(tex.get_width(), tex.get_height());
        float3 near = (tex.sample(linClamp, uvw - float2(tx.x, 0)).rgb
                     + tex.sample(linClamp, uvw + float2(tx.x, 0)).rgb
                     + tex.sample(linClamp, uvw - float2(0, tx.y)).rgb
                     + tex.sample(linClamp, uvw + float2(0, tx.y)).rgb) * 0.25;
        rgb = clamp(rgb + clamp(rgb - near, float3(-0.06), float3(0.06)) * (u.detail * 0.75), 0.0, 1.0);
    }

    if (u.maskMode > 0.5) {
        // Vision mattes are timestamped in source time. Interpolating adjacent
        // mattes removes the hard 30Hz edge jump on 60fps exports.
        float m0 = maskA.sample(linClamp, uvw).r;
        float m1 = maskB.sample(linClamp, uvw).r;
        float person = smoothstep(0.055, 0.94, mix(m0, m1, u.matteMix));
        if (u.maskMode < 1.5) {
            float alpha = a * person * u.opacity;
            return float4(rgb * alpha, alpha);
        }
        float3 backdrop = u.maskMode < 2.5 ? wallpaper.sample(linClamp, q).rgb : u.canvasColor.rgb;
        float3 combined = mix(backdrop, rgb, person);
        float alpha = a * u.opacity;
        return float4(combined * alpha, alpha);
    }

    rgb = mix(rgb, float3(1.0), u.border * 0.9 * clamp(0.5 + (d + u.bw) / w, 0.0, 1.0));
    float ds = length(p - float2(0.0, u.margin * 0.25)) - min(h.x, h.y);
    float sh = u.shadow * 0.45 * (1.0 - smoothstep(-u.margin * 0.4, u.margin * 0.8, ds));
    float alpha = clamp(a + (1.0 - a) * sh, 0.0, 1.0) * u.opacity;
    return float4(rgb * a * u.opacity, alpha);
}

// ---- Motion-blur accumulation (premultiplied RGBA, additive)
struct AccU { float weight; };
fragment float4 accumFS(VO in [[stage_in]], constant AccU &u [[buffer(0)]], texture2d<float, access::read> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy)) * u.weight;
}

// ---- Resolve: scene over cached backdrop, triangular dither, convert to output format
static uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
static float rnd(uint2 p, uint seed) { return float(pcg(p.x + pcg(p.y + pcg(seed)))) * (1.0 / 4294967295.0); }
struct ResU { float levels; uint seed; float blur; float alpha; };
fragment float4 resolveFS(VO in [[stage_in]], constant ResU &u [[buffer(0)]],
                          texture2d<float, access::read> scene [[texture(0)]],
                          texture2d<float> back [[texture(1)]]) {
    uint2 g = uint2(in.pos.xy);
    float4 s = scene.read(g);
    float2 uv = (float2(g) + 0.5) / float2(back.get_width(), back.get_height());
    // Transparent delivery keeps the premultiplied scene untouched: no
    // backdrop, no dither, no forced opaque alpha.
    if (u.alpha < 0.5) return s;
    // Only the backdrop has mipmaps. Text, cursor, and webcam are drawn into
    // the sharp scene layer, sampled without any blur.
    float3 background = back.sample(linMip, uv, level(u.blur)).rgb;
    float3 c = s.rgb + background * (1.0 - s.a);
    float n = rnd(g, u.seed) + rnd(g, u.seed + 1u) - 1.0;
    return float4(clamp(c + n / u.levels, 0.0, 1.0), 1.0);
}

// Premultiplied text sprite rasterized by CoreText on the CPU once per content/style.
// The Metal pass is shared by the editor preview and offline export.
struct TextSpriteU { float opacity; float blur; float pad0; float pad1; };
fragment float4 textSpriteFS(VO in [[stage_in]], constant TextSpriteU &u [[buffer(0)]],
                            texture2d<float> image [[texture(0)]]) {
    float4 c = image.sample(linClamp, in.q);
    float b = max(u.blur, 0.0);
    if (b > 0.05) {
        // Short blur-in only. Nine samples at the requested radius are enough
        // at caption sizes and cheaper than a per-sprite mip chain.
        float2 tx = b / float2(image.get_width(), image.get_height());
        float4 sum = c * 0.227027;
        sum += image.sample(linClamp, in.q + float2(tx.x, 0.0)) * 0.1945946;
        sum += image.sample(linClamp, in.q - float2(tx.x, 0.0)) * 0.1945946;
        sum += image.sample(linClamp, in.q + float2(0.0, tx.y)) * 0.1216216;
        sum += image.sample(linClamp, in.q - float2(0.0, tx.y)) * 0.1216216;
        sum += image.sample(linClamp, in.q + tx) * 0.054054;
        sum += image.sample(linClamp, in.q - tx) * 0.054054;
        sum += image.sample(linClamp, in.q + float2(tx.x, -tx.y)) * 0.016216;
        sum += image.sample(linClamp, in.q + float2(-tx.x, tx.y)) * 0.016216;
        c = sum;
    }
    return c * clamp(u.opacity, 0.0, 1.0);
}

// ---- Separable Gaussian: the caption card's frosted material.
// Two passes (H then V) at quarter resolution. A true kernel, not a mip pick:
// mip sampling box-filters and reads as blocky at card sizes.
struct BlurU { float2 dir; float sigma; float pad0; float pad1; };
fragment float4 gaussFS(VO in [[stage_in]], constant BlurU &u [[buffer(0)]],
                        texture2d<float> src [[texture(0)]]) {
    // Six symmetric taps spaced at half a sigma reach 3 sigma, which captures
    // 99.7% of the kernel at a fixed cost. Weights are therefore fixed; only
    // the spacing carries the radius, so any sigma costs the same.
    float2 step = u.dir * max(u.sigma, 0.4) * 0.5;
    float4 sum = src.sample(linClamp, in.q);
    float wsum = 1.0;
    for (int i = 1; i <= 6; ++i) {
        float fi = float(i) * 0.5;
        float w = exp(-0.5 * fi * fi);
        sum += (src.sample(linClamp, in.q + step * float(i))
              + src.sample(linClamp, in.q - step * float(i))) * w;
        wsum += 2.0 * w;
    }
    return sum / wsum;
}

// ---- Caption card: a real frosted material, not a baked grey pill.
// Samples the Gaussian-blurred scene, boosts saturation, then adapts a dark
// tint until white text keeps >= 4.5:1 contrast. The CPU draws this before the
// sharp text; preview and export share the shader.
struct CaptionCardU { float4 rect; float4 tint; float2 canvas; float radius; float opacity; };
fragment float4 captionCardFS(VO in [[stage_in]], constant CaptionCardU &u [[buffer(0)]],
                              texture2d<float> scene [[texture(0)]]) {
    float a = rectMask(in.px, u.rect, u.radius) * clamp(u.opacity, 0.0, 1.0);
    if (a <= 0.001) return float4(0.0);
    float2 uv = in.px / u.canvas;
    float3 b = scene.sample(linClamp, clamp(uv, 0.0, 1.0)).rgb;
    float luma = dot(b, float3(0.2126, 0.7152, 0.0722));
    // Frosted glass lifts colour before the dark tint lands on it.
    float3 sat = clamp(mix(float3(luma), b, 1.70), 0.0, 1.0);
    float3 face = mix(u.tint.rgb, sat, 0.12);
    float faceL = dot(face, float3(0.2126, 0.7152, 0.0722));
    // Solve overlay alpha so the resulting backdrop luminance stays <= 0.14
    // (target 0.14, threshold 0.18 for 4.5:1 with white).
    float need = (luma - 0.14) / max(luma - faceL, 1e-3);
    float alpha = clamp(max(need, u.tint.a), 0.55, 0.97);
    // A hairline specular rim keeps the material from reading as flat paint.
    float2 h = u.rect.zw * 0.5;
    float d = sdSquircle(in.px - (u.rect.xy + h), h, u.radius);
    float rim = exp(-pow(d / 1.6, 2.0)) * step(d, 0.0);
    face = clamp(face + float3(0.05) * rim, 0.0, 1.0);
    // Composite the blurred backdrop and the tint inside the card, then make
    // the card opaque. A translucent card would reveal the sharp scene and
    // defeat the blur; only the rounded edge uses the mask alpha.
    float3 finalColor = face * alpha + b * (1.0 - alpha);
    return float4(finalColor * a, a);
}

struct HighlightU {
    float4 rect;
    float4 content;
    float opacity;
    float strength;
    int mode;
};
fragment float4 highlightFS(VO in [[stage_in]], constant HighlightU &u [[buffer(0)]]) {
    float2 p = in.px;
    if (p.x < u.content.x || p.y < u.content.y ||
        p.x > u.content.x + u.content.z || p.y > u.content.y + u.content.w)
        return float4(0.0);
    float2 lo = p - u.rect.xy;
    float2 hi = u.rect.xy + u.rect.zw - p;
    bool inside = all(lo >= 0.0) && all(hi >= 0.0);
    float alpha = 0.0;
    if (u.mode == 0) {
        alpha = inside ? 0.0 : u.strength * u.opacity;
        return float4(0.0, 0.0, 0.0, alpha);
    }
    float2 d = max(max(-lo, -hi), float2(0.0));
    float outsideDistance = length(d);
    float insideDistance = min(min(lo.x, lo.y), min(hi.x, hi.y));
    float distance = inside ? insideDistance : -outsideDistance;
    if (u.mode == 1) alpha = (1.0 - smoothstep(1.0, 3.0, abs(distance))) * u.opacity * 0.85;
    else alpha = exp(-pow(distance / 9.0, 2.0)) * u.opacity * 0.45;
    return float4(float3(1.0, 0.78, 0.30) * alpha, alpha);
}

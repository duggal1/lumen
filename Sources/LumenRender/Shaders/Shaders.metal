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
                   float radius; float shadow; float scale; float cell; float density; int hasWall; float time; float4 pointer; };

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
        float2 grid = floor(in.px / pitch), local = fract(in.px / pitch);
        float step = pitch / u.canvas.y;
        float nx = grid.x * step * 1.4 - u.time * 0.09, ny = grid.y * step * 2.6;
        float warp = fieldNoise(float3(nx * 0.6 + 11.0, ny * 0.6, u.time * 0.05));
        float value = 0.65 * fieldNoise(float3(nx + warp * 1.2, ny, u.time * 0.12))
                    + 0.35 * fieldNoise(float3(nx * 2.3 + 7.0, ny * 2.3, u.time * 0.2 + 3.0));
        bool dash = local.x >= 0.14 && local.x < 0.86 && local.y >= 0.30 && local.y < 0.70;
        bool hatch = int(grid.x - grid.y) % 3 != 0;
        c = dash && hatch && value >= 0.5 ? cols[1].rgb : cols[0].rgb;
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
        float2 ts = float2(wall.get_width(), wall.get_height());
        float s = max(u.canvas.x / ts.x, u.canvas.y / ts.y);
        float2 off = (u.canvas - ts * s) * 0.5;
        c = wall.sample(linClamp, (in.px - off) / (ts * s)).rgb;
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

// ---- High-quality resampling: Catmull-Rom (9 taps) at two mip levels
static float3 catmull(texture2d<float> t, float2 uv, uint lv) {
    float2 sz = float2(t.get_width(lv), t.get_height(lv));
    float2 sp = uv * sz;
    float2 t1 = floor(sp - 0.5) + 0.5;
    float2 f = sp - t1;
    float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
    float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
    float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
    float2 w3 = f * f * (-0.5 + 0.5 * f);
    float2 w12 = w1 + w2;
    float2 p0 = (t1 - 1.0) / sz, p3 = (t1 + 2.0) / sz, p12 = (t1 + w2 / w12) / sz;
    float L = float(lv);
    float3 r = float3(0.0);
    r += t.sample(linClamp, float2(p0.x,  p0.y),  level(L)).rgb * (w0.x  * w0.y);
    r += t.sample(linClamp, float2(p12.x, p0.y),  level(L)).rgb * (w12.x * w0.y);
    r += t.sample(linClamp, float2(p3.x,  p0.y),  level(L)).rgb * (w3.x  * w0.y);
    r += t.sample(linClamp, float2(p0.x,  p12.y), level(L)).rgb * (w0.x  * w12.y);
    r += t.sample(linClamp, float2(p12.x, p12.y), level(L)).rgb * (w12.x * w12.y);
    r += t.sample(linClamp, float2(p3.x,  p12.y), level(L)).rgb * (w3.x  * w12.y);
    r += t.sample(linClamp, float2(p0.x,  p3.y),  level(L)).rgb * (w0.x  * w3.y);
    r += t.sample(linClamp, float2(p12.x, p3.y),  level(L)).rgb * (w12.x * w3.y);
    r += t.sample(linClamp, float2(p3.x,  p3.y),  level(L)).rgb * (w3.x  * w3.y);
    return r;
}
static float3 sampleMip(texture2d<float> t, float2 uv, float minif) {
    float maxL = float(t.get_num_mip_levels() - 1);
    float L = clamp(log2(max(minif, 1.0)), 0.0, maxL);
    float l0 = floor(L), f = L - l0;
    float3 a = catmull(t, uv, uint(l0));
    if (f > 0.001 && l0 + 1.0 <= maxL) a = mix(a, catmull(t, uv, uint(l0) + 1u), f);
    return max(a, float3(0.0));
}

// ---- Content (camera-transformed source inside the rounded mask)
// `tilt` is (yaw, pitch) in degrees. A small perspective divide is enough to
// sell depth without ever sampling outside the source: the warp is clamped so
// the visible rectangle can never exceed the original frame.
struct ContentU { float4 content; float2 src; float2 cam; float scale; float radius; float border; float p; float2 tilt; };

fragment float4 contentFS(VO in [[stage_in]], constant ContentU &u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 h = u.content.zw * 0.5;
    float d = sdSquircle(in.px - (u.content.xy + h), h, u.radius);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float2 view = u.src / u.scale;
    float2 n = (in.px - u.content.xy) / u.content.zw - 0.5;
    if (abs(u.tilt.x) + abs(u.tilt.y) > 0.001) {
        float ky = tan(radians(clamp(u.tilt.x, -18.0, 18.0)));
        float kx = tan(radians(clamp(u.tilt.y, -18.0, 18.0)));
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

// ---- Privacy masks: source-space rectangles composited after screen content.
// Mode 3 (Blend) never samples pixels inside the protected region; mode 2
// (Solid) never samples the source. Blur/pixelation are visual effects only.
struct PrivacyU {
    float4 content;
    float4 sourceRect;
    float2 sourceSize;
    float2 safeSample;
    float radius;
    int mode;
    float block;
    float pad;
};
fragment float4 privacyFS(VO in [[stage_in]], constant PrivacyU &u [[buffer(0)]],
                          texture2d<float> src [[texture(0)]]) {
    float alpha = rectMask(in.px, u.content, u.radius);
    if (alpha <= 0.0) return float4(0.0);
    float2 p = u.sourceRect.xy + in.q * u.sourceRect.zw;
    float2 sourceUV = p / u.sourceSize;
    float3 rgb;
    if (u.mode == 2) {
        // Deliberately opaque. Never let the original characters show through.
        rgb = float3(0.09);
    } else if (u.mode == 3) {
        // Sample only outside the masked source rectangle. The CPU falls back
        // to solid when every neighboring pixel could contain masked data.
        rgb = src.sample(linClamp, u.safeSample / u.sourceSize, level(0.0)).rgb;
    } else if (u.mode == 1) {
        float pitch = max(u.block, 24.0);
        float2 tile = floor(p / pitch) * pitch + 0.5 * pitch;
        rgb = src.sample(linClamp, clamp(tile / u.sourceSize, 0.0, 1.0), level(0.0)).rgb;
    } else {
        // Visual obfuscation only. Blur is not presented as secure redaction.
        float2 r = float2(max(u.block, 16.0)) / u.sourceSize;
        rgb = float3(0);
        for (int y = -2; y <= 2; ++y) {
            for (int x = -2; x <= 2; ++x) {
                rgb += src.sample(linClamp, clamp(sourceUV + float2(x, y) * r, 0.0, 1.0), level(0.0)).rgb;
            }
        }
        rgb *= 1.0 / 25.0;
    }
    return float4(rgb * alpha, alpha);
}

// ---- Cursor sprite (premultiplied atlas, mip-mapped)
struct CursorU { float4 content; float radius; float opacity; uint layer; float p; };
fragment float4 cursorFS(VO in [[stage_in]], constant CursorU &u [[buffer(0)]], texture2d_array<float> atlas [[texture(0)]]) {
    float4 c = atlas.sample(linMip, in.q, u.layer);
    return c * (u.opacity * rectMask(in.px, u.content, u.radius));
}

// ---- Click ring
struct RingU { float4 content; float4 color; float2 center; float radius; float progress; float cr; };
fragment float4 ringFS(VO in [[stage_in]], constant RingU &u [[buffer(0)]]) {
    float p = u.progress, e = 1.0 - pow(1.0 - p, 3.0);
    float r = mix(0.25, 1.0, e) * u.radius * 0.9, wd = mix(0.16, 0.025, e) * u.radius;
    float dd = abs(length(in.px - u.center) - r) - wd * 0.5;
    float ring = clamp(0.5 - dd / max(fwidth(dd), 1e-3), 0.0, 1.0);
    float a = ring * pow(max(1.0 - p, 0.0), 1.5) * u.color.a * rectMask(in.px, u.content, u.cr);
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
struct TextSpriteU { float opacity; };
fragment float4 textSpriteFS(VO in [[stage_in]], constant TextSpriteU &u [[buffer(0)]],
                            texture2d<float> image [[texture(0)]]) {
    return image.sample(linClamp, float2(in.q.x, 1.0 - in.q.y)) * clamp(u.opacity, 0.0, 1.0);
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

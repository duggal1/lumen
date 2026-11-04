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
                   float radius; float shadow; float scale; float cell; float density; int hasWall; float time; };

constant float kBayer[16] = { 0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5 };

fragment float4 backdropFS(VO in [[stage_in]], constant BackdropU &u [[buffer(0)]], constant float4 *cols [[buffer(1)]],
                           texture2d<float> wall [[texture(0)]]) {
    float2 uv = in.px / u.canvas;
    float3 c = cols[0].rgb;
    if (u.kind == 3) {
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
struct ContentU { float4 content; float2 src; float2 cam; float scale; float radius; float border; float p; };

fragment float4 contentFS(VO in [[stage_in]], constant ContentU &u [[buffer(0)]], texture2d<float> src [[texture(0)]]) {
    float2 h = u.content.zw * 0.5;
    float d = sdSquircle(in.px - (u.content.xy + h), h, u.radius);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    if (a <= 0.0) return float4(0.0);
    float2 view = u.src / u.scale;
    float2 sp = u.cam + ((in.px - u.content.xy) / u.content.zw - 0.5) * view;
    float3 rgb = sampleMip(src, sp / u.src, view.x / u.content.z);
    if (u.border > 0.5) rgb = mix(rgb, float3(1.0), 0.08 * clamp(0.5 + (d + 1.0) / w, 0.0, 1.0));
    return float4(rgb * a, a);
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
struct WebU { float4 crop; float4 bubble; float radius; float shape; float mirror; float border; float shadow; float bw; float minif; float margin; };
fragment float4 webFS(VO in [[stage_in]], constant WebU &u [[buffer(0)]], texture2d<float> tex [[texture(0)]]) {
    float2 h = u.bubble.zw * 0.5, p = in.px - (u.bubble.xy + h);
    float d = u.shape < 0.5 ? length(p) - h.x : sdSquircle(p, h, u.radius);
    float w = max(fwidth(d), 1e-3);
    float a = clamp(0.5 - d / w, 0.0, 1.0);
    float ds = length(p - float2(0.0, u.margin * 0.25)) - h.x;
    float sh = u.shadow * 0.45 * (1.0 - smoothstep(-u.margin * 0.4, u.margin * 0.8, ds));
    float2 q = (p + h) / u.bubble.zw;
    float2 uvw = u.crop.xy + float2(u.mirror > 0.5 ? 1.0 - q.x : q.x, q.y) * u.crop.zw;
    float3 rgb = sampleMip(tex, uvw, u.minif);
    rgb = mix(rgb, float3(1.0), u.border * 0.9 * clamp(0.5 + (d + u.bw) / w, 0.0, 1.0));
    return float4(rgb * a, a + (1.0 - a) * sh);
}

// ---- Motion-blur accumulation (premultiplied RGBA, additive)
struct AccU { float weight; };
fragment float4 accumFS(VO in [[stage_in]], constant AccU &u [[buffer(0)]], texture2d<float, access::read> src [[texture(0)]]) {
    return src.read(uint2(in.pos.xy)) * u.weight;
}

// ---- Resolve: scene over cached backdrop, triangular dither, convert to output format
static uint pcg(uint v) { uint s = v * 747796405u + 2891336453u; uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u; return (w >> 22u) ^ w; }
static float rnd(uint2 p, uint seed) { return float(pcg(p.x + pcg(p.y + pcg(seed)))) * (1.0 / 4294967295.0); }
struct ResU { float levels; uint seed; };
fragment float4 resolveFS(VO in [[stage_in]], constant ResU &u [[buffer(0)]],
                          texture2d<float, access::read> scene [[texture(0)]], texture2d<float, access::read> back [[texture(1)]]) {
    uint2 g = uint2(in.pos.xy);
    float4 s = scene.read(g);
    float3 c = s.rgb + back.read(g).rgb * (1.0 - s.a);
    float n = rnd(g, u.seed) + rnd(g, u.seed + 1u) - 1.0;
    return float4(clamp(c + n / u.levels, 0.0, 1.0), 1.0);
}
/// The stage's shaders, compiled when the renderer starts, since SwiftPM doesn't build Metal files.
///
/// Everything is drawn as instanced quads in world units, shaped in the fragment shader by signed distances, so
/// outlines stay crisp at every zoom. Colours come in straight and go out premultiplied.
let stageShaderSource = #"""
#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 viewSize;      // points
    float2 center;        // world point at the middle of the view
    float scale;          // points per world unit
    float pixelScale;     // pixels per point
    float time;
    int count;            // streams, for the stream pass
};

constant float2 corners[6] = { float2(0, 0), float2(1, 0), float2(0, 1), float2(0, 1), float2(1, 0), float2(1, 1) };

float4 toClip(float2 world, constant Uniforms& u) {
    float2 view = (world - u.center) * u.scale + u.viewSize * 0.5;
    return float4(view.x / u.viewSize.x * 2 - 1, 1 - view.y / u.viewSize.y * 2, 0, 1);
}

/// World units in a pixel.
float pixel(constant Uniforms& u) { return 1.0 / (u.scale * u.pixelScale); }

float4 premultiply(float3 rgb, float a) { return float4(rgb * a, a); }
float4 over(float4 below, float4 above) { return above + below * (1 - above.a); }

// MARK: Background: off-black with a faint grid of dots that thins out as you zoom out.

struct BackgroundColors { float4 background; float4 grid; };
struct BackgroundOut { float4 position [[position]]; float2 world; };

vertex BackgroundOut background_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float2 c = corners[vid];
    BackgroundOut out;
    out.position = float4(c.x * 2 - 1, 1 - c.y * 2, 0, 1);
    out.world = (c * u.viewSize - u.viewSize * 0.5) / u.scale + u.center;
    return out;
}

float gridDots(float2 world, float spacing, constant Uniforms& u) {
    float2 offset = (world / spacing - round(world / spacing)) * spacing;
    float d = length(offset) * u.scale * u.pixelScale;
    float radius = 1.0 * u.pixelScale;
    float dot = clamp(radius - d + 0.5, 0.0, 1.0);
    return dot * smoothstep(7.0, 16.0, spacing * u.scale);
}

fragment float4 background_fragment(BackgroundOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    constant BackgroundColors& colors [[buffer(1)]]) {
    float fine = gridDots(in.world, 24.0, u);
    float coarse = gridDots(in.world, 120.0, u) * (1 - smoothstep(7.0, 16.0, 24.0 * u.scale));
    float3 rgb = mix(colors.background.rgb, colors.grid.rgb, max(fine, coarse));
    return float4(rgb, 1);
}

// MARK: Tiles: a face with depth below it, like a Mahjong tile, and a hatched shadow.

struct Tile {
    float4 color;
    float2 center;
    float2 halfSize;
    float flash;
    int shape;
    int flags;          // 1 hovered, 2 selected, 4 dimmed
    float depth;
};

struct TileOut {
    float4 position [[position]];
    float2 local;
    uint index [[flat]];
};

vertex TileOut tile_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                           constant Tile* tiles [[buffer(1)]]) {
    Tile t = tiles[iid];
    float margin = 22;
    float2 low = -t.halfSize - margin;
    float2 high = t.halfSize + float2(margin, margin + t.depth);
    float2 local = mix(low, high, corners[vid]);
    TileOut out;
    out.position = toClip(t.center + local, u);
    out.local = local;
    out.index = iid;
    return out;
}

float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

float sdTriangle(float2 p, float2 p0, float2 p1, float2 p2) {
    float2 e0 = p1 - p0, e1 = p2 - p1, e2 = p0 - p2;
    float2 v0 = p - p0, v1 = p - p1, v2 = p - p2;
    float2 pq0 = v0 - e0 * clamp(dot(v0, e0) / dot(e0, e0), 0.0, 1.0);
    float2 pq1 = v1 - e1 * clamp(dot(v1, e1) / dot(e1, e1), 0.0, 1.0);
    float2 pq2 = v2 - e2 * clamp(dot(v2, e2) / dot(e2, e2), 0.0, 1.0);
    float s = sign(e0.x * e2.y - e0.y * e2.x);
    float2 d = min(min(float2(dot(pq0, pq0), s * (v0.x * e0.y - v0.y * e0.x)),
                       float2(dot(pq1, pq1), s * (v1.x * e1.y - v1.y * e1.x))),
                       float2(dot(pq2, pq2), s * (v2.x * e2.y - v2.y * e2.x)));
    return -sqrt(d.x) * sign(d.y);
}

/// The tile's outline as a signed distance, negative inside. Triangles are shrunk toward their middle, then grown
/// back round, so their corners are rounded and their size stays the same.
float sdShape(float2 p, int shape, float2 h) {
    if (shape == 0) return sdRoundBox(p, h, 10.0);
    if (shape == 1) return length(p) - h.x;
    float2 a, b, c;
    if (shape == 2) { a = float2(-h.x, -h.y); b = float2(h.x, -h.y); c = float2(0, h.y); }
    else if (shape == 3) { a = float2(-h.x, -h.y); b = float2(h.x, 0); c = float2(-h.x, h.y); }
    else { a = float2(h.x, -h.y); b = float2(-h.x, 0); c = float2(h.x, h.y); }
    float la = length(b - c), lb = length(c - a), lc = length(a - b);
    float perimeter = la + lb + lc;
    float2 middle = (a * la + b * lb + c * lc) / perimeter;
    float area = abs((b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)) * 0.5;
    float inradius = area / (perimeter * 0.5);
    float corner = min(7.0, inradius * 0.6);
    float k = (inradius - corner) / inradius;
    a = middle + (a - middle) * k; b = middle + (b - middle) * k; c = middle + (c - middle) * k;
    return sdTriangle(p, a, b, c) - corner;
}

/// The tile with its side: the face swept down by its depth.
float sdBody(float2 p, int shape, float2 h, float depth) {
    float d = sdShape(p, shape, h);
    for (int step = 1; step <= 6; step++) {
        d = min(d, sdShape(p - float2(0, depth * float(step) / 6.0), shape, h));
    }
    return d;
}

float fill(float d, float px) { return clamp(0.5 - d / px, 0.0, 1.0); }
float stroke(float d, float width, float px) { return clamp(0.5 - (abs(d) - width * 0.5) / px, 0.0, 1.0); }

fragment float4 tile_shadow_fragment(TileOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                     constant Tile* tiles [[buffer(1)]]) {
    Tile t = tiles[in.index];
    float px = pixel(u);
    float2 offset = float2(6.0, 7.0);
    float shadow = sdBody(in.local - offset, t.shape, t.halfSize, t.depth);
    float body = sdBody(in.local, t.shape, t.halfSize, t.depth);
    float region = fill(shadow, px) * clamp(0.5 + body / px, 0.0, 1.0);
    if (region <= 0) discard_fragment();
    // Diagonal hatching, drawn in world units, fading to a flat tint when the lines would be too close to see.
    float spacing = 4.5;
    float across = abs(fract((in.local.x + in.local.y) / spacing) - 0.5) * spacing * 0.7071;
    float halfWidth = max(0.55 * px, 0.45);
    float line = clamp(0.5 - (across - halfWidth) / px, 0.0, 1.0);
    float visible = smoothstep(2.5, 4.5, spacing / px);
    float alpha = (line * 0.42 * visible + 0.12 * (1 - visible)) * region;
    if ((t.flags & 4) != 0) alpha *= 0.5;
    return premultiply(t.color.rgb, alpha);
}

fragment float4 tile_fragment(TileOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              constant Tile* tiles [[buffer(1)]], constant float4& background [[buffer(2)]]) {
    Tile t = tiles[in.index];
    float px = pixel(u);
    float line = clamp(1.6 * px, 0.9, 3.0 * px);
    float face = sdShape(in.local, t.shape, t.halfSize);
    float body = sdBody(in.local, t.shape, t.halfSize, t.depth);
    float3 color = mix(t.color.rgb, float3(1.0, 0.30, 0.37), t.flash);
    bool hovered = (t.flags & 1) != 0;
    bool selected = (t.flags & 2) != 0;

    float4 result = float4(0);
    // A glow round it when hovered, selected or failing.
    float glow = (hovered ? 0.30 : 0.0) + (selected ? 0.55 : 0.0) + t.flash * 0.9;
    if (glow > 0 && body > 0) {
        result = premultiply(color, glow * exp(-body / 7.0) * clamp(body / px, 0.0, 1.0));
    }
    // The side: darker, its outline dimmer.
    float3 side = background.rgb * 0.7 + t.color.rgb * 0.05;
    result = over(result, premultiply(side, fill(body, px)));
    result = over(result, premultiply(color, 0.55 * stroke(body, line, px)));
    // A line where the face meets the side.
    float edge = sdShape(in.local - float2(0, t.depth * 0.5), t.shape, t.halfSize);
    result = over(result, premultiply(color, 0.22 * stroke(edge, line * 0.6, px) * fill(-face, px)));
    // The face, with a bevel inside its outline.
    float3 faceColor = background.rgb * 1.35 + t.color.rgb * 0.07 + float3(1, 0.3, 0.37) * t.flash * 0.18;
    result = over(result, premultiply(faceColor, fill(face, px)));
    result = over(result, premultiply(color, 0.24 * stroke(face + 4.0, line * 0.6, px)));
    result = over(result, premultiply(color, stroke(face, selected ? line * 1.8 : line, px)));
    return result;
}

// MARK: Wires: antialiased segments.

struct Segment {
    float4 color;
    float2 a;
    float2 b;
    float width;        // pixels
    int kind;           // 0 main, 1 errors, 2 backward
    float along;        // length of the wire before this segment
    float padding;
};

struct SegmentOut {
    float4 position [[position]];
    float2 local;       // along and across, world units, from a
    float length [[flat]];
    float halfWidth [[flat]];
    uint index [[flat]];
};

vertex SegmentOut wire_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                              constant Segment* segments [[buffer(1)]]) {
    Segment s = segments[iid];
    float px = pixel(u);
    float2 delta = s.b - s.a;
    float len = length(delta);
    float2 dir = len > 0 ? delta / len : float2(1, 0);
    float2 normal = float2(-dir.y, dir.x);
    float halfWidth = max(s.width * px, 0.8) * 0.5;
    float reach = halfWidth + px;
    float2 c = corners[vid];
    float alongPos = mix(-reach, len + reach, c.x);
    float acrossPos = mix(-reach, reach, c.y);
    SegmentOut out;
    out.position = toClip(s.a + dir * alongPos + normal * acrossPos, u);
    out.local = float2(alongPos, acrossPos);
    out.length = len;
    out.halfWidth = halfWidth;
    out.index = iid;
    return out;
}

fragment float4 wire_fragment(SegmentOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              constant Segment* segments [[buffer(1)]]) {
    Segment s = segments[in.index];
    float px = pixel(u);
    float along = clamp(in.local.x, 0.0, in.length);
    float d = length(float2(in.local.x - along, in.local.y));
    float coverage = clamp(0.5 - (d - in.halfWidth) / px, 0.0, 1.0);
    if (s.kind == 2) {
        float dash = fract((s.along + in.local.x) / 12.0);
        coverage *= step(dash, 0.55);
    }
    return premultiply(s.color.rgb, s.color.a * coverage);
}

// MARK: Particles: single ones placed by the CPU, and streams placed here from a path, a spacing and a phase.

struct Particle {
    float4 color;
    float2 position;
    float2 direction;
    float size;
    int style;          // 0 message, 1 rate, 2 fading
    float fade;
    float padding;
};

struct Stream {
    float4 color;
    int pointStart;
    int pointCount;
    int firstInstance;
    int style;
    float spacing;
    float phase;
    float size;
    float length;
};

struct ParticleOut {
    float4 position [[position]];
    float2 local;       // along and across, world units, from its middle
    float4 color;
    float size [[flat]];
    int style [[flat]];
};

ParticleOut placeParticle(uint vid, float2 position, float2 direction, float size, int style, float4 color,
                          constant Uniforms& u) {
    float px = pixel(u);
    float radius = max(size, 0.9 * px);
    float2 extent = style == 1 ? float2(radius * 4.0, radius * 1.6) : float2(radius * 3.2, radius * 3.2);
    float2 c = corners[vid] * 2 - 1;
    float2 local = c * extent;
    float2 normal = float2(-direction.y, direction.x);
    ParticleOut out;
    out.position = toClip(position + direction * local.x + normal * local.y, u);
    out.local = local;
    out.color = color;
    out.size = radius;
    out.style = style;
    return out;
}

vertex ParticleOut particle_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                                   constant Particle* particles [[buffer(1)]]) {
    Particle p = particles[iid];
    return placeParticle(vid, p.position, p.direction, p.size, p.style, p.color, u);
}

vertex ParticleOut stream_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                                 constant Stream* streams [[buffer(1)]], constant float4* points [[buffer(2)]]) {
    // The stream this particle belongs to: the last whose first instance is at or before it.
    int low = 0, high = u.count - 1;
    while (low < high) {
        int middle = (low + high + 1) / 2;
        if (streams[middle].firstInstance <= int(iid)) low = middle; else high = middle - 1;
    }
    Stream s = streams[low];
    float along = s.phase + float(int(iid) - s.firstInstance) * s.spacing;
    ParticleOut out;
    if (along > s.length || s.pointCount < 2) {
        out.position = float4(2, 2, 2, 1);
        out.local = float2(0); out.color = float4(0); out.size = 0; out.style = 0;
        return out;
    }
    // The segment of the path it's on.
    int first = s.pointStart, last = s.pointStart + s.pointCount - 1;
    while (last - first > 1) {
        int middle = (first + last) / 2;
        if (points[middle].z <= along) first = middle; else last = middle;
    }
    float4 a = points[first], b = points[last];
    float span = max(b.z - a.z, 0.0001);
    float t = clamp((along - a.z) / span, 0.0, 1.0);
    float2 position = mix(a.xy, b.xy, t);
    float2 direction = normalize(b.xy - a.xy + float2(0.00001, 0));
    float4 color = s.color;
    if (s.style == 2) color.a *= 1.0 - along / max(s.length, 1.0);
    // Fade in and out at the ends, so particles don't pop.
    color.a *= smoothstep(0.0, 6.0, along) * smoothstep(0.0, 6.0, s.length - along);
    return placeParticle(vid, position, direction, s.size, s.style, color, u);
}

fragment float4 particle_fragment(ParticleOut in [[stage_in]], constant Uniforms& u [[buffer(0)]]) {
    float px = pixel(u);
    float r = in.size;
    float alpha;
    if (in.style == 1) {
        // A streak, brightest at its head.
        float halfLength = r * 2.6;
        float along = clamp(in.local.x, -halfLength, halfLength);
        float d = length(float2(in.local.x - along, in.local.y));
        float core = clamp(0.5 - (d - r * 0.75) / px, 0.0, 1.0);
        float head = 0.25 + 0.75 * (along + halfLength) / (2 * halfLength);
        alpha = core * head;
    } else {
        float d = length(in.local);
        float core = clamp(0.5 - (d - r) / px, 0.0, 1.0);
        float halo = in.style == 0 ? exp(-(d * d) / (r * r * 3.2)) * 0.5 : 0.0;
        alpha = max(core, halo);
    }
    return premultiply(in.color.rgb, in.color.a * alpha);
}

// MARK: Text, from a glyph atlas of signed distances.

struct Glyph {
    float4 color;
    float2 origin;      // world, top left
    float2 size;        // world
    float2 uvMin;
    float2 uvMax;
    float pixelsPerTexel;
    float spread;       // texels
    float padding0;
    float padding1;
};

struct GlyphOut {
    float4 position [[position]];
    float2 uv;
    float4 color;
    float pixelsPerTexel [[flat]];
    float spread [[flat]];
};

vertex GlyphOut glyph_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                             constant Glyph* glyphs [[buffer(1)]]) {
    Glyph g = glyphs[iid];
    float2 c = corners[vid];
    GlyphOut out;
    out.position = toClip(g.origin + g.size * c, u);
    out.uv = mix(g.uvMin, g.uvMax, c);
    out.color = g.color;
    out.pixelsPerTexel = g.pixelsPerTexel;
    out.spread = g.spread;
    return out;
}

fragment float4 glyph_fragment(GlyphOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    float sampled = atlas.sample(linear, in.uv).r;
    float distance = (sampled - 0.5) * 2.0 * in.spread * in.pixelsPerTexel;
    float alpha = clamp(distance + 0.5, 0.0, 1.0);
    return premultiply(in.color.rgb, in.color.a * alpha);
}
"""#

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

// MARK: Background: the theme's colour, a starfield travelling toward the viewer, and a faint grid of dots that
// thins out as you zoom out.

struct BackgroundLook {
    float4 background;
    float4 grid;
    float4 starColor;
    float4 starTint;
    float gridSpacing;
    float coarseGridSpacing;
    float gridDotRadius;    // points
    float starOpacity;
    float starTravel;       // star lifetimes travelled; repeats every 100
    float starSpeed;        // lifetimes a second, now
    float starDensity;
    float starCellSize;     // points
    float starSize;         // points, when nearest
    float starBrightness;
    float starStreak;
    float starParallax;
    int starLayers;
    float padding0, padding1, padding2;
};

struct BackgroundOut { float4 position [[position]]; float2 world; float2 view; };

vertex BackgroundOut background_vertex(uint vid [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    float2 c = corners[vid];
    BackgroundOut out;
    out.position = float4(c.x * 2 - 1, 1 - c.y * 2, 0, 1);
    out.world = (c * u.viewSize - u.viewSize * 0.5) / u.scale + u.center;
    out.view = c * u.viewSize - u.viewSize * 0.5;
    return out;
}

float gridDots(float2 world, float spacing, float radius, constant Uniforms& u) {
    float2 offset = (world / spacing - round(world / spacing)) * spacing;
    float d = length(offset) * u.scale * u.pixelScale;
    float dot = clamp(radius * u.pixelScale - d + 0.5, 0.0, 1.0);
    return dot * smoothstep(7.0, 16.0, spacing * u.scale);
}

float hash12(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

/// The starfield's light at `view`, in points from the middle of the view, where the stars come from.
///
/// Stars live in layers, each a sky of cells holding at most one star. A layer's age runs from 0, far away, to 1, at
/// the viewer; as it ages its sky is drawn larger, so its stars spread out from the middle, grow and brighten, then
/// fade as they pass. When a layer comes round again its stars are new ones. The layers are spread evenly through
/// the ages, so there are always some far and some near.
float3 starfield(float2 view, constant BackgroundLook& look, constant Uniforms& u) {
    float px = 1.0 / u.pixelScale;
    float3 light = float3(0);
    int layers = look.starLayers;
    for (int i = 0; i < layers; i++) {
        float age = look.starTravel + float(i) / float(layers);
        float z = fract(age);
        float generation = fmod(floor(age), 100.0);
        // Points in the layer's sky for each point on screen: one when far, ever fewer as it nears.
        float shrink = mix(1.0, 0.08, z);
        float2 sky = view * shrink;
        float2 cell = floor(sky / look.starCellSize);
        float2 seed = cell + float2(float(i) * 37.0 + generation * 113.0, generation * 71.0 - float(i) * 17.0);
        if (hash12(seed) > look.starDensity) continue;
        float2 star = (cell + 0.2 + 0.6 * hash22(seed + 5.0)) * look.starCellSize / shrink;
        float2 delta = view - star;
        // Near stars streak back toward the middle, the faster the longer.
        float2 outward = normalize(star + float2(0.0001, 0));
        float along = dot(delta, outward);
        float across = dot(delta, float2(-outward.y, outward.x));
        float stretch = 1.0 + look.starStreak * look.starSpeed * z * z;
        if (along < 0) along /= stretch;
        float size = look.starSize * mix(0.25, 1.0, z * z) * mix(0.6, 1.25, hash12(seed + 9.0));
        float radius = max(size, 0.7 * px);
        float d = length(float2(along, across));
        float glow = exp(-(d * d) / (radius * radius)) * (size / radius);
        float fade = smoothstep(0.0, 0.35, z) * (1.0 - smoothstep(0.82, 1.0, z));
        float3 color = mix(look.starColor.rgb, look.starTint.rgb, step(0.72, hash12(seed + 3.0)));
        light += color * glow * fade * look.starBrightness;
    }
    return light;
}

fragment float4 background_fragment(BackgroundOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                    constant BackgroundLook& look [[buffer(1)]]) {
    float3 rgb = look.background.rgb;
    if (look.starOpacity > 0) {
        // Panning shifts the stars a little, so they seem far behind the grid.
        float2 view = in.view + u.center * look.starParallax;
        rgb += starfield(view, look, u) * look.starOpacity;
    }
    float fine = gridDots(in.world, look.gridSpacing, look.gridDotRadius, u);
    float coarse = gridDots(in.world, look.coarseGridSpacing, look.gridDotRadius, u)
        * (1 - smoothstep(7.0, 16.0, look.gridSpacing * u.scale));
    rgb = mix(rgb, look.grid.rgb, max(fine, coarse));
    return float4(min(rgb, float3(1)), 1);
}

// MARK: Tiles: a face with depth below it, like a Mahjong tile, and a hatched shadow.

struct Tile {
    float4 color;
    float2 center;
    float2 halfSize;
    float flash;
    int shape;
    int flags;          // 1 hovered, 2 selected, 4 dimmed, 8 ghost
    float depth;
};

struct TileLook {
    float4 flashColor;
    float2 shadowOffset;
    float cornerRadius;
    float triangleCornerRadius;
    float outlineWidth;
    float selectedOutlineScale;
    float faceLift;
    float faceTint;
    float sideShade;
    float sideTint;
    float sideOutlineOpacity;
    float edgeOpacity;
    float bevelInset;
    float bevelOpacity;
    float hoverGlow;
    float selectedGlow;
    float flashGlow;
    float glowReach;
    float ghostFaceOpacity;
    float ghostDashLength;
    float ghostDashDuty;
    float hatchSpacing;     // 0 for a flat shadow
    float hatchOpacity;
    float flatOpacity;
    float margin;
    float flashFaceTint;
    float padding0, padding1;
};

struct TileOut {
    float4 position [[position]];
    float2 local;
    uint index [[flat]];
};

vertex TileOut tile_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                           constant Tile* tiles [[buffer(1)]], constant TileLook& look [[buffer(3)]]) {
    Tile t = tiles[iid];
    float margin = look.margin;
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
float sdShape(float2 p, int shape, float2 h, constant TileLook& look) {
    if (shape == 0) return sdRoundBox(p, h, min(look.cornerRadius, min(h.x, h.y)));
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
    float corner = min(look.triangleCornerRadius, inradius * 0.6);
    float k = (inradius - corner) / inradius;
    a = middle + (a - middle) * k; b = middle + (b - middle) * k; c = middle + (c - middle) * k;
    return sdTriangle(p, a, b, c) - corner;
}

/// The tile with its side: the face swept down by its depth.
float sdBody(float2 p, int shape, float2 h, float depth, constant TileLook& look) {
    float d = sdShape(p, shape, h, look);
    for (int step = 1; step <= 6; step++) {
        d = min(d, sdShape(p - float2(0, depth * float(step) / 6.0), shape, h, look));
    }
    return d;
}

float fill(float d, float px) { return clamp(0.5 - d / px, 0.0, 1.0); }
float stroke(float d, float width, float px) { return clamp(0.5 - (abs(d) - width * 0.5) / px, 0.0, 1.0); }

fragment float4 tile_shadow_fragment(TileOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                     constant Tile* tiles [[buffer(1)]], constant TileLook& look [[buffer(3)]]) {
    Tile t = tiles[in.index];
    float px = pixel(u);
    float shadow = sdBody(in.local - look.shadowOffset, t.shape, t.halfSize, t.depth, look);
    float body = sdBody(in.local, t.shape, t.halfSize, t.depth, look);
    float region = fill(shadow, px) * clamp(0.5 + body / px, 0.0, 1.0);
    if (region <= 0) discard_fragment();
    // Diagonal hatching, drawn in world units, fading to a flat tint when the lines would be too close to see.
    float spacing = max(look.hatchSpacing, 0.001);
    float across = abs(fract((in.local.x + in.local.y) / spacing) - 0.5) * spacing * 0.7071;
    float halfWidth = max(0.55 * px, 0.45);
    float line = clamp(0.5 - (across - halfWidth) / px, 0.0, 1.0);
    float visible = look.hatchSpacing > 0 ? smoothstep(2.5, 4.5, spacing / px) : 0.0;
    float alpha = (line * look.hatchOpacity * visible + look.flatOpacity * (1 - visible)) * region;
    if ((t.flags & 4) != 0) alpha *= 0.5;
    if ((t.flags & 8) != 0) discard_fragment();
    return premultiply(t.color.rgb, alpha);
}

fragment float4 tile_fragment(TileOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                              constant Tile* tiles [[buffer(1)]], constant float4& background [[buffer(2)]],
                              constant TileLook& look [[buffer(3)]]) {
    Tile t = tiles[in.index];
    float px = pixel(u);
    float line = clamp(look.outlineWidth * px, 0.9, look.outlineWidth * 1.875 * px);
    float face = sdShape(in.local, t.shape, t.halfSize, look);
    float body = sdBody(in.local, t.shape, t.halfSize, t.depth, look);
    float3 color = mix(t.color.rgb, look.flashColor.rgb, t.flash);
    bool hovered = (t.flags & 1) != 0;
    bool selected = (t.flags & 2) != 0;
    bool ghost = (t.flags & 8) != 0;

    float4 result = float4(0);
    // A glow round it when hovered, selected or failing.
    float glow = (hovered ? look.hoverGlow : 0.0) + (selected ? look.selectedGlow : 0.0) + t.flash * look.flashGlow;
    if (glow > 0 && body > 0) {
        result = premultiply(color, glow * exp(-body / max(look.glowReach, 0.01)) * clamp(body / px, 0.0, 1.0));
    }
    float selectedLine = selected ? line * look.selectedOutlineScale : line;
    if (ghost) {
        // Not running yet, or being mended: a faint face, and an outline of dashes, cut by diagonal bands in world
        // units so they keep their spacing on every shape.
        float3 faceColor = background.rgb * 1.15 + color * 0.04;
        result = over(result, premultiply(faceColor, look.ghostFaceOpacity * fill(face, px)));
        float dash = step(1.0 - look.ghostDashDuty, fract((in.local.x - in.local.y) / look.ghostDashLength));
        result = over(result, premultiply(color, dash * stroke(face, selected ? selectedLine : line * 1.2, px)));
        return result;
    }
    // The side: darker, its outline dimmer.
    float3 side = background.rgb * look.sideShade + t.color.rgb * look.sideTint;
    result = over(result, premultiply(side, fill(body, px)));
    result = over(result, premultiply(color, look.sideOutlineOpacity * stroke(body, line, px)));
    // A line where the face meets the side.
    float edge = sdShape(in.local - float2(0, t.depth * 0.5), t.shape, t.halfSize, look);
    result = over(result, premultiply(color, look.edgeOpacity * stroke(edge, line * 0.6, px) * fill(-face, px)));
    // The face, with a bevel inside its outline.
    float3 faceColor = background.rgb * look.faceLift + t.color.rgb * look.faceTint + look.flashColor.rgb * t.flash * look.flashFaceTint;
    result = over(result, premultiply(faceColor, fill(face, px)));
    result = over(result, premultiply(color, look.bevelOpacity * stroke(face + look.bevelInset, line * 0.6, px)));
    result = over(result, premultiply(color, stroke(face, selectedLine, px)));
    return result;
}

// MARK: Wires: antialiased segments.

struct Segment {
    float4 color;
    float2 a;
    float2 b;
    float width;        // pixels
    int kind;           // 0 main, 1 errors, 2 backward, 3 declared flow, 4 flow
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
                              constant Segment* segments [[buffer(1)]], constant float4& dashes [[buffer(2)]]) {
    Segment s = segments[in.index];
    float px = pixel(u);
    float along = clamp(in.local.x, 0.0, in.length);
    float d = length(float2(in.local.x - along, in.local.y));
    float coverage = clamp(0.5 - (d - in.halfWidth) / px, 0.0, 1.0);
    if (s.kind == 2) {
        float dash = fract((s.along + in.local.x) / max(dashes.x, 0.5));
        coverage *= step(dash, dashes.y);
    } else if (s.kind == 3) {
        // A declared flow's dashes keep their length on screen, at every zoom.
        float dash = fract((s.along + in.local.x) / max(dashes.z * px, 1e-6));
        coverage *= step(dash, dashes.w);
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
    } else if (in.style == 3) {
        // A real message: a ring round a bright core, with a glow, unlike the dots and streaks counts make.
        float d = length(in.local);
        float ring = clamp(0.5 - (abs(d - r) - max(r * 0.18, 0.6 * px)) / px, 0.0, 1.0);
        float core = clamp(0.5 - (d - r * 0.38) / px, 0.0, 1.0);
        float halo = exp(-(d * d) / (r * r * 2.5)) * 0.35;
        alpha = max(max(ring, core), halo);
    } else {
        float d = length(in.local);
        float core = clamp(0.5 - (d - r) / px, 0.0, 1.0);
        float halo = in.style == 0 ? exp(-(d * d) / (r * r * 3.2)) * 0.5 : 0.0;
        alpha = max(core, halo);
    }
    return premultiply(in.color.rgb, in.color.a * alpha);
}

// MARK: Regions: the plates hosts and pipelines sit on when the Continuum is drawn whole, rounded rectangles (or
// circles) with a fill and an outline whose width is in points, so they read the same at every zoom.

struct Region {
    float4 fill;
    float4 stroke;
    float2 center;
    float2 halfSize;
    float radius;       // world units
    float strokeWidth;  // points
    int flags;          // 1 dashed, 2 hovered, 4 selected
    float glow;         // 0 to 1
};

struct RegionOut {
    float4 position [[position]];
    float2 local;
    uint index [[flat]];
};

vertex RegionOut region_vertex(uint vid [[vertex_id]], uint iid [[instance_id]], constant Uniforms& u [[buffer(0)]],
                               constant Region* regions [[buffer(1)]]) {
    Region r = regions[iid];
    float margin = (r.strokeWidth + 16.0) / u.scale;
    float2 local = mix(-r.halfSize - margin, r.halfSize + margin, corners[vid]);
    RegionOut out;
    out.position = toClip(r.center + local, u);
    out.local = local;
    out.index = iid;
    return out;
}

fragment float4 region_fragment(RegionOut in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                constant Region* regions [[buffer(1)]]) {
    Region r = regions[in.index];
    float px = pixel(u);
    float radius = min(r.radius, min(r.halfSize.x, r.halfSize.y));
    float2 q = abs(in.local) - r.halfSize + radius;
    float sd = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    float fillAlpha = clamp(0.5 - sd / px, 0.0, 1.0);
    float width = r.strokeWidth / u.scale;
    float strokeAlpha = clamp(0.5 - (abs(sd + width * 0.5) - width * 0.5) / px, 0.0, 1.0);
    if ((r.flags & 1) != 0) {
        float dash = 9.0 / u.scale;
        strokeAlpha *= step(0.45, fract((in.local.x + in.local.y) / dash));
    }
    float4 color = premultiply(r.fill.rgb, r.fill.a * fillAlpha);
    float glow = r.glow;
    if ((r.flags & 2) != 0) glow = max(glow, 0.35);
    if ((r.flags & 4) != 0) glow = max(glow, 0.6);
    if (glow > 0) {
        float reach = 12.0 / u.scale;
        float outside = max(sd, 0.0);
        float halo = exp(-(outside * outside) / (reach * reach)) * (1.0 - fillAlpha) * glow * 0.5;
        color = over(color, premultiply(r.stroke.rgb, halo));
    }
    color = over(color, premultiply(r.stroke.rgb, r.stroke.a * strokeAlpha));
    return color;
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

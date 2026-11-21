import CoreGraphics
import CoreText
import Foundation
import Metal
import QuartzCore
import Stage
import simd

/// Draws a ``StageSnapshot`` with Metal: the background with its starfield and grid, tiles' shadows, wires, particles,
/// tiles and text, each as one instanced draw, in the look of the snapshot's ``Theme``. The same renderer serves the Mac and the iPad; the platform supplies the drawable.
@MainActor
public final class StageRenderer {
    public let device: MTLDevice
    public let pixelFormat: MTLPixelFormat
    private let queue: MTLCommandQueue
    private let background: MTLRenderPipelineState
    private let shadows: MTLRenderPipelineState
    private let tiles: MTLRenderPipelineState
    private let wires: MTLRenderPipelineState
    private let singles: MTLRenderPipelineState
    private let streams: MTLRenderPipelineState
    private let glyphs: MTLRenderPipelineState
    private let regions: MTLRenderPipelineState
    private let atlas: GlyphAtlas
    private let shaper = TextShaper.shared

    /// What the last frame drew, for tests and the frame counter.
    public private(set) var lastCounts = Counts()

    public struct Counts: Sendable, Equatable {
        public var tiles = 0
        public var segments = 0
        public var particles = 0
        public var streamed = 0
        public var glyphs = 0
        public var regions = 0
    }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let device, let queue = device.makeCommandQueue(), let atlas = GlyphAtlas(device: device) else { return nil }
        self.device = device
        self.pixelFormat = pixelFormat
        self.queue = queue
        self.atlas = atlas
        do {
            let library = try device.makeLibrary(source: stageShaderSource, options: nil)
            func pipeline(_ vertex: String, _ fragment: String, blended: Bool = true) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.label = vertex
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                let attachment = descriptor.colorAttachments[0]!
                attachment.pixelFormat = pixelFormat
                if blended {
                    attachment.isBlendingEnabled = true
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
                }
                return try device.makeRenderPipelineState(descriptor: descriptor)
            }
            background = try pipeline("background_vertex", "background_fragment", blended: false)
            shadows = try pipeline("tile_vertex", "tile_shadow_fragment")
            tiles = try pipeline("tile_vertex", "tile_fragment")
            wires = try pipeline("wire_vertex", "wire_fragment")
            singles = try pipeline("particle_vertex", "particle_fragment")
            streams = try pipeline("stream_vertex", "particle_fragment")
            glyphs = try pipeline("glyph_vertex", "glyph_fragment")
            regions = try pipeline("region_vertex", "region_fragment")
        } catch {
            assertionFailure("The stage's shaders didn't compile: \(error)")
            return nil
        }
    }

    // MARK: Drawing

    /// Encodes `snapshot` into `commandBuffer`, drawing into `pass`'s first colour attachment, for a view of `size`
    /// points with `pixelScale` pixels to a point.
    public func encode(_ snapshot: StageSnapshot, into commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, pixelScale: CGFloat) {
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(snapshot.background.x), green: Double(snapshot.background.y), blue: Double(snapshot.background.z), alpha: 1
        )
        guard size.width > 0, size.height > 0, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.label = "Stage"
        var uniforms = Uniforms(
            viewSize: SIMD2(Float(size.width), Float(size.height)),
            center: SIMD2(Float(snapshot.camera.center.x), Float(snapshot.camera.center.y)),
            scale: Float(snapshot.camera.scale), pixelScale: Float(pixelScale), time: Float(snapshot.time.truncatingRemainder(dividingBy: 10_000)), count: 0
        )
        var counts = Counts()
        let theme = snapshot.theme

        // The background, its starfield and its grid.
        var backgroundLook = BackgroundLook(snapshot)
        encoder.setRenderPipelineState(background)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&backgroundLook, length: MemoryLayout<BackgroundLook>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)

        // The plates of hosts and pipelines, under everything else.
        let regionData = snapshot.regions.map(RegionInstance.init)
        counts.regions = regionData.count
        if let regionBuffer = buffer(regionData) {
            encoder.setRenderPipelineState(regions)
            bind(encoder, uniforms: &uniforms, buffer: regionBuffer)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: regionData.count)
        }

        var tileLook = TileLook(theme)
        let tileData = snapshot.tiles.map { TileInstance($0, depth: theme.tiles.depth) }
        counts.tiles = tileData.count
        let tileBuffer = buffer(tileData)

        // Shadows first, so wires pass over them.
        if let tileBuffer {
            encoder.setRenderPipelineState(shadows)
            bind(encoder, uniforms: &uniforms, buffer: tileBuffer)
            encoder.setVertexBytes(&tileLook, length: MemoryLayout<TileLook>.stride, index: 3)
            encoder.setFragmentBytes(&tileLook, length: MemoryLayout<TileLook>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: tileData.count)
        }

        // Wires.
        var segments: [SegmentInstance] = []
        for wire in snapshot.wires {
            let usual = wire.width ?? theme.wires.width
            let width = wire.isHovered ? max(theme.wires.hoveredWidth, usual + 1.2) : usual
            let color = wire.isHovered ? wire.color.mixed(with: theme.colors.highlight, by: theme.wires.hoverLighten) : wire.color
            for index in 0..<max(wire.points.count - 1, 0) {
                segments.append(SegmentInstance(
                    color: color, a: point(wire.points[index]), b: point(wire.points[index + 1]), width: width,
                    kind: wire.kind.rawValue, along: Float(wire.lengths[index]), padding: 0
                ))
            }
        }
        counts.segments = segments.count
        if let segmentBuffer = buffer(segments) {
            var dashes = SIMD4(theme.wires.dashLength, theme.wires.dashDuty, theme.flows.dashLength, theme.flows.dashDuty)
            encoder.setRenderPipelineState(wires)
            bind(encoder, uniforms: &uniforms, buffer: segmentBuffer)
            encoder.setFragmentBytes(&dashes, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: segments.count)
        }

        // Particles under the tiles, then the tiles, then particles over them, then text.
        counts.streamed += drawStreams(snapshot.streams, encoder: encoder, uniforms: &uniforms)
        counts.particles += drawParticles(snapshot.particles, encoder: encoder, uniforms: &uniforms)
        if let tileBuffer {
            var backgroundColor = snapshot.background
            encoder.setRenderPipelineState(tiles)
            bind(encoder, uniforms: &uniforms, buffer: tileBuffer)
            encoder.setFragmentBytes(&backgroundColor, length: MemoryLayout<StageColor>.stride, index: 2)
            encoder.setVertexBytes(&tileLook, length: MemoryLayout<TileLook>.stride, index: 3)
            encoder.setFragmentBytes(&tileLook, length: MemoryLayout<TileLook>.stride, index: 3)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: tileData.count)
        }
        counts.streamed += drawStreams(snapshot.overStreams, encoder: encoder, uniforms: &uniforms)
        counts.particles += drawParticles(snapshot.overParticles, encoder: encoder, uniforms: &uniforms)
        if let plateBuffer = buffer(snapshot.labelPlates.map(RegionInstance.init)) {
            encoder.setRenderPipelineState(regions)
            bind(encoder, uniforms: &uniforms, buffer: plateBuffer)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: snapshot.labelPlates.count)
            counts.regions += snapshot.labelPlates.count
        }
        counts.glyphs = drawTexts(snapshot.texts, camera: snapshot.camera, pixelScale: pixelScale, encoder: encoder, uniforms: &uniforms)
        encoder.endEncoding()
        lastCounts = counts
    }

    private func drawStreams(_ list: [ParticleStream], encoder: MTLRenderCommandEncoder, uniforms: inout Uniforms) -> Int {
        var records: [StreamInstance] = []
        var points: [SIMD4<Float>] = []
        var total = 0
        for stream in list {
            let count = stream.count
            guard count > 0 else { continue }
            records.append(StreamInstance(
                color: stream.color, pointStart: Int32(points.count), pointCount: Int32(stream.path.points.count),
                firstInstance: Int32(total), style: stream.style.rawValue, spacing: Float(stream.spacing),
                phase: Float(stream.phase), size: Float(stream.size), length: Float(stream.path.length)
            ))
            for (point, length) in zip(stream.path.points, stream.path.lengths) {
                points.append(SIMD4(Float(point.x), Float(point.y), Float(length), 0))
            }
            total += count
        }
        guard total > 0, let recordBuffer = buffer(records), let pointBuffer = buffer(points) else { return 0 }
        uniforms.count = Int32(records.count)
        encoder.setRenderPipelineState(streams)
        bind(encoder, uniforms: &uniforms, buffer: recordBuffer)
        encoder.setVertexBuffer(pointBuffer, offset: 0, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: total)
        uniforms.count = 0
        return total
    }

    private func drawParticles(_ list: [StageParticle], encoder: MTLRenderCommandEncoder, uniforms: inout Uniforms) -> Int {
        let data = list.map { particle in
            ParticleInstance(
                color: particle.color, position: point(particle.position),
                direction: SIMD2(Float(particle.direction.dx), Float(particle.direction.dy)),
                size: Float(particle.size), style: particle.style.rawValue, fade: 1, padding: 0
            )
        }
        guard let particleBuffer = buffer(data) else { return 0 }
        encoder.setRenderPipelineState(singles)
        bind(encoder, uniforms: &uniforms, buffer: particleBuffer)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: data.count)
        return data.count
    }

    private func drawTexts(_ texts: [StageText], camera: Camera, pixelScale: CGFloat, encoder: MTLRenderCommandEncoder, uniforms: inout Uniforms) -> Int {
        var data: [GlyphInstance] = []
        for text in texts {
            let shaped = shaper.shape(text.string, font: text.font)
            let k = text.font.size / GlyphAtlas.em
            let pixelsPerTexel = Float(k * camera.scale * pixelScale)
            for glyph in shaped.glyphs {
                guard let entry = atlas.entry(for: glyph.glyph, in: glyph.font) else { continue }
                // The glyph's box, y up from its origin, turned to world units, y down.
                let origin = CGPoint(
                    x: text.origin.x + glyph.position.x + entry.origin.x * k,
                    y: text.origin.y + glyph.position.y - (entry.origin.y + entry.size.height) * k
                )
                data.append(GlyphInstance(
                    color: text.color, origin: point(origin),
                    size: SIMD2(Float(entry.size.width * k), Float(entry.size.height * k)),
                    uvMin: entry.uvMin, uvMax: entry.uvMax, pixelsPerTexel: pixelsPerTexel,
                    spread: Float(GlyphAtlas.spread), padding0: 0, padding1: 0
                ))
            }
        }
        guard let glyphBuffer = buffer(data) else { return 0 }
        encoder.setRenderPipelineState(glyphs)
        bind(encoder, uniforms: &uniforms, buffer: glyphBuffer)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: data.count)
        return data.count
    }

    private func bind(_ encoder: MTLRenderCommandEncoder, uniforms: inout Uniforms, buffer: MTLBuffer) {
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 1)
    }

    private func buffer<T>(_ items: [T]) -> MTLBuffer? {
        guard !items.isEmpty else { return nil }
        return items.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }

    private func point(_ p: CGPoint) -> SIMD2<Float> { SIMD2(Float(p.x), Float(p.y)) }

    // MARK: Images

    /// Draws `snapshot` into an image of `size` points at `pixelScale`, for tests and for looking at a stage
    /// without a window.
    public func image(of snapshot: StageSnapshot, size: CGSize, pixelScale: CGFloat = 2) -> CGImage? {
        let width = Int(size.width * pixelScale)
        let height = Int(size.height * pixelScale)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        guard let target = device.makeTexture(descriptor: descriptor),
              let readback = device.makeBuffer(length: width * height * 4, options: .storageModeShared),
              let commands = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].storeAction = .store
        encode(snapshot, into: commands, pass: pass, size: size, pixelScale: pixelScale)
        guard let blit = commands.makeBlitCommandEncoder() else { return nil }
        blit.copy(
            from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1), to: readback, destinationOffset: 0,
            destinationBytesPerRow: width * 4, destinationBytesPerImage: width * height * 4
        )
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let data = Data(bytes: readback.contents(), count: width * height * 4)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// A command buffer from the renderer's queue, for a view drawing a frame.
    public func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }
}

// The shaders' structs, laid out to match them.

struct Uniforms {
    var viewSize: SIMD2<Float>
    var center: SIMD2<Float>
    var scale: Float
    var pixelScale: Float
    var time: Float
    var count: Int32
}

/// The background's look, with the starfield's state this frame.
struct BackgroundLook {
    var background: SIMD4<Float>
    var grid: SIMD4<Float>
    var starColor: SIMD4<Float>
    var starTint: SIMD4<Float>
    var gridSpacing: Float
    var coarseGridSpacing: Float
    var gridDotRadius: Float
    var starOpacity: Float
    var starTravel: Float
    var starSpeed: Float
    var starDensity: Float
    var starCellSize: Float
    var starSize: Float
    var starBrightness: Float
    var starStreak: Float
    var starParallax: Float
    var starLayers: Int32
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0

    init(_ snapshot: StageSnapshot) {
        let canvas = snapshot.theme.canvas
        let stars = snapshot.theme.starfield
        background = canvas.background
        grid = canvas.grid
        starColor = stars.color
        starTint = stars.tint
        gridSpacing = Float(canvas.gridSpacing)
        coarseGridSpacing = Float(canvas.coarseGridSpacing)
        gridDotRadius = Float(canvas.gridDotRadius)
        starOpacity = min(max(snapshot.starOpacity, 0), 1)
        starTravel = Float(snapshot.starTravel.truncatingRemainder(dividingBy: 100))
        starSpeed = Float(snapshot.starSpeed)
        starDensity = stars.density
        starCellSize = max(stars.cellSize, 4)
        starSize = stars.starSize
        starBrightness = stars.brightness
        starStreak = stars.streak
        starParallax = stars.parallax
        starLayers = Int32(min(max(stars.layers, 1), 12))
    }
}

/// The tiles' look from the theme, shared by every tile.
struct TileLook {
    var flashColor: SIMD4<Float>
    var shadowOffset: SIMD2<Float>
    var cornerRadius: Float
    var triangleCornerRadius: Float
    var outlineWidth: Float
    var selectedOutlineScale: Float
    var faceLift: Float
    var faceTint: Float
    var sideShade: Float
    var sideTint: Float
    var sideOutlineOpacity: Float
    var edgeOpacity: Float
    var bevelInset: Float
    var bevelOpacity: Float
    var hoverGlow: Float
    var selectedGlow: Float
    var flashGlow: Float
    var glowReach: Float
    var ghostFaceOpacity: Float
    var ghostDashLength: Float
    var ghostDashDuty: Float
    var hatchSpacing: Float
    var hatchOpacity: Float
    var flatOpacity: Float
    /// How far past the tile its quad reaches, for the shadow and glow.
    var margin: Float
    var flashFaceTint: Float
    var padding0: Float = 0
    var padding1: Float = 0

    init(_ theme: Theme) {
        let tiles = theme.tiles
        let shadow = tiles.shadow
        flashColor = theme.colors.error
        shadowOffset = SIMD2(Float(shadow.offset.dx), Float(shadow.offset.dy))
        cornerRadius = tiles.cornerRadius
        triangleCornerRadius = tiles.triangleCornerRadius
        outlineWidth = tiles.outlineWidth
        selectedOutlineScale = tiles.selectedOutlineScale
        faceLift = tiles.faceLift
        faceTint = tiles.faceTint
        sideShade = tiles.sideShade
        sideTint = tiles.sideTint
        sideOutlineOpacity = tiles.sideOutlineOpacity
        edgeOpacity = tiles.edgeOpacity
        bevelInset = tiles.bevelInset
        bevelOpacity = tiles.bevelOpacity
        hoverGlow = tiles.hoverGlow
        selectedGlow = tiles.selectedGlow
        flashGlow = tiles.flashGlow
        glowReach = tiles.glowReach
        ghostFaceOpacity = tiles.ghostFaceOpacity
        ghostDashLength = max(tiles.ghostDashLength, 0.5)
        ghostDashDuty = tiles.ghostDashDuty
        hatchSpacing = shadow.hatchSpacing
        hatchOpacity = shadow.hatchOpacity
        flatOpacity = shadow.flatOpacity
        margin = max(abs(shadowOffset.x), abs(shadowOffset.y)) + tiles.glowReach * 2.2 + 2
        flashFaceTint = tiles.flashFaceTint
    }
}

struct TileInstance {
    var color: SIMD4<Float>
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var flash: Float
    var shape: Int32
    var flags: Int32
    var depth: Float

    init(_ tile: StageTile, depth: CGFloat) {
        color = tile.color
        center = SIMD2(Float(tile.frame.midX), Float(tile.frame.midY))
        halfSize = SIMD2(Float(tile.frame.width / 2), Float(tile.frame.height / 2))
        flash = tile.flash
        shape = tile.shape.rawValue
        flags = (tile.isHovered ? 1 : 0) | (tile.isSelected ? 2 : 0) | (tile.isDimmed ? 4 : 0) | (tile.isGhost ? 8 : 0)
        self.depth = Float(depth)
    }
}

struct RegionInstance {
    var fill: SIMD4<Float>
    var stroke: SIMD4<Float>
    var center: SIMD2<Float>
    var halfSize: SIMD2<Float>
    var radius: Float
    var strokeWidth: Float
    var flags: Int32
    var glow: Float

    init(_ region: StageRegion) {
        fill = region.fill
        stroke = region.stroke
        center = SIMD2(Float(region.frame.midX), Float(region.frame.midY))
        halfSize = SIMD2(Float(region.frame.width / 2), Float(region.frame.height / 2))
        radius = Float(region.cornerRadius)
        strokeWidth = region.strokeWidth
        flags = (region.isDashed ? 1 : 0) | (region.isHovered ? 2 : 0) | (region.isSelected ? 4 : 0)
        glow = region.glow
    }
}

struct SegmentInstance {
    var color: SIMD4<Float>
    var a: SIMD2<Float>
    var b: SIMD2<Float>
    var width: Float
    var kind: Int32
    var along: Float
    var padding: Float
}

struct ParticleInstance {
    var color: SIMD4<Float>
    var position: SIMD2<Float>
    var direction: SIMD2<Float>
    var size: Float
    var style: Int32
    var fade: Float
    var padding: Float
}

struct StreamInstance {
    var color: SIMD4<Float>
    var pointStart: Int32
    var pointCount: Int32
    var firstInstance: Int32
    var style: Int32
    var spacing: Float
    var phase: Float
    var size: Float
    var length: Float
}

struct GlyphInstance {
    var color: SIMD4<Float>
    var origin: SIMD2<Float>
    var size: SIMD2<Float>
    var uvMin: SIMD2<Float>
    var uvMax: SIMD2<Float>
    var pixelsPerTexel: Float
    var spread: Float
    var padding0: Float
    var padding1: Float
}

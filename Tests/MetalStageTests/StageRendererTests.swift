import ContinuumKit
import CoreGraphics
import Foundation
import ImageIO
import Metal
import MeepClient
import Simulation
import Stage
import Testing
import UniformTypeIdentifiers
@testable import MetalStage

/// Renders simulated pipelines off screen. With `SYNESTHESIA_SNAPSHOTS` set to a folder, each test also writes what
/// it drew there as a PNG, to look at.
@MainActor
@Suite(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "needs a GPU"))
struct StageRendererTests {
    let size = CGSize(width: 1100, height: 560)

    @Test(arguments: ["orders", "sensors", "warehouse"])
    func aPipelineIsDrawn(name: String) async throws {
        let renderer = try #require(StageRenderer())
        let (stage, session) = try await running(name, seconds: 2)
        defer { session.stop() }
        let snapshot = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: size)
        let image = try #require(renderer.image(of: snapshot, size: size))
        save(image, as: name)
        #expect(image.width == 2200 && image.height == 1120)
        #expect(renderer.lastCounts.tiles == snapshot.tiles.count)
        #expect(renderer.lastCounts.glyphs > 50, "labels are drawn")
        #expect(renderer.lastCounts.particles + renderer.lastCounts.streamed > 0, "particles are drawn")
        // The background is off-black, but for a few stars, and the tiles' outlines bright.
        let pixels = try #require(Pixels(image))
        #expect(pixels.brightest > 0.7)
        let corner = (0..<40).flatMap { y in (0..<40).map { x in pixels.at(x: x, y: y).max()! } }
        #expect(corner.filter { $0 < 0.12 }.count > corner.count * 9 / 10)
    }

    @Test func theStarfieldShowsWhenOnAndNotWhenOff() throws {
        let renderer = try #require(StageRenderer())
        let size = CGSize(width: 600, height: 400)
        var snapshot = StageSnapshot()
        snapshot.starTravel = 0.37
        snapshot.starSpeed = Theme.standard.starfield.speed
        snapshot.starOpacity = 1
        let on = try #require(pixels(renderer, snapshot, size: size, saveAs: "starfield"))
        snapshot.starOpacity = 0
        let off = try #require(pixels(renderer, snapshot, size: size))
        // Brighter than the grid's dots: only stars.
        #expect(on.count { $0 > 0.25 } > 20)
        #expect(off.count { $0 > 0.25 } == 0)
    }

    @Test func aFlatShadowAndOtherTileLooksComeFromTheTheme() async throws {
        let renderer = try #require(StageRenderer())
        let (stage, session) = try await running("orders", seconds: 0.3)
        defer { session.stop() }
        var snapshot = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: size)
        snapshot.starOpacity = 0
        let standard = try #require(pixels(renderer, snapshot, size: size))
        snapshot.theme.tiles.shadow.hatchSpacing = 0
        snapshot.theme.tiles.shadow.flatOpacity = 0.6
        snapshot.theme.tiles.shadow.offset = CGVector(dx: 14, dy: 14)
        let flat = try #require(pixels(renderer, snapshot, size: size, saveAs: "orders-flat-shadows"))
        #expect(standard.bytes != flat.bytes)
    }

    @Test func zoomedInTextStaysSharp() async throws {
        let renderer = try #require(StageRenderer())
        let (stage, session) = try await running("ticker", seconds: 0.5)
        defer { session.stop() }
        _ = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: size)
        stage.zoom(by: 3, at: CGPoint(x: size.width / 2, y: size.height / 2))
        let snapshot = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: size)
        let image = try #require(renderer.image(of: snapshot, size: size))
        save(image, as: "ticker-zoomed")
        #expect(renderer.lastCounts.glyphs > 10)
    }

    @Test func distanceFieldsAreSignedFromTheOutline() {
        // A 9×9 square of ink in a 21×21 field.
        var coverage = [UInt8](repeating: 0, count: 21 * 21)
        for y in 6..<15 { for x in 6..<15 { coverage[y * 21 + x] = 255 } }
        let field = GlyphAtlas.distanceField(coverage, width: 21, height: 21, spread: 5)
        #expect(field[10 * 21 + 10] > 200, "deep inside")
        #expect(field[0] == 0, "far outside")
        let edgeInside = Int(field[10 * 21 + 6])
        let edgeOutside = Int(field[10 * 21 + 5])
        #expect(edgeInside > 127 && edgeOutside < 128)
    }

    // MARK: Helpers

    private func running(_ name: String, seconds: Double) async throws -> (PipelineStage, HostSession) {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", kind: .simulated)
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let session = HostSession(host: host, settings: .init(statsEvery: .milliseconds(40), watchedStatsEvery: .milliseconds(40), listEvery: .milliseconds(40))) { link }
        session.start()
        while host.pipeline(name)?.links.first?.isCounted != true {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stage = PipelineStage(pipeline: host.pipeline(name)!, host: host)
        let start = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - start < seconds {
            _ = stage.frame(at: ProcessInfo.processInfo.systemUptime, viewSize: size)
            try await Task.sleep(for: .milliseconds(16))
        }
        return (stage, session)
    }

    private func pixels(_ renderer: StageRenderer, _ snapshot: StageSnapshot, size: CGSize, saveAs name: String? = nil) -> Pixels? {
        guard let image = renderer.image(of: snapshot, size: size) else { return nil }
        if let name { save(image, as: name) }
        return Pixels(image)
    }

    private func save(_ image: CGImage, as name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SYNESTHESIA_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

/// An image's pixels, as red, green and blue from 0 to 1.
struct Pixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init?(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { return nil }
        self.bytes = bytes
    }

    func at(x: Int, y: Int) -> [Double] {
        let index = (y * width + x) * 4
        return (0..<3).map { Double(bytes[index + $0]) / 255 }
    }

    /// How many pixels' brightest channel passes `test`.
    func count(where test: (Double) -> Bool) -> Int {
        stride(from: 0, to: bytes.count, by: 4).filter { test(Double(max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])) / 255) }.count
    }

        var brightest: Double {
        stride(from: 0, to: bytes.count, by: 4).map { Double(max(bytes[$0], bytes[$0 + 1], bytes[$0 + 2])) / 255 }.max() ?? 0
    }
}

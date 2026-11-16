import ContinuumKit
import CoreGraphics
import Foundation
import ImageIO
import Simulation
import Stage
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import SynesthesiaUI

/// Renders the hover cards off screen. With `SYNESTHESIA_SNAPSHOTS` set to a folder, each is saved there as a PNG.
@MainActor
struct HoverCardTests {
    @Test func aModulesCardShowsItsCountsAndWhereItsWritten() async throws {
        let (stage, session) = try await stage(for: "orders")
        defer { session.stop() }
        let image = try #require(render(HoverCard(hit: .tile("m2"), stage: stage)))
        save(image, as: "card-module")
        #expect(image.width > 200 && image.height > 150)
    }

    @Test func aWiresCardSaysWhatItsParticlesMean() async throws {
        let (stage, session) = try await stage(for: "orders")
        defer { session.stop() }
        let image = try #require(render(HoverCard(hit: .wire("m1>m2"), stage: stage)))
        save(image, as: "card-wire")
        #expect(image.width > 200)
    }

    private func stage(for name: String) async throws -> (PipelineStage, HostSession) {
        let continuum = Continuum()
        let host = continuum.add(host: "sim", kind: .simulated)
        let link = SimulatedHost(name: "sim", latency: .milliseconds(1))
        let session = HostSession(host: host, settings: .init(statsEvery: .milliseconds(40), listEvery: .milliseconds(40))) { link }
        session.start()
        while host.pipeline(name)?.links.first?.isCounted != true || (host.pipeline(name)?.modules.first?.rates[.emitted] ?? 0) == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        return (PipelineStage(pipeline: host.pipeline(name)!, host: host), session)
    }

    private func render(_ view: some View) -> CGImage? {
        let renderer = ImageRenderer(content: view.fixedSize().padding(8).background(Color(white: 0.2)))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func save(_ image: CGImage, as name: String) {
        guard let folder = ProcessInfo.processInfo.environment["SYNESTHESIA_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name).png")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}

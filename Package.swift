// swift-tools-version: 6.0
// Synesthesia: the Mac app, and the core it's built on. The core's targets import neither AppKit nor UIKit, so the
// iPad and iPhone versions can share them; only SynesthesiaMac is the Mac's. See docs/Design/architecture-round-1.md,
// section 9. Build the app with scripts/build-app.sh.

import PackageDescription

let package = Package(
    name: "Synesthesia",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "Transport", targets: ["Transport"]),
        .library(name: "MeepClient", targets: ["MeepClient"]),
        .library(name: "FlowKit", targets: ["FlowKit"]),
        .library(name: "ContinuumKit", targets: ["ContinuumKit"]),
        .library(name: "Simulation", targets: ["Simulation"]),
        .library(name: "LayoutKit", targets: ["LayoutKit"]),
        .library(name: "Stage", targets: ["Stage"]),
        .library(name: "MetalStage", targets: ["MetalStage"]),
        .library(name: "SynesthesiaUI", targets: ["SynesthesiaUI"]),
        .executable(name: "SynesthesiaMac", targets: ["SynesthesiaMac"]),
    ],
    targets: [
        // Byte streams over Unix sockets (and later TCP with TLS and tunnels), and WebSockets on top of them.
        .target(name: "Transport"),
        // The Meep daemon's API: its contracts, and one WebSocket carrying every request and stream.
        .target(name: "MeepClient", dependencies: ["Transport"]),
        // Rates from cumulative counts; later digests, history, the playout clock and the subscription planner.
        .target(name: "FlowKit"),
        // The Continuum: hosts, pipelines and modules, their addresses, and keeping them up to date.
        .target(name: "ContinuumKit", dependencies: ["MeepClient", "FlowKit"]),
        // Pretend hosts, for tests and for building the host and mesh levels without real machines.
        .target(name: "Simulation", dependencies: ["MeepClient"]),
        // Layouts in Swift (Q3): layered for a pipeline; later packing, force and edge layouts, and pins.
        .target(name: "LayoutKit"),
        // The scene the canvas draws, independent of the renderer: tiles, wires, text, particles, the camera and
        // hit-testing, built from the model.
        .target(name: "Stage", dependencies: ["ContinuumKit", "LayoutKit", "FlowKit", "MeepClient"]),
        // The Metal renderer of the stage, shared by the Mac and iPad.
        .target(name: "MetalStage", dependencies: ["Stage"]),
        // SwiftUI shared by the Mac and iPad apps.
        .target(name: "SynesthesiaUI", dependencies: ["ContinuumKit", "Stage"]),
        // The Mac app: its windows, menus and the hosts it starts with.
        .executableTarget(name: "SynesthesiaMac", dependencies: ["SynesthesiaUI", "ContinuumKit", "MeepClient", "Simulation", "Stage", "MetalStage"]),

        .testTarget(name: "TransportTests", dependencies: ["Transport"]),
        .testTarget(name: "MeepClientTests", dependencies: ["MeepClient"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FlowKitTests", dependencies: ["FlowKit"]),
        .testTarget(name: "ContinuumKitTests", dependencies: ["ContinuumKit", "Simulation"]),
        .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit"]),
        .testTarget(name: "StageTests", dependencies: ["Stage", "ContinuumKit", "Simulation", "MeepClient"]),
        .testTarget(name: "MetalStageTests", dependencies: ["MetalStage", "Stage", "ContinuumKit", "Simulation", "MeepClient"]),
        .testTarget(name: "SynesthesiaUITests", dependencies: ["SynesthesiaUI", "Stage", "ContinuumKit", "Simulation", "MeepClient"]),
    ]
)

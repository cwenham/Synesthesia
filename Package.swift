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
        .library(name: "Assistant", targets: ["Assistant"]),
        .library(name: "LanguageClient", targets: ["LanguageClient"]),
        .library(name: "CodeEditing", targets: ["CodeEditing"]),
        .executable(name: "SynesthesiaMac", targets: ["SynesthesiaMac"]),
        .executable(name: "synesthesia-mcp", targets: ["SynesthesiaMCPBridge"]),
    ],
    targets: [
        // Byte streams over Unix sockets (and later TCP with TLS and tunnels), and WebSockets on top of them.
        .target(name: "Transport"),
        // The Meep daemon's API: its contracts, and one WebSocket carrying every request and stream.
        .target(name: "MeepClient", dependencies: ["Transport"]),
        // Rates from cumulative counts, handling-time histograms and the subscription planner; later history and the
        // playout clock.
        .target(name: "FlowKit"),
        // The Continuum: hosts, pipelines and modules, their addresses, and keeping them up to date.
        .target(name: "ContinuumKit", dependencies: ["MeepClient", "FlowKit", "Transport"]),
        // Pretend hosts, for tests and for building the host and mesh levels without real machines.
        .target(name: "Simulation", dependencies: ["MeepClient"]),
        // meep lsp: the Language Server Protocol, with Meep's additions (the graph, keys shared with the daemon, the
        // verb catalogue), and starting it on the Mac.
        .target(name: "LanguageClient", dependencies: ["Transport", "MeepClient"]),
        // A pipeline's Meeplang as it's edited: its text, colours, problems and graph from meep lsp, with keys that
        // agree with the daemon's, and what the gutter shows. The text view itself is the platform's.
        .target(name: "CodeEditing", dependencies: ["LanguageClient", "ContinuumKit", "MeepClient", "FlowKit"]),
        // Layouts in Swift (Q3): layered for a pipeline; later packing, force and edge layouts, and pins.
        .target(name: "LayoutKit"),
        // The scene the canvas draws, independent of the renderer: tiles, wires, text, particles, the camera and
        // hit-testing, built from the model.
        .target(name: "Stage", dependencies: ["ContinuumKit", "LayoutKit", "FlowKit", "MeepClient"]),
        // The Metal renderer of the stage, shared by the Mac and iPad.
        // Optimised even in debug builds: drawing each glyph's distance field takes seconds unoptimised, on the main
        // thread, which stalls the canvas the first time it draws and every test running beside the renderer's.
        .target(name: "MetalStage", dependencies: ["Stage"], swiftSettings: [.unsafeFlags(["-O"], .when(configuration: .debug))]),
        // The tools Claude uses, written once (design, section 8), the MCP server that offers them, and the Claude API
        // client and tool loop the sidebar uses.
        .target(name: "Assistant", dependencies: ["ContinuumKit", "Stage", "FlowKit", "MeepClient", "Transport", "CodeEditing", "LanguageClient"]),
        // SwiftUI shared by the Mac and iPad apps, the Claude sidebar among it.
        .target(name: "SynesthesiaUI", dependencies: ["ContinuumKit", "Stage", "CodeEditing", "LanguageClient", "MeepClient", "FlowKit", "Transport", "Assistant"]),
        // The Mac app: its windows, menus and the hosts it starts with.
        .executableTarget(name: "SynesthesiaMac", dependencies: ["SynesthesiaUI", "ContinuumKit", "MeepClient", "Simulation", "Stage", "MetalStage", "Assistant", "Transport", "CodeEditing", "LanguageClient"]),
        // synesthesia-mcp, in the app bundle: joins an MCP client's standard input and output to the app's socket.
        .executableTarget(name: "SynesthesiaMCPBridge", dependencies: ["Transport"]),

        // What the test targets share: the gate that keeps only a few tests running simulated hosts at once.
        .target(name: "TestSupport", path: "Tests/TestSupport"),

        .testTarget(name: "TransportTests", dependencies: ["Transport"]),
        .testTarget(name: "LanguageClientTests", dependencies: ["LanguageClient", "Transport", "MeepClient"], resources: [.copy("Fixtures")]),
        .testTarget(name: "CodeEditingTests", dependencies: ["TestSupport", "CodeEditing", "LanguageClient", "ContinuumKit", "Simulation", "MeepClient", "Transport", "FlowKit"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MeepClientTests", dependencies: ["MeepClient"], resources: [.copy("Fixtures")]),
        .testTarget(name: "FlowKitTests", dependencies: ["FlowKit"]),
        .testTarget(name: "ContinuumKitTests", dependencies: ["TestSupport", "ContinuumKit", "Simulation", "MeepClient", "FlowKit", "Transport"]),
        .testTarget(name: "LayoutKitTests", dependencies: ["LayoutKit"]),
        .testTarget(name: "StageTests", dependencies: ["TestSupport", "Stage", "ContinuumKit", "Simulation", "MeepClient"]),
        .testTarget(name: "MetalStageTests", dependencies: ["TestSupport", "MetalStage", "Stage", "ContinuumKit", "Simulation", "MeepClient"]),
        .testTarget(name: "AssistantTests", dependencies: ["TestSupport", "Assistant", "ContinuumKit", "Simulation", "Stage", "Transport", "MeepClient", "CodeEditing", "LanguageClient"], resources: [.copy("Fixtures")]),
        .testTarget(name: "SynesthesiaUITests", dependencies: ["TestSupport", "SynesthesiaUI", "Stage", "ContinuumKit", "Simulation", "MeepClient", "LanguageClient", "CodeEditing", "Assistant"]),
    ]
)

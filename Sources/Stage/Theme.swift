import CoreGraphics
import MeepClient

/// How the canvas looks: every colour, size, shape and effect the stage and its renderer draw with, in one value.
///
/// Nothing the canvas draws should have its look written anywhere else. The stage reads ``current`` each frame and
/// hands it to the renderer in the snapshot, so changing it changes the canvas at once; a change to the tiles' or
/// labels' sizes lays the pipeline out again. A theme is `Codable`, so themes the person makes can later be saved,
/// shared and loaded as JSON; ``standard`` is the look from the design's theme notes: bright wireframe colours on an
/// off-black background, tiles with depth like Mahjong tiles, and hatched shadows.
public struct Theme: Sendable, Equatable, Codable {
    public var name: String
    public var canvas: Canvas
    public var starfield: Starfield
    public var roles: Roles
    public var colors: Colors
    public var tiles: Tiles
    public var wires: Wires
    public var particles: Particles
    public var labels: Labels
    /// Hosts and pipelines as the Continuum draws them, zoomed out.
    public var continuum: ContinuumLook
    /// Flows between pipelines and hosts, and the boundary's endpoints.
    public var flows: FlowLook

    public init(
        name: String, canvas: Canvas, starfield: Starfield, roles: Roles, colors: Colors, tiles: Tiles, wires: Wires,
        particles: Particles, labels: Labels, continuum: ContinuumLook = .standard, flows: FlowLook = .standard
    ) {
        self.continuum = continuum
        self.flows = flows
        self.name = name
        self.canvas = canvas
        self.starfield = starfield
        self.roles = roles
        self.colors = colors
        self.tiles = tiles
        self.wires = wires
        self.particles = particles
        self.labels = labels
    }

    /// The theme the canvas draws with now. The app sets it, with the person's settings applied.
    @MainActor public static var current = Theme.standard

    // MARK: Parts

    /// The ground everything is drawn on.
    public struct Canvas: Sendable, Equatable, Codable {
        public var background: StageColor
        /// The faint dots of the grid behind everything.
        public var grid: StageColor
        /// The grid's spacing, in world units, close up and far out; the fine grid gives way to the coarse one as
        /// you zoom out.
        public var gridSpacing: CGFloat
        public var coarseGridSpacing: CGFloat
        /// The grid dots' radius, in points.
        public var gridDotRadius: CGFloat
    }

    /// Stars drifting toward the viewer behind the grid, as if the canvas were travelling forward through space.
    public struct Starfield: Sendable, Equatable, Codable {
        public var isOn: Bool
        /// How fast the canvas travels: each star's journey from far away to past the viewer takes 1 / speed seconds.
        public var speed: Double
        /// How many cells of the sky hold a star, from 0 to 1.
        public var density: Float
        /// The size of a sky cell, in points: larger cells spread the stars further apart.
        public var cellSize: Float
        /// How many layers of stars are in flight at once, from far to near.
        public var layers: Int
        /// A star's radius when nearest, in points.
        public var starSize: Float
        /// How bright the nearest stars are, from 0 to 1.
        public var brightness: Float
        /// The stars' colour, and a second they're tinted toward at random, for variety.
        public var color: StageColor
        public var tint: StageColor
        /// How long near stars streak toward the edges, as a multiple of their size, for each unit of speed: at the
        /// standard speed of 0.04, a streak of 50 draws near stars three times as long as they're wide.
        public var streak: Float
        /// How far the stars shift as the canvas is panned, against the grid's 1: small, so they seem far away.
        public var parallax: Float
    }

    /// How a role's modules look.
    public struct RoleStyle: Sendable, Equatable, Codable {
        public var color: StageColor
        /// The tile's outline, its symbol.
        public var shape: TileShape
    }

    /// Each role's colour and symbol.
    public struct Roles: Sendable, Equatable, Codable {
        public var source: RoleStyle
        public var inlet: RoleStyle
        public var filter: RoleStyle
        public var step: RoleStyle
        public var outlet: RoleStyle
        /// A module whose verb's role isn't known.
        public var unknown: RoleStyle

        public subscript(role: VerbRole?) -> RoleStyle {
            switch role {
            case .source: source
            case .inlet: inlet
            case .filter: filter
            case .step: step
            case .outlet: outlet
            case nil: unknown
            }
        }
    }

    /// Colours for states and what happens to messages, apart from the roles'.
    public struct Colors: Sendable, Equatable, Codable {
        /// Errors, failures, and a module a proposal would take out.
        public var error: StageColor
        public var dropped: StageColor
        public var expired: StageColor
        /// Greyed: a pipeline that has ended, or a host that can't be reached.
        public var dimmed: StageColor
        /// A module written in lines being mended, while the text doesn't load; unlike any role's colour.
        public var editing: StageColor
        /// What a proposal would add or change, waiting for the person to accept it; unlike any role's colour.
        public var proposed: StageColor
        /// What hovered things and particles are lightened toward.
        public var highlight: StageColor
        public var title: StageColor
        public var detail: StageColor
    }

    /// The tiles: their sizes, depth, outline, face, glow and shadow.
    public struct Tiles: Sendable, Equatable, Codable {
        /// All tiles are as tall, so wires between them run straight.
        public var height: CGFloat
        /// A rectangle's width; a circle's is its height.
        public var rectangleWidth: CGFloat
        /// The width of the triangles: filters, inlets and outlets.
        public var triangleWidth: CGFloat
        /// How far a tile's side shows below its face.
        public var depth: CGFloat
        public var cornerRadius: Float
        /// The most a triangle's corners are rounded; small triangles are rounded less.
        public var triangleCornerRadius: Float
        /// The outline's width, in pixels at 1×.
        public var outlineWidth: Float
        /// How much thicker a selected tile's outline is.
        public var selectedOutlineScale: Float
        /// The face's colour: the background's, brightened by this much, with this much of the role's colour.
        public var faceLift: Float
        public var faceTint: Float
        /// The side's colour: the background's, darkened to this much, with this much of the role's colour.
        public var sideShade: Float
        public var sideTint: Float
        public var sideOutlineOpacity: Float
        /// The line where the face meets the side.
        public var edgeOpacity: Float
        /// The bevel: a faint second outline this far inside the face's.
        public var bevelInset: Float
        public var bevelOpacity: Float
        /// The glow round a tile, by why it glows, and how far it reaches in world units.
        public var hoverGlow: Float
        public var selectedGlow: Float
        public var flashGlow: Float
        public var glowReach: Float
        /// How long a failure's red flash takes to fade, in seconds.
        public var flashSeconds: Double
        /// How much of the error colour a failing tile's face takes on, at the flash's height.
        public var flashFaceTint: Float
        /// A tile not running yet: its face's opacity, and its outline's dashes, in world units.
        public var ghostFaceOpacity: Float
        public var ghostDashLength: Float
        /// Of each dash's length, how much is drawn.
        public var ghostDashDuty: Float
        public var shadow: Shadow
        /// The height over which a tile's inputs spread down its left side, and the least room between two.
        public var inputSpan: CGFloat
        public var inputSpacing: CGFloat

        /// The tile's size for a shape.
        public func size(for shape: TileShape) -> CGSize {
            switch shape {
            case .rectangle: CGSize(width: rectangleWidth, height: height)
            case .circle: CGSize(width: height, height: height)
            case .filter, .send, .receive: CGSize(width: triangleWidth, height: height)
            }
        }
    }

    /// The shadow a tile casts: hatched in its role's colour, or a flat tint when the hatching's spacing is 0.
    public struct Shadow: Sendable, Equatable, Codable {
        /// Where it falls, from the tile, in world units.
        public var offset: CGVector
        /// The distance between hatching lines, in world units; 0 for a flat shadow.
        public var hatchSpacing: Float
        public var hatchOpacity: Float
        /// The shadow's opacity where its lines are too close to see, or when it's flat.
        public var flatOpacity: Float
    }

    /// The wires between tiles.
    public struct Wires: Sendable, Equatable, Codable {
        /// Dim, so their particles stand out.
        public var color: StageColor
        public var errorColor: StageColor
        /// Widths in pixels at 1×.
        public var width: Float
        public var hoveredWidth: Float
        /// How far a hovered wire is lightened toward the highlight.
        public var hoverLighten: Float
        /// A wire going back against the flow is dashed: its dashes' length in world units, and how much is drawn.
        public var dashLength: Float
        public var dashDuty: Float
    }

    /// Particles: messages, rates, queues, probes and real messages. Sizes are radii in world units.
    public struct Particles: Sendable, Equatable, Codable {
        /// How far particles are lightened from their module's colour toward the highlight.
        public var lighten: Float
        public var messageSize: CGFloat
        public var streamSize: CGFloat
        public var queuedSize: CGFloat
        public var probeMarkSize: CGFloat
        public var tracerSize: CGFloat
        public var injectedSize: CGFloat
        /// A message sent in by the person.
        public var injected: StageColor
        /// The probes' colours, distinct from the roles', in the order probes take them.
        public var probeColors: [StageColor]

        public func probeColor(_ index: Int) -> StageColor {
            guard !probeColors.isEmpty else { return injected }
            return probeColors[((index % probeColors.count) + probeColors.count) % probeColors.count]
        }
    }

    /// The label under each tile.
    public struct Labels: Sendable, Equatable, Codable {
        public var titleFont: StageFont
        public var detailFont: StageFont
        public var rateFont: StageFont
        /// From the bottom of a tile's side to its label's first baseline.
        public var gap: CGFloat
        /// The second and third lines' baselines, from the line above's.
        public var detailLineHeight: CGFloat
        public var noteLineHeight: CGFloat
        /// Room for the label under a tile.
        public var height: CGFloat
        /// Longer labels are cut short; the label is at least this wide.
        public var maxWidth: CGFloat
        public var minWidth: CGFloat
        /// Text smaller than this on screen, in points, isn't drawn.
        public var smallestTitle: CGFloat
        public var smallestDetail: CGFloat
    }
}

/// How the Continuum looks zoomed out (design, section 2): each host a plate with its pipelines as districts on it,
/// and from further out each host a node of the mesh.
public struct ContinuumLook: Sendable, Equatable, Codable {
    public var hostFill: StageColor
    public var hostStroke: StageColor
    /// A host that can't be reached: its plate dashed and greyed.
    public var unreachable: StageColor
    public var districtFill: StageColor
    public var districtStroke: StageColor
    /// A pipeline's plate by how busy it is, from idle through busy to its limit: cool to hot.
    public var cool: StageColor
    public var warm: StageColor
    public var hot: StageColor
    /// Meters: the spare share of a host's cores, and their track.
    public var spare: StageColor
    public var meterTrack: StageColor
    /// Fonts in points: they keep their size on screen at every zoom.
    public var hostTitleFont: StageFont
    public var titleFont: StageFont
    public var detailFont: StageFont
    /// Corners, room and gaps, in world units.
    public var hostCorner: CGFloat
    public var districtCorner: CGFloat
    public var districtPadding: CGFloat
    public var districtHeader: CGFloat
    public var hostPadding: CGFloat
    public var hostHeader: CGFloat
    public var districtGap: CGFloat
    public var hostGap: CGFloat
    /// Tiles are drawn from this zoom in; further out, a pipeline is its plate.
    public var tilesFrom: CGFloat
    /// When hosts are narrower than this on screen on average, in points, they become nodes of the mesh, all at once.
    public var nodeBelow: CGFloat
    /// A node's size on screen, in points.
    public var nodeSize: CGFloat

    public static let standard = ContinuumLook(
        hostFill: StageColor(hex: 0x1A1D24, alpha: 0.72), hostStroke: StageColor(hex: 0x5B6AA0), unreachable: StageColor(hex: 0x4A4E58),
        districtFill: StageColor(hex: 0x20242D, alpha: 0.85), districtStroke: StageColor(hex: 0x3C4457),
        cool: StageColor(hex: 0x39D5FF), warm: StageColor(hex: 0xFFC23D), hot: StageColor(hex: 0xFF4D5E),
        spare: StageColor(hex: 0x6CFF8E), meterTrack: StageColor(hex: 0x2A2F3A),
        hostTitleFont: StageFont(size: 17, weight: .semibold), titleFont: StageFont(size: 14, weight: .semibold),
        detailFont: StageFont(size: 11.5, weight: .medium, monospacedDigits: true),
        hostCorner: 40, districtCorner: 22, districtPadding: 36, districtHeader: 76, hostPadding: 70, hostHeader: 70,
        districtGap: 80, hostGap: 520, tilesFrom: 0.11, nodeBelow: 120, nodeSize: 56
    )

    /// A plate's colour for a load from 0 (idle) to 1 (at its limit).
    public func heat(_ load: Double) -> StageColor {
        let t = Float(min(max(load, 0), 1))
        return t < 0.5 ? cool.mixed(with: warm, by: t * 2) : warm.mixed(with: hot, by: (t - 0.5) * 2)
    }
}

/// How flows between pipelines and the boundary look (design, section 3): flows seen solid and declared ones dashed,
/// endpoints outside Meep round the edge in the colours of the roles that meet them, sizes in points so they read at
/// every zoom.
public struct FlowLook: Sendable, Equatable, Codable {
    /// A flow that's been seen, and one only declared.
    public var observed: StageColor
    public var declared: StageColor
    /// Traffic into the Continuum, from clients to Listens, and out of it, from Fetches and Sends.
    public var inbound: StageColor
    public var outbound: StageColor
    /// Another Meep Synesthesia doesn't follow, and everything past modules' limits.
    public var otherMeep: StageColor
    public var pastLimit: StageColor
    /// The Continuum's edge, drawn round the mesh.
    public var region: StageColor
    /// Widths in pixels at 1×: the least, and the most a busy flow grows to.
    public var width: Float
    public var widest: Float
    /// A declared flow's dashes, in pixels at 1×, and how much of each is drawn.
    public var dashLength: Float
    public var dashDuty: Float
    /// An endpoint's marker on screen, in points.
    public var endpointSize: CGFloat
    /// How far beyond the mesh the boundary's endpoints sit, in world units.
    public var ringMargin: CGFloat
    /// Fonts in points, keeping their size on screen.
    public var labelFont: StageFont
    public var detailFont: StageFont
    public var groupFont: StageFont

    public static let standard = FlowLook(
        observed: StageColor(hex: 0x9FE7FF), declared: StageColor(hex: 0x8C93A3), inbound: StageColor(hex: 0x7C8CFF),
        outbound: StageColor(hex: 0x6CFF8E), otherMeep: StageColor(hex: 0xFFC23D), pastLimit: StageColor(hex: 0x8C93A3),
        region: StageColor(hex: 0x5B6AA0), width: 1.6, widest: 6, dashLength: 7, dashDuty: 0.55, endpointSize: 18, ringMargin: 900,
        labelFont: StageFont(size: 13, weight: .semibold), detailFont: StageFont(size: 11, weight: .medium, monospacedDigits: true),
        groupFont: StageFont(size: 12, weight: .medium)
    )

    /// A flow's width for `rate` messages a second: wider with the log of the rate, so ten times the traffic is a
    /// step wider without swamping the rest.
    public func width(for rate: Double) -> Float {
        min(widest, width + 1.1 * Float(log10(1 + max(rate, 0))))
    }
}

// MARK: The standard theme

extension Theme {
    public static let standard = Theme(
        name: "Standard",
        canvas: Canvas(
            background: StageColor(hex: 0x111216), grid: StageColor(hex: 0x23262E), gridSpacing: 24, coarseGridSpacing: 120,
            gridDotRadius: 1
        ),
        starfield: Starfield(
            isOn: true, speed: 0.04, density: 0.42, cellSize: 54, layers: 6, starSize: 1.4, brightness: 0.7,
            color: StageColor(hex: 0xDCE6FF), tint: StageColor(hex: 0xFFE2B8), streak: 50, parallax: 0.04
        ),
        roles: Roles(
            source: RoleStyle(color: StageColor(hex: 0x39D5FF), shape: .circle), // cyan
            inlet: RoleStyle(color: StageColor(hex: 0x7C8CFF), shape: .receive), // periwinkle
            filter: RoleStyle(color: StageColor(hex: 0xFF52D9), shape: .filter), // magenta
            step: RoleStyle(color: StageColor(hex: 0xFFC23D), shape: .rectangle), // amber
            outlet: RoleStyle(color: StageColor(hex: 0x6CFF8E), shape: .send), // green
            unknown: RoleStyle(color: StageColor(hex: 0xB8BCC6), shape: .rectangle)
        ),
        colors: Colors(
            error: StageColor(hex: 0xFF4D5E), dropped: StageColor(hex: 0xFF9A3D), expired: StageColor(hex: 0x8A8F9C),
            dimmed: StageColor(hex: 0x4A4E58), editing: StageColor(hex: 0xF4F6FA), proposed: StageColor(hex: 0xB98CFF),
            highlight: StageColor(hex: 0xFFFFFF), title: StageColor(hex: 0xE8EBF0), detail: StageColor(hex: 0x8C93A3)
        ),
        tiles: Tiles(
            height: 52, rectangleWidth: 108, triangleWidth: 62, depth: 6, cornerRadius: 10, triangleCornerRadius: 7,
            outlineWidth: 1.6, selectedOutlineScale: 1.8, faceLift: 1.35, faceTint: 0.07, sideShade: 0.7, sideTint: 0.05,
            sideOutlineOpacity: 0.55, edgeOpacity: 0.22, bevelInset: 4, bevelOpacity: 0.24,
            hoverGlow: 0.30, selectedGlow: 0.55, flashGlow: 0.9, glowReach: 7, flashSeconds: 0.7, flashFaceTint: 0.18,
            ghostFaceOpacity: 0.85, ghostDashLength: 9, ghostDashDuty: 0.55,
            shadow: Shadow(offset: CGVector(dx: 6, dy: 7), hatchSpacing: 4.5, hatchOpacity: 0.42, flatOpacity: 0.12),
            inputSpan: 28, inputSpacing: 14
        ),
        wires: Wires(
            color: StageColor(hex: 0x3A4254), errorColor: StageColor(hex: 0x6B2C36), width: 1.6, hoveredWidth: 2.8,
            hoverLighten: 0.35, dashLength: 12, dashDuty: 0.55
        ),
        particles: Particles(
            lighten: 0.35, messageSize: 2.6, streamSize: 1.7, queuedSize: 2.1, probeMarkSize: 5.5, tracerSize: 3.6,
            injectedSize: 4.2, injected: StageColor(hex: 0xFFFFFF),
            probeColors: [
                StageColor(hex: 0xFFFFFF), StageColor(hex: 0xFFE27A), StageColor(hex: 0x9CF0FF), StageColor(hex: 0xFFB0E6),
                StageColor(hex: 0xB9FFB0),
            ]
        ),
        labels: Labels(
            titleFont: StageFont(size: 13, weight: .semibold), detailFont: StageFont(size: 11),
            rateFont: StageFont(size: 11, weight: .medium, monospacedDigits: true),
            gap: 20, detailLineHeight: 15, noteLineHeight: 14, height: 52, maxWidth: 180, minWidth: 64,
            smallestTitle: 4.5, smallestDetail: 5.5
        )
    )

    /// What decides where tiles go: when it changes, the pipeline is laid out again.
    var layoutMetrics: LayoutMetrics {
        LayoutMetrics(tiles: tiles, labels: labels, shapes: [roles.source, roles.inlet, roles.filter, roles.step, roles.outlet, roles.unknown].map(\.shape))
    }

    struct LayoutMetrics: Equatable {
        var tiles: Tiles
        var labels: Labels
        var shapes: [TileShape]
    }
}

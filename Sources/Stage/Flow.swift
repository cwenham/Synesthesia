import CoreGraphics
import Foundation

/// The particles for one count along one path, such as the messages a wire carries, or what a filter holds back.
///
/// While the rate is low, one particle is one message: each rise in the count starts that many particles, spread
/// over the time the rise took, so they don't arrive in clumps. Above a few a second, particles show the rate
/// instead: a stream whose density grows with the log of the rate, so ten times the traffic looks busier without
/// filling the wire. The two look different (design, section 4: particles are honest).
public struct Flow: Sendable {
    /// At this rate a second and above, particles show the rate.
    public static let rateAbove: Double = 5
    /// Below this, they're single messages again; the gap keeps them from flickering between the two.
    public static let messagesBelow: Double = 3
    /// How fast a single message travels, in world units a second.
    public static let messageSpeed: CGFloat = 130
    /// The most single particles one rise starts.
    static let mostAtOnce = 40

    /// Whether particles show the rate rather than single messages.
    public private(set) var showsRate = false
    /// How far along the stream's first particle is.
    public private(set) var phase: CGFloat = 0
    /// When each single particle set off, oldest first.
    public private(set) var travelling: [Double] = []
    private var waiting: [Double] = []
    private var lastCount: Int64?
    private var lastRise: Double?

    public init() {}

    /// Takes the cumulative count and its rate at `time`; a rise starts single particles.
    public mutating func observe(_ count: Int64, rate: Double, at time: Double) {
        if showsRate, rate < Self.messagesBelow {
            showsRate = false
        } else if !showsRate, rate >= Self.rateAbove {
            showsRate = true
            waiting.removeAll()
        }
        guard let last = lastCount else {
            // The first reading is where counting starts; what came before isn't drawn.
            lastCount = count
            lastRise = time
            return
        }
        if count < last {
            // The pipeline started again, counting from zero.
            lastCount = count
            lastRise = time
            return
        }
        guard count > last else { return }
        let added = Int(min(count - last, Int64(Self.mostAtOnce)))
        let took = min(max(time - (lastRise ?? time), 0.15), 1.5)
        lastCount = count
        lastRise = time
        guard !showsRate else { return }
        for index in 0..<added {
            waiting.append(time + took * Double(index) / Double(added))
        }
    }

    /// Moves everything on to `time`: starts particles whose time has come, ends those past `length`, and moves the
    /// stream on at `rate`.
    public mutating func advance(to time: Double, by elapsed: Double, rate: Double, length: CGFloat) {
        while let first = waiting.first, first <= time {
            travelling.append(waiting.removeFirst())
        }
        travelling.removeAll { CGFloat(time - $0) * Self.messageSpeed > length }
        if showsRate {
            let spacing = Self.spacing(for: rate)
            phase = (phase + Self.streamSpeed(for: rate) * CGFloat(elapsed)).truncatingRemainder(dividingBy: spacing)
        }
    }

    /// Forgets everything, as when counts stop being current.
    public mutating func stop() {
        waiting.removeAll()
        travelling.removeAll()
        showsRate = false
        lastCount = nil
    }

    /// Distance between a stream's particles, in world units: about 30 at the switch, closing to 7 at a million a
    /// second.
    public static func spacing(for rate: Double) -> CGFloat {
        let density = min(max(2.5 + 3.5 * log10(max(rate, 1) / messagesBelow), 2.5), 14)
        return 100 / CGFloat(density)
    }

    /// How fast a stream moves, a little faster as the rate grows.
    public static func streamSpeed(for rate: Double) -> CGFloat {
        messageSpeed * CGFloat(1 + 0.25 * min(max(log10(max(rate, 1) / rateAbove), 0), 5))
    }

    /// The flow's particles on `path`: a stream while it shows the rate, and the single particles still travelling.
    public func draw(
        on path: StageWire, rate: Double, at time: Double, color: StageColor, sizes: Theme.Particles = Theme.standard.particles,
        fading: Bool = false
    ) -> (stream: ParticleStream?, particles: [StageParticle]) {
        var stream: ParticleStream?
        if showsRate, path.length > 0 {
            stream = ParticleStream(
                path: path, spacing: Self.spacing(for: rate), phase: phase, color: color, size: sizes.streamSize,
                style: fading ? .fading : .rate
            )
        }
        let particles = travelling.compactMap { start -> StageParticle? in
            let along = CGFloat(time - start) * Self.messageSpeed
            guard along <= path.length else { return nil }
            let place = path.point(at: along)
            var tint = color
            if fading { tint.w *= Float(max(0, 1 - along / max(path.length, 1))) }
            return StageParticle(position: place.point, direction: place.direction, color: tint, size: sizes.messageSize, style: .message, owner: path.id)
        }
        return (stream, particles)
    }
}

/// How the stage writes numbers.
public enum StageFormat {
    public static func rate(_ value: Double) -> String {
        switch value {
        case ..<0.05: "0/s"
        case ..<10: String(format: "%.1f/s", value)
        case ..<10_000: "\(Int(value.rounded()).formatted())/s"
        case ..<1_000_000: String(format: "%.1fk/s", value / 1000)
        default: String(format: "%.2fM/s", value / 1_000_000)
        }
    }

    public static func count(_ value: Int64) -> String {
        value.formatted()
    }
}

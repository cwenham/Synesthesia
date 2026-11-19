import Foundation
import Stage
import SwiftUI

/// The person's settings for how the canvas looks, applied to the theme: ``Theme/current`` is the theme with them.
///
/// Today the theme is always ``Theme/standard``; when themes can be chosen and edited, the chosen one is what these
/// settings are applied to.
@MainActor
public enum CanvasLook {
    /// Whether the starfield shows behind the canvas.
    public static let starfieldKey = "starfieldIsOn"
    /// How fast it travels, as a multiple of the theme's speed: 0 holds the stars still.
    public static let starfieldSpeedKey = "starfieldSpeed"
    public static let speedRange: ClosedRange<Double> = 0...3

    /// Whether the system asks for less motion; the stars then stay still. The platform keeps this up to date.
    public static var reducesMotion = false {
        didSet { if reducesMotion != oldValue { apply() } }
    }

    private static var observer: (any NSObjectProtocol)?

    /// Applies the settings now and whenever they change.
    public static func start(defaults: UserDefaults = .standard) {
        apply(defaults: defaults)
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: defaults, queue: .main) { _ in
            MainActor.assumeIsolated { apply(defaults: defaults) }
        }
    }

    /// The theme with the person's settings in `defaults` applied.
    public static func theme(from defaults: UserDefaults = .standard, base: Theme = .standard, reducesMotion: Bool = false) -> Theme {
        var theme = base
        let isOn = defaults.object(forKey: starfieldKey) as? Bool ?? true
        let speed = defaults.object(forKey: starfieldSpeedKey) as? Double ?? 1
        theme.starfield.isOn = base.starfield.isOn && isOn
        theme.starfield.speed = reducesMotion ? 0 : base.starfield.speed * min(max(speed, speedRange.lowerBound), speedRange.upperBound)
        return theme
    }

    public static func apply(defaults: UserDefaults = .standard) {
        let theme = theme(from: defaults, reducesMotion: reducesMotion)
        if theme != Theme.current { Theme.current = theme }
    }
}

/// The canvas's settings: the starfield and its speed. Shown in the app's Settings window.
public struct CanvasSettingsView: View {
    @AppStorage(CanvasLook.starfieldKey) private var starfield = true
    @AppStorage(CanvasLook.starfieldSpeedKey) private var speed = 1.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init() {}

    public var body: some View {
        Form {
            Section("Canvas") {
                Toggle("Starfield behind the pipeline", isOn: $starfield)
                    .help("Stars drifting toward you behind the canvas, as if it were travelling through space.")
                LabeledContent("Speed") {
                    HStack {
                        Slider(value: $speed, in: CanvasLook.speedRange) {
                            Text("Speed")
                        } minimumValueLabel: {
                            Image(systemName: "tortoise").help("Still")
                        } maximumValueLabel: {
                            Image(systemName: "hare").help("Three times as fast as usual")
                        }
                        .labelsHidden()
                        Text(speedText).monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 40, alignment: .leading)
                    }
                }
                .disabled(!starfield)
                .help("How fast the stars travel, from still to three times as fast as usual.")
                if reduceMotion, starfield {
                    Text("Reduce Motion is on in System Settings, so the stars stay still.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
    }

    private var speedText: String {
        speed < 0.01 ? "Still" : String(format: "%.1f×", speed)
    }
}

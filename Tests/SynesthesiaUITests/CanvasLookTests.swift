import Foundation
import Stage
import Testing
@testable import SynesthesiaUI

@MainActor
struct CanvasLookTests {
    private func defaults() -> UserDefaults {
        let name = "CanvasLookTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func withNoSettingsTheStandardThemeIsUsed() {
        #expect(CanvasLook.theme(from: defaults()) == Theme.standard)
    }

    @Test func theStarfieldCanBeSwitchedOffAndItsSpeedChanged() {
        let settings = defaults()
        settings.set(false, forKey: CanvasLook.starfieldKey)
        settings.set(2.0, forKey: CanvasLook.starfieldSpeedKey)
        let theme = CanvasLook.theme(from: settings)
        #expect(!theme.starfield.isOn)
        #expect(theme.starfield.speed == Theme.standard.starfield.speed * 2)
        settings.set(50.0, forKey: CanvasLook.starfieldSpeedKey)
        #expect(CanvasLook.theme(from: settings).starfield.speed == Theme.standard.starfield.speed * CanvasLook.speedRange.upperBound)
    }

    @Test func reducedMotionHoldsTheStarsStill() {
        let theme = CanvasLook.theme(from: defaults(), reducesMotion: true)
        #expect(theme.starfield.isOn && theme.starfield.speed == 0)
    }
}

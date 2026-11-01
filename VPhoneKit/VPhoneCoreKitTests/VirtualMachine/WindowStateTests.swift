import Foundation
import Testing
@testable import VPhoneCoreKit

struct WindowStateTests {
    @Test(arguments: VPhoneDisplayOrientation.allCases)
    func `each VM keeps its frame and all four rotations across sessions`(orientation: VPhoneDisplayOrientation) throws {
        let suite = "VPhoneWindowStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = VPhoneWindowState(frame: CGRect(x: -1200, y: 137, width: 840, height: 620), orientation: orientation,
                                     panelSize: CGSize(width: 669, height: 951))
        try state.save(scene: "/machines/Duo", defaults: defaults)
        let other = VPhoneWindowState(frame: CGRect(x: 92, y: 60, width: 650, height: 900), orientation: .portrait)
        try other.save(scene: "/machines/iPad", defaults: defaults)
        let nextSession = try #require(UserDefaults(suiteName: suite))
        #expect(VPhoneWindowState.load(scene: "/machines/Duo", defaults: nextSession) == state)
        #expect(VPhoneWindowState.load(scene: "/machines/iPad", defaults: nextSession) == other)
        #expect(VPhoneWindowState.load(scene: "/machines/New", defaults: nextSession) == nil)
    }

    @Test func `invalid preferences cannot restore an unusable window`() throws {
        let suite = "VPhoneWindowStateTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "window-state-test"
        defaults.set(Data("damaged".utf8), forKey: key)
        #expect(VPhoneWindowState.load(scene: "test", defaults: defaults) == nil)
        let invalid = VPhoneWindowState(frame: CGRect(x: 0, y: 0, width: 0, height: 600), orientation: .portrait)
        defaults.set(try PropertyListEncoder().encode(invalid), forKey: key)
        #expect(VPhoneWindowState.load(scene: "test", defaults: defaults) == nil)
    }

    @Test func `a present monitor preserves exact placement and an unplugged monitor falls back`() {
        let main = CGRect(x: 0, y: 25, width: 1440, height: 850)
        let left = CGRect(x: -1920, y: 25, width: 1920, height: 1055)
        let state = VPhoneWindowState(frame: CGRect(x: -1600, y: 120, width: 900, height: 700), orientation: .landscapeRight)
        #expect(state.frame(visibleFrames: [main, left]) == state.frame)
        #expect(main.contains(state.frame(visibleFrames: [main])))
        let oversized = VPhoneWindowState(frame: CGRect(x: 1800, y: 400, width: 2400, height: 1600), orientation: .landscapeLeft)
        let fitted = oversized.frame(visibleFrames: [main])
        #expect(main.contains(fitted))
        #expect(abs(fitted.width / fitted.height - 1.5) < 0.001)
        #expect(state.frame(visibleFrames: []) == state.frame)
    }
}

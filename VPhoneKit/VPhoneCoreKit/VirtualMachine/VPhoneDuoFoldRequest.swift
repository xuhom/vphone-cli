import Foundation

/// A panel swap and its physical orientation are one pose, not a posture
/// write followed by a competing rotation write. See GuestAPI.setDevicePose.
public struct VPhoneDuoFoldRequest: Sendable {
    public let position: VPhoneDuoPosture
    public let duration: Double?
    public let coverOrientation: VPhoneDisplayOrientation?

    public init(position: VPhoneDuoPosture, duration: Double?, coverOrientation: VPhoneDisplayOrientation? = nil) {
        self.position = position
        self.duration = duration
        self.coverOrientation = coverOrientation
    }

    public struct Reply: Sendable {
        public let angle: Double
        public let hinge: Int
        public let providerRunning: Bool
        public let applied: Bool
        public let sweepMilliseconds: Double?
        public let orientation: VPhoneDisplayOrientation
    }

    public enum Failure: Error, LocalizedError {
        case invalidReply
        case notSettled(expected: VPhoneDisplayOrientation?, actual: Int?)

        public var errorDescription: String? {
            switch self {
            case .invalidReply: "The guest returned an invalid fold posture."
            case let .notSettled(expected, actual):
                "The Duo panel did not finish switching (expected orientation: \(expected.map { String($0.rawValue) } ?? "any")°, reported: \(actual.map(String.init) ?? "unavailable")°)."
            }
        }
    }

    @MainActor
    public func perform(
        timeout: Duration = .seconds(4),
        rpc: @MainActor (String, [String: Any]) async throws -> [String: Any],
    ) async throws -> Reply {
        var params: [String: Any] = ["position": position.rawValue, "use_display_tool": true]
        if let duration {
            // A zero-length absolute sweep can leave iOS 27.1's content-mode
            // transition active after its reply, refusing every later swap.
            // Host actions use a short real sweep so that transition finishes.
            // The raw guest API retains its explicit instant-swap option.
            params["duration"] = duration == 0 ? 0.42 : duration
        }
        if position == .closed, let coverOrientation {
            // Physical pose codes differ from interface degrees. On the
            // cover this is the mapping used by setFoldableRotation.
            params["orientation"] = switch coverOrientation {
            case .portrait: 1
            case .landscapeLeft: 4
            case .upsideDown: 2
            case .landscapeRight: 3
            }
        }
        let result = try await rpc("display.posture", params)
        guard let angle = (result["angle"] as? NSNumber)?.doubleValue,
              angle.isFinite, abs(angle - position.angle) < 0.01,
              let hinge = (result["hinge"] as? NSNumber)?.intValue, 0 ... 4 ~= hinge
        else { throw Failure.invalidReply }
        let sweep = result["sweep"] as? [String: Any]
        let milliseconds = (sweep?["duration_ms"] as? NSNumber)?.doubleValue
        if let milliseconds, !milliseconds.isFinite || milliseconds < -1 || milliseconds > 10_000 {
            throw Failure.invalidReply
        }
        // CoreMotion acknowledges publication, before its animation ends.
        // SpringBoard's synchronous sweep has already finished when it replies.
        if sweep?["completed"] as? Bool != true, let milliseconds, milliseconds > 0 {
            try await Task.sleep(for: .milliseconds(milliseconds))
        }
        let expected: VPhoneDisplayOrientation? = if position == .closed, let coverOrientation {
            coverOrientation
        } else if result["source"] as? String == "coremotion" {
            position == .closed ? .portrait : .landscapeLeft
        } else {
            nil // The legacy SpringBoard sweep preserves its physical pose.
        }
        let clock = ContinuousClock()
        let verifiesPanel = result["panel_verified"] as? Bool == true
        let expectedPanel = position == .closed ? "cover" : "inner"
        let deadline = clock.now.advanced(by: timeout)
        var actual: Int?
        var previous: VPhoneDisplayOrientation?
        repeat {
            try Task.checkCancellation()
            let state = try await rpc("display.orientation", [:])
            actual = (state["degrees"] as? NSNumber)?.intValue
            let orientation = actual.flatMap(VPhoneDisplayOrientation.init(degrees:))
            let reportedAngle = (state["fold_angle"] as? NSNumber)?.doubleValue
            let currentAngle = (state["fold_current_angle"] as? NSNumber)?.doubleValue
            let sweeping = state["fold_sweeping"] as? Bool == true
            if let orientation, expected == nil || expected == orientation,
               !verifiesPanel || state["fold_panel"] as? String == expectedPanel,
               !sweeping, currentAngle.map({ abs($0 - angle) < 0.5 }) ?? true,
               let reportedAngle, abs(reportedAngle - angle) < 0.01 {
                // Do not release the controls on a single pre-transition read.
                if previous == orientation {
                    let hid = result["hinge_hid"] as? [String: Any]
                    return Reply(angle: angle, hinge: hinge,
                                 providerRunning: hid?["provider_running"] as? Bool ?? false,
                                 applied: hid?["applied"] as? Bool ?? false,
                                 sweepMilliseconds: milliseconds, orientation: orientation)
                }
                previous = orientation
            } else {
                previous = nil
            }
            if clock.now >= deadline { break }
            try await Task.sleep(for: .milliseconds(100))
        } while clock.now < deadline
        throw Failure.notSettled(expected: expected, actual: actual)
    }
}

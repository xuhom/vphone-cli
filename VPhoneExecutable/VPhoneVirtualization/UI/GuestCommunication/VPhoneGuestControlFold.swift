import Foundation
import VPhoneCoreKit

// MARK: - Fold posture RPC

extension VPhoneGuestControl {
    /// Sweeps a foldable guest to `position`, one of the three screen states
    /// Apple's Duo tooling names (`display.posture`'s `position`). `duration`
    /// is seconds — 0 uses a short native sweep to avoid an unfinished instant
    /// transition, nil the guest's per-direction default (opening faster than
    /// closing). The pose override is the primary; the
    /// virtual hinge service beside it may be off without failing the call.
    func setFoldPosition(_ position: VPhoneFoldPosition, duration: Double?) async throws -> VPhoneFoldReply {
        guard guestCapabilities.contains("device_pose") else {
            throw ControlError.unsupportedCapability("device_pose")
        }
        guard foldRequestsInFlight == 0, !isChangingOrientation else {
            throw ControlError.guestError("A display transition is already in progress. Wait for it to finish.")
        }
        // Snapshot before the first await. A successful swap already belongs
        // to the inner scene when its reply and observers are delivered.
        if foldPosition == .closed, position != .closed, !isRestoringDisplayState,
           let interfaceOrientation {
            duoCoverOrientation = interfaceOrientation
        }
        let restoresCover = position == .closed && foldPosition != .closed && !isRestoringDisplayState
        print("[fold] requesting \(position.rawValue); interface=\(interfaceOrientation?.rawValue.description ?? "unknown"), cover=\(duoCoverOrientation.rawValue), restoreCover=\(restoresCover)")
        foldRequestsInFlight += 1
        defer { foldRequestsInFlight -= 1 }
        let request = VPhoneDuoFoldRequest(position: position, duration: duration,
                                          coverOrientation: restoresCover ? duoCoverOrientation : nil)
        let reply = try await request.perform { try await self.call($0, params: $1) }
        print("[fold] confirmed \(position.rawValue); interface=\(reply.orientation.rawValue)")
        // Publish the panel before its confirmed direction, so the window
        // consumes both around the fixed right edge. No second rotation RPC.
        foldSweepSeconds = 0
        foldPosition = position
        foldAngle = reply.angle
        interfaceOrientation = reply.orientation
        return VPhoneFoldReply(
            position: position,
            angle: reply.angle,
            hingeState: reply.hinge,
            providerRunning: reply.providerRunning,
            applied: reply.applied,
            sweepMilliseconds: reply.sweepMilliseconds,
        )
    }

    /// The angle the guest's last fold settled at, which the orientation poll
    /// reads (`display.orientation`'s `fold_angle`), so the window follows
    /// folds it did not ask for, such as Xcode DeviceHub's. A fold this window
    /// has in flight verifies its own direction before publishing. The hinge
    /// preference can name its target before the interface has finished.
    func followGuestFold(angle: Double) {
        guard foldRequestsInFlight == 0, angle.isFinite, 0 ... 180 ~= angle, foldAngle != angle else { return }
        foldSweepSeconds = 0
        foldPosition = VPhoneFoldPosition.allCases.min { abs($0.angle - angle) < abs($1.angle - angle) }
        foldAngle = angle
    }
}

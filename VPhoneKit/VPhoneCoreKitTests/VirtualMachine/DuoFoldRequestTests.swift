import Foundation
import Testing
@testable import VPhoneCoreKit

@MainActor
struct DuoFoldRequestTests {
    @MainActor private final class Guest {
        var writes: [[String: Any]] = []
        var reads: [[String: Any]]
        var readCount = 0
        var posture: [String: Any]

        init(position: VPhoneDuoPosture, orientations: [Int]) {
            posture = ["angle": position.angle, "hinge": position == .closed ? 1 : 3,
                       "source": "coremotion", "sweep": ["duration_ms": 0, "completed": false],
                       "hinge_hid": ["provider_running": true, "applied": true]]
            reads = orientations.map { ["degrees": $0, "fold_angle": position.angle] }
        }

        func call(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            if method == "display.posture" {
                writes.append(params)
                return posture
            }
            // A fold may only read direction afterwards. The old follow-up
            // display.rotation write caused the reported guest refusal.
            #expect(method == "display.orientation" && params.isEmpty)
            readCount += 1
            return reads.count > 1 ? reads.removeFirst() : reads[0]
        }
    }

    @Test(arguments: VPhoneDisplayOrientation.allCases)
    func `closing restores the cover in the same pose write`(orientation: VPhoneDisplayOrientation) async throws {
        let guest = Guest(position: .closed, orientations: [orientation.rawValue])
        let reply = try await VPhoneDuoFoldRequest(position: .closed, duration: 0, coverOrientation: orientation)
            .perform(rpc: { try guest.call($0, $1) })
        let physical = switch orientation {
        case .portrait: 1
        case .landscapeLeft: 4
        case .upsideDown: 2
        case .landscapeRight: 3
        }
        #expect(guest.writes.count == 1)
        #expect(guest.writes[0]["use_display_tool"] as? Bool == true)
        // Releasing the button on a zero-length native sweep left the display
        // transition active indefinitely on iOS 27.1.
        #expect((guest.writes[0]["duration"] as? Double ?? 0) > 0)
        #expect(guest.writes[0]["orientation"] as? Int == physical)
        #expect(guest.writes[0]["position"] as? String == "closed")
        #expect(reply.orientation == orientation && reply.angle == 0)
        #expect(reply.providerRunning && reply.applied)
    }

    @Test func `opening waits for stable direction instead of accepting the publication acknowledgement`() async throws {
        let guest = Guest(position: .open, orientations: [0, 90, 0, 90, 90])
        let reply = try await VPhoneDuoFoldRequest(position: .open, duration: 0).perform(rpc: { try guest.call($0, $1) })
        #expect(guest.writes.count == 1 && guest.writes[0]["orientation"] == nil)
        #expect(guest.readCount == 5 && reply.orientation == .landscapeLeft)
    }

    @Test func `startup closed does not overwrite its separately saved rotation`() async throws {
        let guest = Guest(position: .closed, orientations: [0])
        _ = try await VPhoneDuoFoldRequest(position: .closed, duration: 0).perform(rpc: { try guest.call($0, $1) })
        #expect(guest.writes.count == 1 && guest.writes[0]["orientation"] == nil)
    }

    @Test func `a matching hinge and direction cannot substitute for actual primary panel ownership`() async throws {
        let guest = Guest(position: .open, orientations: [90])
        guest.posture["panel_verified"] = true
        guest.reads = [
            ["degrees": 90, "fold_angle": 180],
            ["degrees": 90, "fold_angle": 180, "fold_panel": "cover"],
            ["degrees": 90, "fold_angle": 180, "fold_panel": "inner"],
        ]
        _ = try await VPhoneDuoFoldRequest(position: .open, duration: 0).perform(rpc: { try guest.call($0, $1) })
        #expect(guest.readCount == 4)
    }

    @Test func `a refused close must not report success from the configured angle alone`() async {
        let guest = Guest(position: .closed, orientations: [0])
        guest.posture["panel_verified"] = true
        guest.reads = [["degrees": 0, "fold_angle": 0, "fold_panel": "inner"]]
        await #expect(throws: VPhoneDuoFoldRequest.Failure.self) {
            try await VPhoneDuoFoldRequest(position: .closed, duration: 0).perform(timeout: .zero, rpc: { try guest.call($0, $1) })
        }
    }

    @Test func `a published target and matching direction cannot finish an active sweep`() async throws {
        let guest = Guest(position: .open, orientations: [90])
        guest.reads = [
            ["degrees": 90, "fold_angle": 180, "fold_current_angle": 80, "fold_sweeping": true],
            ["degrees": 90, "fold_angle": 180, "fold_current_angle": 180, "fold_sweeping": true],
            ["degrees": 90, "fold_angle": 180, "fold_current_angle": 100, "fold_sweeping": false],
            ["degrees": 90, "fold_angle": 180, "fold_current_angle": 180, "fold_sweeping": false],
        ]
        _ = try await VPhoneDuoFoldRequest(position: .open, duration: nil).perform(rpc: { try guest.call($0, $1) })
        #expect(guest.readCount == 5)
    }

    @Test func `a timed out fold reports its real direction without forcing another rotation`() async {
        let guest = Guest(position: .closed, orientations: [90])
        await #expect(throws: VPhoneDuoFoldRequest.Failure.self) {
            try await VPhoneDuoFoldRequest(position: .closed, duration: 0, coverOrientation: .portrait)
                .perform(timeout: .zero, rpc: { try guest.call($0, $1) })
        }
        #expect(guest.writes.count == 1 && guest.readCount == 1)
    }

    @Test func `invalid and unfinished replies cannot be published as a completed panel swap`() async {
        let guest = Guest(position: .open, orientations: [90])
        guest.posture["angle"] = 0
        await #expect(throws: VPhoneDuoFoldRequest.Failure.self) {
            try await VPhoneDuoFoldRequest(position: .open, duration: 0).perform(rpc: { try guest.call($0, $1) })
        }
        #expect(guest.readCount == 0)
        guest.posture["angle"] = 180
        guest.reads = [["degrees": 90, "fold_angle": 0]]
        await #expect(throws: VPhoneDuoFoldRequest.Failure.self) {
            try await VPhoneDuoFoldRequest(position: .open, duration: 0).perform(timeout: .zero, rpc: { try guest.call($0, $1) })
        }
    }

    @Test func `legacy sweeps preserve their native pose`() async throws {
        let guest = Guest(position: .open, orientations: [270])
        guest.posture["source"] = "test-automation"
        guest.posture["sweep"] = ["completed": true, "duration_ms": 3000]
        let reply = try await VPhoneDuoFoldRequest(position: .open, duration: 3).perform(rpc: { try guest.call($0, $1) })
        #expect(reply.orientation == .landscapeRight && reply.sweepMilliseconds == 3000)
    }

    @Test func `a guest refusal retains its diagnostic text`() async {
        struct Refused: Error, LocalizedError {
            var errorDescription: String? { "The virtual hinge did not take the pose" }
        }
        do {
            _ = try await VPhoneDuoFoldRequest(position: .open, duration: 0).perform { _, _ in throw Refused() }
            Issue.record("A refused fold must not succeed")
        } catch {
            #expect(error.localizedDescription == "The virtual hinge did not take the pose")
        }
    }
}

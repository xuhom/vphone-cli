import CoreGraphics
import Foundation

/// Host window state, keyed by the canonical VM directory rather than by
/// the bundle version or the guest's device name. Kept in host preferences;
/// saving a window never modifies a running machine's files.
public struct VPhoneWindowState: Codable, Equatable, Sendable {
    public let frame: CGRect
    public let orientation: VPhoneDisplayOrientation
    public let panelSize: CGSize?
    public let alwaysOnTop: Bool

    public init(frame: CGRect, orientation: VPhoneDisplayOrientation, panelSize: CGSize? = nil, alwaysOnTop: Bool = false) {
        self.frame = frame
        self.orientation = orientation
        self.panelSize = panelSize
        self.alwaysOnTop = alwaysOnTop
    }

    private enum CodingKeys: String, CodingKey {
        case frame, orientation, panelSize, alwaysOnTop
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        frame = try values.decode(CGRect.self, forKey: .frame)
        orientation = try values.decode(VPhoneDisplayOrientation.self, forKey: .orientation)
        panelSize = try values.decodeIfPresent(CGSize.self, forKey: .panelSize)
        // Older records still restore their frame and rotation.
        alwaysOnTop = try values.decodeIfPresent(Bool.self, forKey: .alwaysOnTop) ?? false
    }

    private var isValid: Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite &&
            frame.width > 0 && frame.height > 0 &&
            (panelSize.map { $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 } ?? true)
    }

    private static func key(for scene: String) -> String { "window-state-\(scene)" }

    public static func load(scene: String, defaults: UserDefaults) -> Self? {
        guard let data = defaults.data(forKey: key(for: scene)),
              let state = try? PropertyListDecoder().decode(Self.self, from: data),
              state.isValid
        else { return nil }
        return state
    }

    public func save(scene: String, defaults: UserDefaults) throws {
        guard isValid else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        defaults.set(try encoder.encode(self), forKey: Self.key(for: scene))
    }

    /// Keep the saved placement when its monitor is present. If it has been
    /// unplugged, move onto an available screen and reduce oversized frames.
    /// Negative coordinates are valid on displays left of the main display.
    public func frame(visibleFrames: [CGRect]) -> CGRect {
        let screens = visibleFrames.filter { !$0.isEmpty && !$0.isInfinite && !$0.isNull }
        guard var screen = screens.first else { return frame }
        var greatestArea: CGFloat = 0
        for candidate in screens {
            let intersection = frame.intersection(candidate)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > greatestArea {
                greatestArea = area
                screen = candidate
            }
        }
        let scale = min(1, screen.width / frame.width, screen.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        return CGRect(
            x: min(max(frame.minX, screen.minX), screen.maxX - size.width),
            y: min(max(frame.minY, screen.minY), screen.maxY - size.height),
            width: size.width,
            height: size.height,
        )
    }
}

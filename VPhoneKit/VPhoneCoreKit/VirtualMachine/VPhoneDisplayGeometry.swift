import CoreGraphics

/// Focus and delta policy shared by the VM event dispatcher and display view.
public enum VPhoneScrollInput {
    public static let pointsPerWheelLine: CGFloat = 16

    public static func shouldCapture(
        appActive: Bool, windowKey: Bool, hasSheet: Bool, eventMatchesWindow: Bool, enabled: Bool,
    ) -> Bool {
        appActive && windowKey && !hasSheet && eventMatchesWindow && enabled
    }

    public static func touchDelta(x: CGFloat, y: CGFloat, precise: Bool, inverted: Bool) -> CGPoint {
        guard x.isFinite, y.isFinite else { return .zero }
        let scale: CGFloat = (precise ? 1 : pointsPerWheelLine) * 1.5 * (inverted ? -1 : 1)
        return CGPoint(x: -x * scale, y: y * scale)
    }
}

// MARK: - Display Geometry

/// Where the guest display sits inside the view that shows it.
///
/// The view draws the display aspect-fit and centered. A windowed VM keeps
/// the display's aspect ratio, so the two coincide; a full-screen VM fills
/// the Mac screen and letterboxes the display. Touches must be measured
/// against the drawn display, not the view, or a letterboxed display maps
/// the bars onto the guest screen and the real edges land inside it.
public struct VPhoneDisplayGeometry: Equatable, Sendable {
    /// Edge a touch starts near, as `_VZTouch`'s `swipeAim` takes it.
    public enum Edge: Int, Sendable {
        case none = 0
        case top = 1
        case bottom = 2
        case right = 4
        case left = 8
    }

    /// Distance, in view points, within which a touch starts an edge swipe.
    public static let edgeThreshold: CGFloat = 32

    /// The drawn display, in the view's coordinates.
    public let displayRect: CGRect
    /// Whether the view's y axis points down.
    public let isFlipped: Bool

    /// AppKit can stretch a view's frame while its bounds retain the scanout
    /// aspect. Duo's guest fills the cover scanout with the inner framebuffer;
    /// the host reverses that small distortion when showing the inner panel.
    public static func framebufferBounds(filling frameSize: CGSize, displaySize: CGSize) -> CGRect {
        guard frameSize.width > 0, frameSize.height > 0,
              displaySize.width > 0, displaySize.height > 0
        else { return CGRect(origin: .zero, size: frameSize) }
        return CGRect(x: 0, y: 0, width: frameSize.width,
                      height: frameSize.width * displaySize.height / displaySize.width)
    }

    /// A display with no size, or a view with no area, maps onto the whole
    /// view: there is nothing better to measure against.
    public init(viewBounds: CGRect, displaySize: CGSize, isFlipped: Bool) {
        self.isFlipped = isFlipped
        guard displaySize.width > 0, displaySize.height > 0,
              viewBounds.width > 0, viewBounds.height > 0
        else {
            displayRect = viewBounds
            return
        }
        let scale = min(viewBounds.width / displaySize.width, viewBounds.height / displaySize.height)
        let size = CGSize(width: displaySize.width * scale, height: displaySize.height * scale)
        displayRect = CGRect(
            x: viewBounds.midX - size.width / 2,
            y: viewBounds.midY - size.height / 2,
            width: size.width,
            height: size.height,
        )
    }

    /// The active panel occupies the top-leading part of a backing scanout.
    /// Its pixel ratio is applied to the actual drawn rectangle, so resizing
    /// the Mac window never mixes guest points with host view coordinates.
    public init(viewBounds: CGRect, displaySize: CGSize, activeDisplaySize: CGSize, isFlipped: Bool) {
        self.isFlipped = isFlipped
        let backing = Self(viewBounds: viewBounds, displaySize: displaySize, isFlipped: isFlipped).displayRect
        guard displaySize.width > 0, displaySize.height > 0,
              activeDisplaySize.width > 0, activeDisplaySize.height > 0
        else {
            displayRect = backing
            return
        }
        let width = backing.width * min(activeDisplaySize.width / displaySize.width, 1)
        let height = backing.height * min(activeDisplaySize.height / displaySize.height, 1)
        displayRect = CGRect(
            x: backing.minX,
            y: isFlipped ? backing.minY : backing.maxY - height,
            width: width,
            height: height,
        )
    }

    /// The visible panel inside a scaled backing view. Pixel dimensions are
    /// ratios: guest points differ from AppKit points after a window resize.
    public static func activeViewportBounds(
        viewBounds: CGRect, activePixels: CGSize, backingPixels: CGSize
    ) -> CGRect {
        guard activePixels.width > 0, activePixels.height > 0,
              backingPixels.width > 0, backingPixels.height > 0 else { return viewBounds }
        let width = viewBounds.width * min(1, activePixels.width / backingPixels.width)
        let height = viewBounds.height * min(1, activePixels.height / backingPixels.height)
        return CGRect(x: viewBounds.minX, y: viewBounds.maxY - height, width: width, height: height)
    }

    /// A view point as a 0...1 display position with y down. Points on the
    /// letterbox bars clamp to the nearest display edge.
    ///
    /// `clamped: false` keeps a point that falls outside the display outside it,
    /// so the result may leave 0...1. A trackpad scroll replayed as a touch
    /// needs that: the guest stops following a finger once it is pinned to the
    /// edge, so a long swipe has to carry coordinates past it.
    public func normalizedPoint(_ point: CGPoint, clamped: Bool = true) -> CGPoint {
        guard displayRect.width > 0, displayRect.height > 0 else { return .zero }
        let x = (point.x - displayRect.minX) / displayRect.width
        let y = (point.y - displayRect.minY) / displayRect.height
        let down = isFlipped ? y : 1 - y
        guard clamped else { return CGPoint(x: x, y: down) }
        return CGPoint(
            x: min(1, max(0, x)),
            y: min(1, max(0, down)),
        )
    }

    /// The view point for a 0...1 display position with y down.
    public func viewPoint(normalized point: CGPoint) -> CGPoint {
        let y = isFlipped ? point.y : 1 - point.y
        return CGPoint(
            x: displayRect.minX + point.x * displayRect.width,
            y: displayRect.minY + y * displayRect.height,
        )
    }

    /// The display edge nearest to a view point, when that point is within
    /// `edgeThreshold` of it. A point on a letterbox bar is past the edge
    /// beside it and counts as near it.
    public func edge(at point: CGPoint) -> Edge {
        let left = point.x - displayRect.minX
        let right = displayRect.maxX - point.x
        let lowY = point.y - displayRect.minY
        let highY = displayRect.maxY - point.y
        let candidates: [(Edge, CGFloat)] = [
            (.left, left),
            (.right, right),
            (.bottom, isFlipped ? highY : lowY),
            (.top, isFlipped ? lowY : highY),
        ]
        // Ties keep the earlier entry, so a corner resolves to left or right.
        var nearest = candidates[0]
        for candidate in candidates.dropFirst() where candidate.1 < nearest.1 {
            nearest = candidate
        }
        return nearest.1 < Self.edgeThreshold ? nearest.0 : .none
    }
}

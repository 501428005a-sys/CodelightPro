import AppKit

/// How the panel presents itself: a Dynamic-Island-style bar hugging the
/// notch, or the draggable floating strip.
enum DisplayMode: String {
    case island
    case floating
}

/// An island ⇄ floating transition in progress. The window is temporarily
/// big enough to hold both shells; rects are in window coordinates (top-left
/// origin) and the view springs from `fromRect` to `toRect`.
struct PanelMorph: Equatable {
    var from: DisplayMode
    var to: DisplayMode
    var fromRect: CGRect
    var toRect: CGRect
    var atDestination = false
}

enum IslandPointerPhase {
    case moved
    case released
}

/// Geometry of the island on its current screen. The island sits flush with
/// the top edge, is as tall as the menu bar / notch and extends `sideWidth`
/// past the notch on each side so there's room for content left and right.
struct IslandMetrics: Equatable {
    /// 0 on screens without a camera housing (the island is then a plain pill).
    var notchWidth: CGFloat
    var height: CGFloat

    static let sideWidth: CGFloat = 76
    static let bottomRadius: CGFloat = 12
    static let expandedBottomRadius: CGFloat = 22
    /// Concave "ears" where the island meets the top edge, like the real notch.
    static let earRadius: CGFloat = 6
    /// Transparent margin around the island so the glow ring isn't clipped.
    static let glowPadding: CGFloat = 12
    static let expandedWidth: CGFloat = 340
    static let expandedBodyHeight: CGFloat = 470
    /// Extra height while the phone switches are dropped down, so the panel
    /// grows downward instead of squeezing the agent cards.
    static let phoneOptionsHeight: CGFloat = 122

    static let fallback = IslandMetrics(notchWidth: 0, height: 32)

    init(notchWidth: CGFloat, height: CGFloat) {
        self.notchWidth = notchWidth
        self.height = height
    }

    init(screen: NSScreen) {
        if let notch = screen.notchSize {
            self.init(notchWidth: notch.width, height: notch.height)
        } else {
            self.init(notchWidth: 0, height: max(24, screen.menuBarHeight))
        }
    }

    var collapsedWidth: CGFloat {
        notchWidth > 0 ? notchWidth + Self.sideWidth * 2 : 224
    }

    func bodySize(expanded: Bool, extraHeight: CGFloat = 0) -> NSSize {
        expanded
            ? NSSize(width: max(collapsedWidth, Self.expandedWidth),
                     height: height + Self.expandedBodyHeight + extraHeight)
            : NSSize(width: collapsedWidth, height: height)
    }

    /// Window size: the island plus glow padding on the sides and bottom (the
    /// top is flush with the screen edge).
    func windowSize(expanded: Bool, extraHeight: CGFloat = 0) -> NSSize {
        let body = bodySize(expanded: expanded, extraHeight: extraHeight)
        return NSSize(width: body.width + Self.glowPadding * 2, height: body.height + Self.glowPadding)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Size of the camera housing, or nil on screens without one.
    var notchSize: NSSize? {
        guard safeAreaInsets.top > 0,
              let left = auxiliaryTopLeftArea,
              let right = auxiliaryTopRightArea else {
            return nil
        }
        return NSSize(width: frame.width - left.width - right.width, height: safeAreaInsets.top)
    }

    var menuBarHeight: CGFloat {
        frame.maxY - visibleFrame.maxY
    }
}

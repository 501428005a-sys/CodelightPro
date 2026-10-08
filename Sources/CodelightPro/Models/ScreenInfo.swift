import AppKit

/// A connected display as shown in the panel settings.
struct ScreenInfo: Identifiable, Equatable {
    /// Stable across reboots and re-plugging, unlike `displayID`, so it's what
    /// the display preference is stored as.
    var id: String
    var displayID: CGDirectDisplayID
    var name: String
    var isBuiltin: Bool
    /// Hosts the menu bar (System Settings' "main display").
    var isMain: Bool
    var pixelSize: CGSize

    /// e.g. "内建 · 主屏", "外接 · 副屏".
    var kindLabel: String {
        "\(isBuiltin ? "内建" : "外接") · \(isMain ? "主屏" : "副屏")"
    }

    @MainActor
    static func connected() -> [ScreenInfo] {
        NSScreen.screens.enumerated().compactMap { index, screen in
            guard let displayID = screen.displayID, let uuid = screen.displayUUID else { return nil }
            return ScreenInfo(
                id: uuid,
                displayID: displayID,
                name: screen.localizedName,
                isBuiltin: CGDisplayIsBuiltin(displayID) != 0,
                // `NSScreen.screens[0]` is always the menu-bar screen.
                isMain: index == 0,
                pixelSize: CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                  height: screen.frame.height * screen.backingScaleFactor)
            )
        }
    }
}

extension NSScreen {
    var displayUUID: String? {
        guard let displayID,
              let uuid = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

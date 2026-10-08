import AppKit

// Top-level code runs on the main thread; assume main-actor isolation so we can
// touch the main-actor-isolated AppDelegate / AppModel.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Accessory: no dock icon, no menu bar item — just the floating orb.
    app.setActivationPolicy(.accessory)
    app.run()
}

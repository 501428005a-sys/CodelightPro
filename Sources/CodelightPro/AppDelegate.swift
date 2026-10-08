import AppKit
import Combine
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let sync = StatusSyncClient()
    private var panel: StripPanel!
    private var settingsWindow: NSWindow?
    private var panelSettingsWindow: NSWindow?
    private var poller: Poller!
    private var approvalCenter: ApprovalCenter!
    private var pairingWatch: Task<Void, Never>?
    private var mouseMovedMonitor: Any?
    private var mouseTrackingTask: Task<Void, Never>?
    private var collapseTask: Task<Void, Never>?
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var dragSettleTask: Task<Void, Never>?
    private var islandShrinkTask: Task<Void, Never>?
    private var phoneOptionsTask: Task<Void, Never>?
    private var morphFinishTask: Task<Void, Never>?
    /// Tracks the mouse while a strip that was just pulled out of the island
    /// keeps following it (the island's own gesture ends when it morphs).
    private var pullMonitor: Any?
    private var lastPullMouse: NSPoint?
    /// Where the current press on the island started (nil when none).
    private var islandPressStart: NSPoint?

    /// The display the panel belongs to. Remembered for the island so it
    /// comes back on the same screen after a relaunch.
    private var targetDisplayID: CGDirectDisplayID? {
        didSet {
            if let targetDisplayID {
                UserDefaults.standard.set(Int(targetDisplayID), forKey: "display.screen")
            }
            model.currentScreenID = model.screens.first { $0.displayID == targetDisplayID }?.id
        }
    }

    // Auto-hide: drop the strip after a few idle minutes, bring it back on work.
    private let autoHideAfter: TimeInterval = 180
    private var lastActiveAt = Date()
    private var isAutoHidden = false

    // Same width in both states so the panel grows straight down from the strip.
    private let stripSize = NSSize(width: 224, height: 72)
    private let bigSize = NSSize(width: 224, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let hosting = NSHostingView(rootView: RootView(model: model))
        hosting.layer?.backgroundColor = .clear

        panel = StripPanel(
            contentRect: NSRect(origin: .zero, size: stripSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.dragsWindow = true
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting

        NSApp.applicationIconImage = CatIconRenderer.restingAppIcon(size: 256)
        model.screens = ScreenInfo.connected()
        setupControlCenter()
        let savedScreen = UserDefaults.standard.object(forKey: "display.screen") as? Int
        targetDisplayID = preferredScreen?.displayID ?? (model.displayMode == .island
            ? savedScreen.map { CGDirectDisplayID($0) } ?? NSScreen.main?.displayID
            : NSScreen.main?.displayID)
        applyDisplayMode(forcePlacement: true)
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDidMove() }
        }

        model.onExpandChange = { [weak self] expanded in
            self?.resize(expanded: expanded)
            if expanded { self?.poller.refreshCodexUsage() }
        }
        model.onStatusesUpdated = { [weak self] in
            self?.evaluateAutoHide()
        }
        model.onIslandPointer = { [weak self] phase in
            self?.handleIslandPointer(phase)
        }
        model.onAutoHideSettingChange = { [weak self] in
            guard let self else { return }
            self.lastActiveAt = Date()
            self.evaluateAutoHide()
        }

        // Install the accurate-tracking hooks for Claude Code (idempotent, backs
        // up the original settings.json). Runs off-main since it touches disk.
        DispatchQueue.global(qos: .utility).async {
            ClaudeHookInstaller().install()
            CodexHookInstaller().install()
        }

        poller = Poller(model: model, sync: sync)
        model.onAuthorizeClaudeUsage = { [weak self] in
            self?.poller.authorizeClaudeUsage()
        }
        model.onOpenSettings = { [weak self] in
            self?.showSettings()
        }
        model.onOpenPanelSettings = { [weak self] in
            self?.showPanelSettings()
        }
        model.onPhonePreferencesChange = { [weak self] in
            self?.poller.phonePreferencesChangedLocally()
        }
        model.onPhoneOptionsChange = { [weak self] open in
            self?.setPhoneOptionsOpen(open)
        }
        model.onPreferredScreenChange = { [weak self] in
            self?.moveToPreferredScreen()
        }
        model.onStartPairing = { [weak self] serverURL in
            self?.startPairing(serverURL: serverURL)
        }
        poller.start()
        startApprovals()
        startMouseTracking()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let mouseMovedMonitor {
            NSEvent.removeMonitor(mouseMovedMonitor)
        }
        mouseTrackingTask?.cancel()
        collapseTask?.cancel()
        dragSettleTask?.cancel()
        morphFinishTask?.cancel()
        if let pullMonitor {
            NSEvent.removeMonitor(pullMonitor)
        }
    }

    private func setupControlCenter() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = CatIconRenderer.restingMenuBarIcon()
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.toolTip = "CodelightPro 控制中心"

        Publishers.CombineLatest4(model.$codex, model.$claude, model.$isExpanded, model.$autoHideEnabled)
            .sink { [weak self] _, _, _, _ in
                self?.refreshControlCenter()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(model.$soundEnabled, model.$launchAtLogin)
            .sink { [weak self] _, _ in
                self?.refreshControlCenter()
            }
            .store(in: &cancellables)

        // @Published fires before the value is stored; hop a run loop turn
        // so the menu reads the new one.
        Publishers.CombineLatest4(model.$phoneLiveActivityEnabled, model.$phoneLiveAlertsEnabled,
                                  model.$phoneApprovalsEnabled,
                                  model.$pairing.map(\.linkedMobileCount).removeDuplicates())
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in
                self?.refreshControlCenter()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(model.$screens, model.$preferredScreenID, model.$currentScreenID)
            .sink { [weak self] _, _, _ in
                self?.refreshControlCenter()
            }
            .store(in: &cancellables)

        refreshControlCenter()
    }

    private func refreshControlCenter() {
        guard let button = statusItem.button else { return }
        button.image = CatIconRenderer.restingMenuBarIcon()
        button.contentTintColor = tintColor(for: model.overall)
        button.toolTip = "CodelightPro · \(model.currentTrackedStateText)"
        statusItem.menu = makeControlCenterMenu()
    }

    private func makeControlCenterMenu() -> NSMenu {
        let menu = NSMenu()

        let title = NSMenuItem(title: "CodelightPro · \(model.currentTrackedStateText)", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let project = NSMenuItem(title: model.currentTrackedProjectName, action: nil, keyEquivalent: "")
        project.isEnabled = false
        menu.addItem(project)
        menu.addItem(.separator())

        let codex = NSMenuItem(title: "Codex：\(model.codex.state.label)", action: nil, keyEquivalent: "")
        codex.isEnabled = false
        menu.addItem(codex)

        let claude = NSMenuItem(title: "Claude Code：\(model.claude.state.label)", action: nil, keyEquivalent: "")
        claude.isEnabled = false
        menu.addItem(claude)
        menu.addItem(.separator())

        let toggleTitle = model.isExpanded ? "收起面板" : (isAutoHidden ? "显示面板" : "展开面板")
        menu.addItem(NSMenuItem(title: toggleTitle, action: #selector(togglePanelFromMenu), keyEquivalent: ""))

        let autoHide = NSMenuItem(title: "空闲 3 分钟自动隐藏", action: #selector(toggleAutoHideFromMenu), keyEquivalent: "")
        autoHide.state = model.autoHideEnabled ? .on : .off
        menu.addItem(autoHide)

        let sound = NSMenuItem(title: "音效", action: #selector(toggleSoundFromMenu), keyEquivalent: "")
        sound.state = model.soundEnabled ? .on : .off
        menu.addItem(sound)

        let launch = NSMenuItem(title: "开机自启动", action: #selector(toggleLaunchAtLoginFromMenu), keyEquivalent: "")
        launch.state = model.launchAtLogin ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        if case .connected = model.phoneLink {
            let live = NSMenuItem(title: "灵动岛实时推送", action: #selector(togglePhoneLiveActivityFromMenu), keyEquivalent: "")
            live.state = model.phoneLiveActivityEnabled ? .on : .off
            menu.addItem(live)

            let alerts = NSMenuItem(title: "状态变更提醒", action: #selector(togglePhoneLiveAlertsFromMenu), keyEquivalent: "")
            alerts.state = model.phoneLiveAlertsEnabled ? .on : .off
            alerts.isEnabled = model.phoneLiveActivityEnabled
            menu.addItem(alerts)

            let approvals = NSMenuItem(title: "手机端审批", action: #selector(togglePhoneApprovalsFromMenu), keyEquivalent: "")
            approvals.state = model.phoneApprovalsEnabled ? .on : .off
            menu.addItem(approvals)
            menu.addItem(.separator())
        }

        let screens = NSMenuItem(title: "优先显示器", action: nil, keyEquivalent: "")
        screens.submenu = makeScreenMenu()
        menu.addItem(screens)
        menu.addItem(NSMenuItem(title: "悬浮窗设置…", action: #selector(openPanelSettingsFromMenu), keyEquivalent: ""))
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "退出 CodelightPro", action: #selector(quitFromMenu), keyEquivalent: "q"))
        menu.items.forEach { $0.target = self }
        return menu
    }

    private func makeScreenMenu() -> NSMenu {
        let menu = NSMenu()
        let follow = NSMenuItem(title: "跟随拖动位置", action: #selector(selectPreferredScreenFromMenu(_:)), keyEquivalent: "")
        follow.state = model.preferredScreenID == nil ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())

        for screen in model.screens {
            let item = NSMenuItem(title: "\(screen.name)（\(screen.kindLabel)）",
                                  action: #selector(selectPreferredScreenFromMenu(_:)), keyEquivalent: "")
            item.representedObject = screen.id
            item.state = model.preferredScreenID == screen.id ? .on : .off
            menu.addItem(item)
        }
        if let id = model.preferredScreenID, !model.screens.contains(where: { $0.id == id }) {
            let item = NSMenuItem(title: "\(model.preferredScreenName ?? "未知显示器")（未连接）",
                                  action: #selector(selectPreferredScreenFromMenu(_:)), keyEquivalent: "")
            item.representedObject = id
            item.state = .on
            menu.addItem(item)
        }
        menu.items.forEach { $0.target = self }
        return menu
    }

    @objc private func selectPreferredScreenFromMenu(_ sender: NSMenuItem) {
        model.preferredScreenID = sender.representedObject as? String
    }

    @objc private func openPanelSettingsFromMenu() {
        showPanelSettings()
    }

    @objc private func togglePanelFromMenu() {
        showStrip()
        toggleExpanded()
    }

    private func toggleExpanded() {
        if model.displayMode == .island && !model.isExpanded {
            // Grow the window first, outside the animation. If the hosting
            // view picked up the new size inside the spring, SwiftUI would
            // animate the root's size too and — since the root is centred in
            // the window — the island would appear to open from its centre.
            islandShrinkTask?.cancel()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                setIslandFrame(expanded: true)
                panel.contentView?.layoutSubtreeIfNeeded()
            }
        }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
            model.isExpanded.toggle()
        }
    }

    @objc private func toggleAutoHideFromMenu() {
        model.autoHideEnabled.toggle()
    }

    @objc private func toggleSoundFromMenu() {
        model.soundEnabled.toggle()
    }

    @objc private func toggleLaunchAtLoginFromMenu() {
        model.launchAtLogin.toggle()
    }

    @objc private func togglePhoneLiveActivityFromMenu() {
        model.phoneLiveActivityEnabled.toggle()
    }

    @objc private func togglePhoneLiveAlertsFromMenu() {
        model.phoneLiveAlertsEnabled.toggle()
    }

    @objc private func togglePhoneApprovalsFromMenu() {
        model.phoneApprovalsEnabled.toggle()
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    private func tintColor(for state: AgentState) -> NSColor {
        switch state {
        case .working:
            return NSColor(calibratedRed: 0.15, green: 0.6, blue: 0.95, alpha: 1)
        case .completed:
            return NSColor(calibratedRed: 0.32, green: 0.85, blue: 0.92, alpha: 1)
        case .needsApproval, .error:
            return NSColor(calibratedRed: 1, green: 0.34, blue: 0.31, alpha: 1)
        case .idle:
            return NSColor(calibratedRed: 0.95, green: 0.9, blue: 0.28, alpha: 1)
        case .offline:
            return .secondaryLabelColor
        }
    }

    private func startApprovals() {
        approvalCenter = ApprovalCenter(model: model, sync: sync)
        approvalCenter.onChange = { [weak self] added in
            guard let self else { return }
            // The phone should see (or drop) the request right away.
            self.poller.pushStatusNow()
            if added { self.presentApprovals() }
        }
        model.onDecideApproval = { [weak self] id, decision in
            self?.approvalCenter.decide(id, decision)
        }
        approvalCenter.start()
    }

    /// A new permission request: make sure the panel is on screen and open
    /// so its approval card is visible.
    private func presentApprovals() {
        lastActiveAt = Date()
        showStrip()
        guard !model.isExpanded, model.morph == nil else { return }
        collapseTask?.cancel()
        collapseTask = nil
        toggleExpanded()
    }

    private func startMouseTracking() {
        mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
        }

        mouseTrackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await MainActor.run {
                    guard self?.model.isExpanded == true else { return }
                    self?.handleMouseMoved()
                }
            }
        }
    }

    private func handleMouseMoved() {
        // Expansion is click-driven (tapping the strip). Here we only auto-collapse
        // the expanded panel a moment after the mouse leaves it.
        guard model.isExpanded else {
            collapseTask?.cancel()
            collapseTask = nil
            return
        }

        // Keep it open under a popover or while a request awaits an answer.
        if model.isSettingsPopoverPresented || !model.approvals.isEmpty {
            collapseTask?.cancel()
            collapseTask = nil
            return
        }

        let mouse = NSEvent.mouseLocation

        if panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) {
            collapseTask?.cancel()
            collapseTask = nil
        } else if collapseTask == nil {
            collapseTask = Task {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }

                await MainActor.run {
                    guard !self.model.isSettingsPopoverPresented, self.model.approvals.isEmpty else {
                        self.collapseTask = nil
                        return
                    }

                    withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                        self.model.isExpanded = false
                    }
                    self.collapseTask = nil
                }
            }
        }
    }

    /// Called after every poll. Keeps the strip visible while any agent is busy,
    /// then fades it out once it's been idle past `autoHideAfter`.
    private func evaluateAutoHide() {
        let state = model.overall
        let isActive = state == .working || state == .needsApproval || state == .completed
            || !model.approvals.isEmpty

        if isActive {
            lastActiveAt = Date()
            showStrip()
            return
        }

        // Setting off → always visible.
        guard model.autoHideEnabled else {
            showStrip()
            return
        }

        // Never hide while the user has it open; keep the grace window fresh.
        if model.isExpanded {
            lastActiveAt = Date()
            return
        }

        if Date().timeIntervalSince(lastActiveAt) >= autoHideAfter {
            hideStrip()
        }
    }

    private func showStrip() {
        guard isAutoHidden else { return }
        isAutoHidden = false
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 1
        }
    }

    private func hideStrip() {
        guard !isAutoHidden, !model.isExpanded else { return }
        isAutoHidden = true
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.35
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isAutoHidden else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    // MARK: - Display mode

    private var targetScreen: NSScreen {
        NSScreen.screens.first { $0.displayID == targetDisplayID } ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The preferred display, if one is chosen and currently connected.
    private var preferredScreen: ScreenInfo? {
        model.screens.first { $0.id == model.preferredScreenID }
    }

    /// Displays were plugged / unplugged / rearranged. When the preferred
    /// display comes (back), the panel returns to it; otherwise it just stays
    /// put (or falls back to the main display if its own went away).
    private func screensDidChange() {
        let before = Set(model.screens.map(\.id))
        model.screens = ScreenInfo.connected()
        if let preferred = preferredScreen, !before.contains(preferred.id) {
            moveToPreferredScreen()
        } else {
            applyDisplayMode()
        }
    }

    /// Moves the panel, in whichever mode it's in, onto the preferred display.
    /// Dragging it elsewhere afterwards is allowed; it comes back on the next
    /// launch or when the preferred display is reconnected.
    private func moveToPreferredScreen() {
        guard let preferred = preferredScreen, model.morph == nil, pullMonitor == nil else { return }
        guard panel.screen?.displayID != preferred.displayID || targetDisplayID != preferred.displayID else { return }
        targetDisplayID = preferred.displayID
        applyDisplayMode(forcePlacement: true)
    }

    /// Puts the panel where the current mode lives on the target screen. The
    /// mode itself only changes by dragging (see `morph`). Cheap and
    /// idempotent: called on launch, when displays are plugged / unplugged
    /// and after the strip is dragged to another screen.
    private func applyDisplayMode(forcePlacement: Bool = false) {
        // A morph owns the window until it finishes.
        guard model.morph == nil else { return }
        let screen = targetScreen
        targetDisplayID = screen.displayID
        model.islandMetrics = IslandMetrics(screen: screen)

        configurePanel(for: model.displayMode)
        switch model.displayMode {
        case .island:
            layoutPanel(animate: false)
        case .floating:
            if forcePlacement || panel.screen?.displayID != screen.displayID {
                placeFloatingTopRight(on: screen)
            }
        }
    }

    private static let islandLevel = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)

    private func configurePanel(for mode: DisplayMode) {
        switch mode {
        case .island:
            // Above the menu bar, pinned to the notch. Dragging is handled by
            // `handleIslandPointer` so a click and a drag can't be confused.
            panel.level = Self.islandLevel
            panel.dragsWindow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        case .floating:
            panel.level = .floating
            panel.dragsWindow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    /// The floating strip was dragged. Once the mouse is released: dropped at
    /// the top centre of a screen → island there; otherwise it adopts the
    /// screen it landed on.
    private func panelDidMove() {
        // Only user drags hold the button; our own setFrame calls don't.
        // Island drags are handled by `handleIslandPointer`.
        guard model.displayMode == .floating, model.morph == nil, pullMonitor == nil,
              NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dragSettleTask?.cancel()
        dragSettleTask = Task { [weak self] in
            while NSEvent.pressedMouseButtons != 0 {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            self?.panelDidSettle()
        }
    }

    private func panelDidSettle() {
        let frame = panel.frame
        let dropPoint = NSPoint(x: frame.midX, y: frame.maxY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(dropPoint) }) ?? panel.screen,
              let id = screen.displayID else { return }

        if isInIslandDropZone(frame, on: screen) {
            let metrics = IslandMetrics(screen: screen)
            let body = metrics.bodySize(expanded: false)
            let island = NSRect(x: screen.frame.midX - body.width / 2, y: screen.frame.maxY - body.height,
                                width: body.width, height: body.height)
            model.islandMetrics = metrics
            morph(to: .island, shell: island, on: screen)
        } else if id != targetDisplayID {
            targetDisplayID = id
            applyDisplayMode()
        }
    }

    /// A press on the island that doesn't move is a click (expand / collapse).
    /// Once it moves a few points it's a drag: the island morphs into the
    /// floating strip right under the cursor, which then follows the mouse.
    private func handleIslandPointer(_ phase: IslandPointerPhase) {
        guard pullMonitor == nil, model.morph == nil else { return }
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .moved:
            guard let start = islandPressStart else {
                islandPressStart = mouse
                return
            }
            guard hypot(mouse.x - start.x, mouse.y - start.y) >= 4 else { return }
            islandPressStart = nil
            pullOutOfIsland(mouse: mouse)
        case .released:
            // Nil when the press already turned into a pull-out.
            guard islandPressStart != nil else { return }
            islandPressStart = nil
            if model.displayMode == .island {
                toggleExpanded()
            }
        }
    }

    private func pullOutOfIsland(mouse: NSPoint) {
        let screen = targetScreen

        // The strip appears just below the menu bar, centred on the cursor.
        let vis = screen.visibleFrame
        let size = NSSize(width: stripSize.width - Theme.panelInset * 2, height: stripSize.height - Theme.panelInset * 2)
        let x = min(max(mouse.x - size.width / 2, vis.minX + 16), vis.maxX - 16 - size.width)
        let top = min(vis.maxY - 4, mouse.y + size.height / 2)
        morph(to: .floating, shell: NSRect(x: x, y: top - size.height, width: size.width, height: size.height), on: screen)

        lastPullMouse = mouse
        pullMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePull(event)
            }
            return event
        }
    }

    private func handlePull(_ event: NSEvent) {
        let mouse = NSEvent.mouseLocation
        if let last = lastPullMouse {
            let origin = panel.frame.origin
            panel.setFrameOrigin(NSPoint(x: origin.x + mouse.x - last.x, y: origin.y + mouse.y - last.y))
        }
        lastPullMouse = mouse

        guard event.type == .leftMouseUp else { return }
        if let pullMonitor {
            NSEvent.removeMonitor(pullMonitor)
        }
        pullMonitor = nil
        lastPullMouse = nil
        // A pulled-out strip stays a strip wherever it's dropped.
        if model.morph == nil, let id = panel.screen?.displayID {
            targetDisplayID = id
        }
    }

    // MARK: - Island ⇄ floating morph

    /// Where the visible shell is right now, in screen coordinates.
    private var currentShellFrame: NSRect {
        let frame = panel.frame
        switch model.displayMode {
        case .floating:
            return frame.insetBy(dx: Theme.panelInset, dy: Theme.panelInset)
        case .island:
            let body = model.islandMetrics.bodySize(expanded: model.isExpanded,
                                                    extraHeight: model.expandedExtraHeight)
            return NSRect(x: frame.midX - body.width / 2, y: frame.maxY - body.height,
                          width: body.width, height: body.height)
        }
    }

    /// Springs the shell from where it is to `destination` (screen coords).
    /// The window is first grown, without animation, to cover both shells;
    /// the steady view of `mode` takes over once the spring settles.
    private func morph(to mode: DisplayMode, shell destination: NSRect, on screen: NSScreen) {
        morphFinishTask?.cancel()
        islandShrinkTask?.cancel()
        collapseTask?.cancel()
        collapseTask = nil
        targetDisplayID = screen.displayID

        let source = currentShellFrame
        let pad = IslandMetrics.glowPadding
        let window = source.union(destination).insetBy(dx: -pad, dy: -pad)
        func local(_ rect: NSRect) -> CGRect {
            CGRect(x: rect.minX - window.minX, y: window.maxY - rect.maxY, width: rect.width, height: rect.height)
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.morph = PanelMorph(from: model.displayMode, to: mode,
                                     fromRect: local(source), toRect: local(destination))
            model.isExpanded = false
            // Above the menu bar for the whole ride, and not draggable by
            // the background while the shell is in flight.
            panel.level = Self.islandLevel
            panel.dragsWindow = false
            panel.setFrame(window, display: true)
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        // Next turn, so the start state has rendered before it animates.
        DispatchQueue.main.async { [weak self] in
            withAnimation(PanelMorphView.animation) {
                self?.model.morph?.atDestination = true
            }
        }
        morphFinishTask = Task { [weak self] in
            try? await Task.sleep(for: PanelMorphView.duration)
            guard !Task.isCancelled else { return }
            self?.finishMorph()
        }
    }

    private func finishMorph() {
        guard let morph = model.morph else { return }
        // The window may have moved meanwhile (a pulled-out strip follows the
        // mouse), so resolve the destination against where it is now.
        let window = panel.frame
        let shell = NSRect(x: window.minX + morph.toRect.minX, y: window.maxY - morph.toRect.maxY,
                           width: morph.toRect.width, height: morph.toRect.height)

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            model.morph = nil
            model.displayMode = morph.to
            configurePanel(for: morph.to)
            switch morph.to {
            case .island:
                setIslandFrame(expanded: false)
            case .floating:
                panel.setFrame(shell.insetBy(dx: -Theme.panelInset, dy: -Theme.panelInset), display: true)
                if pullMonitor == nil, let id = panel.screen?.displayID {
                    targetDisplayID = id
                }
            }
            panel.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// The top edge reaches the menu bar and it's roughly under the notch.
    private func isInIslandDropZone(_ frame: NSRect, on screen: NSScreen) -> Bool {
        let menuBar = max(screen.menuBarHeight, 24)
        let reachesTop = frame.maxY >= screen.frame.maxY - menuBar - 16
        let halfZone = IslandMetrics(screen: screen).collapsedWidth / 2 + 100
        return reachesTop && abs(frame.midX - screen.frame.midX) <= halfZone
    }

    private func resize(expanded: Bool) {
        guard model.morph == nil else { return }
        layoutPanel(animate: true)
    }

    private func layoutPanel(animate: Bool) {
        switch model.displayMode {
        case .island:
            // SwiftUI animates the island itself; the window just has to be
            // big enough. Grow it at once, shrink it after the collapse spring.
            islandShrinkTask?.cancel()
            guard animate, !model.isExpanded else {
                setIslandFrame(expanded: model.isExpanded)
                return
            }
            islandShrinkTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self, !Task.isCancelled,
                      self.model.displayMode == .island, !self.model.isExpanded else { return }
                self.setIslandFrame(expanded: false)
            }
        case .floating:
            setFloatingFrame(floatingSize(), animate: animate)
        }
    }

    private func setFloatingFrame(_ size: NSSize, animate: Bool) {
        let old = panel.frame
        // Keep the top-right corner fixed so it grows down/left.
        var origin = NSPoint(x: old.maxX - size.width, y: old.maxY - size.height)

        if let screen = panel.screen ?? NSScreen.main {
            let vis = screen.visibleFrame.insetBy(dx: 16, dy: 16)
            origin.x = min(max(origin.x, vis.minX), vis.maxX - size.width)
            origin.y = min(max(origin.y, vis.minY), vis.maxY - size.height)
        }

        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: animate)
    }

    private func setIslandFrame(expanded: Bool, extraHeight: CGFloat? = nil) {
        let screen = targetScreen
        let extra = expanded ? extraHeight ?? model.expandedExtraHeight : 0
        let size = model.islandMetrics.windowSize(expanded: expanded, extraHeight: extra)
        // Top edge flush with the screen, centred on the notch.
        let origin = NSPoint(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height)
        let frame = NSRect(origin: origin, size: size)
        guard panel.frame != frame else { return }
        panel.setFrame(frame, display: true)
    }

    private func floatingSize(extraHeight: CGFloat? = nil) -> NSSize {
        guard model.isExpanded else { return stripSize }
        return NSSize(width: bigSize.width, height: bigSize.height + (extraHeight ?? model.expandedExtraHeight))
    }

    /// The panel grows downward for the phone switches, animated like
    /// expanding. Island: the window grows first, then the shell springs
    /// down (same as `toggleExpanded()`). Floating: the window animates its
    /// height and the rows are revealed as it grows (`isPhoneOptionsResizing`
    /// pins the cards above). Closing runs the same steps backwards.
    private func setPhoneOptionsOpen(_ open: Bool) {
        guard model.isExpanded, model.morph == nil, open != model.isPhoneOptionsVisible else { return }
        phoneOptionsTask?.cancel()
        islandShrinkTask?.cancel()
        let fade = Animation.easeOut(duration: 0.25)

        switch model.displayMode {
        case .island:
            if open {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    setIslandFrame(expanded: true, extraHeight: IslandMetrics.phoneOptionsHeight)
                    panel.contentView?.layoutSubtreeIfNeeded()
                }
            }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.82)) {
                model.isPhoneOptionsOpen = open
                model.isPhoneOptionsVisible = open
            }
            if !open {
                islandShrinkTask = Task { [weak self] in
                    try? await Task.sleep(for: .milliseconds(450))
                    guard let self, !Task.isCancelled, self.model.displayMode == .island,
                          self.model.isExpanded, !self.model.isPhoneOptionsOpen else { return }
                    self.setIslandFrame(expanded: true)
                }
            }

        case .floating:
            model.isPhoneOptionsResizing = true
            withAnimation(fade) { model.isPhoneOptionsVisible = open }
            if open { model.isPhoneOptionsOpen = true }
            // Next turn, so the pinned layout is in place before the window moves.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.model.isExpanded, self.model.displayMode == .floating else { return }
                self.setFloatingFrame(self.floatingSize(extraHeight: open ? IslandMetrics.phoneOptionsHeight : 0),
                                      animate: true)
            }
            phoneOptionsTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled else { return }
                if !open { self.model.isPhoneOptionsOpen = false }
                self.model.isPhoneOptionsResizing = false
            }
        }
    }

    private func placeFloatingTopRight(on screen: NSScreen) {
        let size = floatingSize()
        let vis = screen.visibleFrame
        let origin = NSPoint(
            x: vis.maxX - size.width - 24,
            y: vis.maxY - size.height - 24
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    /// The phone sync window. Opens straight onto a live QR code (made on
    /// the spot when there isn't one) and closes itself once a phone pairs.
    private func showSettings() {
        defer { startPairingIfNeeded() }
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CodelightPro 手机同步"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }

    private func showPanelSettings() {
        if let panelSettingsWindow {
            panelSettingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 390, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "CodelightPro 悬浮窗设置"
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: PanelSettingsView(model: model))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panelSettingsWindow = window
    }

    private func startPairingIfNeeded() {
        let hasLiveCode = model.pairing.qrDataURL != nil && (model.pairing.expiresAt ?? .distantPast) > Date()
        // Without a saved relay the default localhost would only fail.
        let serverConfigured = UserDefaults.standard.string(forKey: "sync.serverURL") != nil
        guard serverConfigured, !hasLiveCode, !model.pairing.isLoading else { return }
        startPairing(serverURL: model.pairing.serverURL)
    }

    /// While the QR code is up, upload every 2 s: the relay's reply carries
    /// the number of linked phones, and a new one means the scan worked.
    /// `baseline` is nil until the relay has reported a count at least once.
    private func watchForPairing(baseline initial: Int?) {
        pairingWatch?.cancel()
        pairingWatch = Task { [weak self] in
            var baseline = initial
            while let self, !Task.isCancelled,
                  self.settingsWindow?.isVisible == true,
                  (self.model.pairing.expiresAt ?? .distantPast) > Date() {
                self.poller.pushStatusNow()
                try? await Task.sleep(for: .seconds(2))
                guard let count = self.model.pairing.linkedMobileCount else { continue }
                guard let known = baseline else {
                    baseline = count
                    continue
                }
                guard count > known else { continue }
                self.model.pairing.message = "已连接 iPhone"
                self.model.pairing.pairedAt = Date()
                if self.model.soundEnabled { SoundPlayer.shared.playPaired() }
                // Let the success animation play out first.
                try? await Task.sleep(for: .milliseconds(2600))
                self.settingsWindow?.close()
                self.model.pairing.qrDataURL = nil
                self.model.pairing.pairURL = nil
                self.model.pairing.expiresAt = nil
                self.model.pairing.pairedAt = nil
                return
            }
        }
    }

    private func startPairing(serverURL: String) {
        model.pairing.isLoading = true
        model.pairing.message = "正在连接服务器并生成二维码…"
        model.pairing.pairedAt = nil
        model.pairing.qrDataURL = nil
        model.pairing.pairURL = nil
        model.pairing.expiresAt = nil

        Task {
            do {
                let response = try await sync.startPairing(serverURL: serverURL)
                model.pairing.isLoading = false
                model.pairing.message = "二维码已生成，请用 iPhone 上的 Codelight 扫描。"
                model.pairing.qrDataURL = response.qrDataUrl
                model.pairing.pairURL = response.pairUrl
                model.pairing.expiresAt = Date(timeIntervalSince1970: response.expiresAt)
                // Upload the current state right away so the phone has
                // something to show the moment it finishes pairing.
                poller.pushStatusNow()
                watchForPairing(baseline: model.pairing.linkedMobileCount)
            } catch {
                model.pairing.isLoading = false
                model.pairing.message = error.localizedDescription
            }
        }
    }
}

/// The panel window. Borderless, but also exempt from AppKit's "keep below
/// the menu bar" constraint so the island can sit flush with the screen top.
final class StripPanel: NSPanel {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    /// Drag the window from anywhere on it. Done by hand rather than with
    /// `isMovableByWindowBackground`: a system window drag takes part in
    /// macOS window tiling, so pausing at the top edge (where the strip is
    /// dropped to become the island) would make it fill the screen.
    var dragsWindow = false

    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    /// The press, held back until we know it's a click and not a drag.
    private var pendingMouseDown: NSEvent?

    override func sendEvent(_ event: NSEvent) {
        guard dragsWindow || dragStart != nil else { return super.sendEvent(event) }
        switch event.type {
        case .leftMouseDown:
            dragStart = (NSEvent.mouseLocation, frame.origin)
            pendingMouseDown = event
        case .leftMouseDragged:
            guard let start = dragStart else { return super.sendEvent(event) }
            let mouse = NSEvent.mouseLocation
            if pendingMouseDown != nil {
                guard hypot(mouse.x - start.mouse.x, mouse.y - start.mouse.y) >= 3 else { return }
                pendingMouseDown = nil
            }
            var origin = NSPoint(x: start.origin.x + mouse.x - start.mouse.x,
                                 y: start.origin.y + mouse.y - start.mouse.y)
            // Stay below the menu bar, like a system drag would.
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
                origin.y = min(origin.y, screen.visibleFrame.maxY - frame.height)
            }
            setFrameOrigin(origin)
        case .leftMouseUp:
            guard dragStart != nil else { return super.sendEvent(event) }
            if let down = pendingMouseDown {
                super.sendEvent(down)
                super.sendEvent(event)
            }
            dragStart = nil
            pendingMouseDown = nil
        default:
            super.sendEvent(event)
        }
    }
}

import AppKit
import PortpeekCore
import ServiceManagement
import SwiftUI

// MARK: Model

@MainActor
final class PortsModel: ObservableObject {
    @Published var entries: [PortEntry] = []
    @Published var loaded = false
    @Published var stopping: Set<Int32> = []      // asked to quit, not gone yet
    @Published var stubborn: Set<Int32> = []      // ignored a polite request; the next press forces it
    @Published var stoppingContainers: Set<String> = []   // container ids being stopped by their runtime
    @Published var expanded: String?              // the one row showing its details, by entry id
    @Published var showBackground: Bool {
        didSet { UserDefaults.standard.set(showBackground, forKey: "showBackground") }
    }

    /// The row under the pointer, so a right-click knows which port it is about.
    private(set) var hovered: PortEntry?

    private var scanning = false
    private var rescan = false
    private var focusing = false

    init() {
        showBackground = UserDefaults.standard.bool(forKey: "showBackground")
    }

    var visible: [PortEntry] {
        showBackground ? entries : entries.filter { !$0.isBackground }
    }

    /// How tall the list wants to be, projects, their headings and an open row's details included.
    var contentHeight: CGFloat {
        let rows = visible
        return Metrics.contentHeight(Projects.sections(rows), expanded: rows.first { $0.id == expanded })
    }

    /// Opens a row's details, or closes them if they are already open. One row at a time.
    func toggle(_ entry: PortEntry) {
        expanded = expanded == entry.id ? nil : entry.id
    }

    func isStopping(_ entry: PortEntry) -> Bool {
        switch entry.stopAction {
        case .signal: return stopping.contains(entry.pid)
        case .container(let container): return stoppingContainers.contains(container.id)
        case .nothing: return false
        }
    }

    var backgroundCount: Int {
        entries.filter(\.isBackground).count
    }

    func refresh() {
        guard !scanning else {
            rescan = true
            return
        }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = PortScanner.scan()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finish(found) }
            }
        }
    }

    private func finish(_ found: [PortEntry]) {
        scanning = false
        if entries != found { entries = found }
        loaded = true
        let alive = Set(found.map(\.pid))
        stopping.formIntersection(alive)
        stubborn.formIntersection(alive)
        if let expanded, !found.contains(where: { $0.id == expanded }) { self.expanded = nil }
        if rescan {
            rescan = false
            refresh()
        }
    }

    func open(_ entry: PortEntry) {
        guard let url = entry.url else { return }
        NSWorkspace.shared.open(url)
    }

    func hover(_ entry: PortEntry, _ inside: Bool) {
        if inside {
            hovered = entry
        } else if hovered?.id == entry.id {
            hovered = nil
        }
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Brings the app the server was started from to the front and, for Terminal and iTerm2, the tab it is running in.
    func showOrigin(of entry: PortEntry) {
        guard let origin = entry.startedFrom, origin.canActivate else { return }
        let app = origin.pid.flatMap { NSRunningApplication(processIdentifier: $0) }
            ?? origin.bundleIdentifier.flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }
        guard let app else { return }
        if !app.activate(options: [.activateAllWindows]), let url = app.bundleURL {
            NSWorkspace.shared.open(url)
        }

        // The tab is a nicety on top. It needs Automation permission, which macOS asks for the first time;
        // if the answer is no, the app has still come forward and nothing else happens.
        guard !focusing, let kind = origin.terminalScripting,
              let script = TerminalFocus.script(for: kind, tty: entry.tty) else { return }
        focusing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = ["-e", script]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            if (try? task.run()) != nil { task.waitUntilExit() }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.focusing = false }
            }
        }
    }

    func stop(_ entry: PortEntry) {
        switch entry.stopAction {
        case .signal:
            signal(entry.pid, force: stubborn.contains(entry.pid))
        case .container(let container):
            stop(container)
        case .nothing:
            // The process is a container runtime. Signalling it would take every container down.
            break
        }
    }

    /// Asks the runtime to stop one container. That can take ten seconds, so it happens off the main thread.
    private func stop(_ container: ContainerInfo) {
        guard stoppingContainers.insert(container.id).inserted else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            Containers.stop(container)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.stoppingContainers.remove(container.id)
                    self.refresh()
                }
            }
        }
    }

    /// Asks every process in a project to quit. Any that ignore it get a Force button on their own row, as usual.
    func stopAll(_ group: ProjectGroup) {
        for pid in Projects.stopTargets(directory: group.directory, in: entries) where !stopping.contains(pid) {
            signal(pid, force: false)
        }
    }

    private func signal(_ pid: Int32, force: Bool) {
        guard ProcessControl.stop(pid, force: force) else {
            refresh()
            return
        }
        stopping.insert(pid)
        for delay in [0.3, 1.0, 2.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
        // Still here after a polite request: offer to force it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.stopping.contains(pid) else { return }
                self.stopping.remove(pid)
                if ProcessControl.isRunning(pid) { self.stubborn.insert(pid) }
            }
        }
    }
}

// MARK: Window

final class CornerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // The shadow margin hangs off the edge of the screen; AppKit would otherwise push the window back on.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

@MainActor
final class CornerController: NSObject {
    let model = PortsModel()
    let state = PanelState()
    private var panel: CornerPanel!

    private var triggers: [(screen: NSScreen, rect: NSRect)] = []
    private var panelRect = NSRect.zero      // the visible panel, in screen coordinates
    private var keepRect = NSRect.zero       // the panel plus the way back to the corner
    private var activeScreen: NSScreen?

    private var pointerInside = false
    private var pending: DispatchWorkItem?
    private var pollTimer: Timer?
    private var ticks = 0
    private var menuOpen = false
    private var pinnedUntil = Date.distantPast

    private var corner: Corner {
        get { Corner(rawValue: UserDefaults.standard.string(forKey: "corner") ?? "") ?? .topRight }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "corner") }
    }

    func start() {
        state.corner = corner

        panel = CornerPanel(contentRect: NSRect(origin: .zero, size: Metrics.windowSize),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.isReleasedWhenClosed = false

        let host = FirstMouseHostingView(rootView: RootView(state: state, model: model, onMenu: { [weak self] in self?.showMenu(at: nil) }))
        host.safeAreaRegions = []
        panel.contentView = host

        layoutTriggers()
        place(on: NSScreen.main ?? NSScreen.screens[0])
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.layoutTriggers()
                if let screen = self?.activeScreen ?? NSScreen.main { self?.place(on: screen) }
            }
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.pointerMoved() }
            return event
        }
        NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.showMenu(at: event) }
            return nil
        }

        // There is no icon anywhere, so the first launch shows the panel and says how to bring it back.
        if !UserDefaults.standard.bool(forKey: "introduced") {
            UserDefaults.standard.set(true, forKey: "introduced")
            reveal(for: 8, hint: true)
        }
    }

    /// Opens the panel without the pointer being in the corner, for a few seconds.
    func reveal(for seconds: TimeInterval, hint: Bool = false) {
        state.hint = hint
        pinnedUntil = Date().addingTimeInterval(seconds)
        place(on: activeScreen ?? NSScreen.main ?? NSScreen.screens[0])
        setOpen(true)
    }

    // MARK: Layout

    private func layoutTriggers() {
        let corner = state.corner
        triggers = NSScreen.screens.map { screen in
            let f = screen.frame
            let size: CGFloat = 5
            let x = corner.isLeft ? f.minX - 2 : f.maxX - size
            let y = corner.isTop ? f.maxY - size : f.minY - 2
            return (screen, NSRect(x: x, y: y, width: size + 2, height: size + 2))
        }
    }

    /// Positions the window so the panel sits in the chosen corner of the usable area, clear of the menu bar and Dock.
    private func place(on screen: NSScreen) {
        activeScreen = screen
        let corner = state.corner
        let area = screen.visibleFrame
        let height = Metrics.height(content: model.contentHeight, hint: state.hint)
        let x = corner.isLeft ? area.minX + Metrics.inset : area.maxX - Metrics.inset - Metrics.width
        let y = corner.isTop ? area.maxY - Metrics.inset - height : area.minY + Metrics.inset
        panelRect = NSRect(x: x, y: y, width: Metrics.width, height: height)

        let size = Metrics.windowSize
        let windowX = corner.isLeft ? panelRect.minX - Metrics.margin : panelRect.maxX + Metrics.margin - size.width
        let windowY = corner.isTop ? panelRect.maxY + Metrics.margin - size.height : panelRect.minY - Metrics.margin
        panel.setFrame(NSRect(x: windowX, y: windowY, width: size.width, height: size.height), display: true)

        let trigger = triggers.first { $0.screen == screen }?.rect ?? panelRect
        keepRect = panelRect.union(trigger).insetBy(dx: -10, dy: -10)
    }

    // MARK: Pointer

    private func pointerMoved() {
        guard !menuOpen, panel != nil else { return }
        let point = NSEvent.mouseLocation
        let pinned = Date() < pinnedUntil

        let inside: Bool
        if state.open {
            inside = keepRect.contains(point) || pinned
            if pinned, panelRect.contains(point) {
                // The pointer has arrived; from here on the panel behaves normally.
                pinnedUntil = .distantPast
            }
        } else if let hit = triggers.first(where: { $0.rect.contains(point) }) {
            inside = true
            if activeScreen != hit.screen || !pointerInside {
                model.refresh()            // have fresh numbers by the time it opens
                place(on: hit.screen)
            }
        } else {
            inside = false
        }

        // Outside the visible panel the window must not swallow clicks meant for whatever is underneath.
        panel.ignoresMouseEvents = !(state.open && panelRect.contains(point))
        guard inside != pointerInside else { return }
        pointerInside = inside

        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.setOpen(inside) }
        }
        pending = work
        // A beat before opening so a pointer thrown at the corner on the way elsewhere does not trigger it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (inside ? 0.14 : 0.35), execute: work)
    }

    private func setOpen(_ open: Bool) {
        if !open { state.hint = state.hint && Date() < pinnedUntil }
        guard state.open != open else { return }
        state.open = open
        pointerInside = open
        if open {
            model.expanded = nil               // it always opens as the plain list
            model.refresh()
        }

        pollTimer?.invalidate()
        pollTimer = nil
        ticks = 0
        if open {
            // Mouse-moved events aren't guaranteed while the pointer rests over our own panel.
            let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pollTimer = timer
        } else {
            panel.ignoresMouseEvents = true
        }
    }

    private func tick() {
        ticks += 1
        if ticks % 10 == 0 { model.refresh() }     // every two seconds while open, never while closed
        if let screen = activeScreen {
            // The list may have grown or shrunk; keep the hit area matched to what is drawn.
            let height = Metrics.height(content: model.contentHeight, hint: state.hint)
            if abs(height - panelRect.height) > 0.5 { place(on: screen) }
        }
        pointerMoved()
    }

    // MARK: Menu

    private func showMenu(at event: NSEvent?) {
        guard let view = panel.contentView else { return }
        let menu = NSMenu()

        // Over a row, the menu starts with that port.
        if event != nil, let entry = model.hovered, model.visible.contains(where: { $0.id == entry.id }) {
            let address = NSMenuItem(title: "Copy \(entry.address)", action: #selector(copyText(_:)), keyEquivalent: "")
            address.target = self
            address.representedObject = entry.address
            menu.addItem(address)
            if let url = entry.url {
                let link = NSMenuItem(title: "Copy \(url.absoluteString)", action: #selector(copyText(_:)), keyEquivalent: "")
                link.target = self
                link.representedObject = url.absoluteString
                menu.addItem(link)
            }
            // How long it has been up has no room on the row, so it is said here.
            if let uptime = Uptime.phrase(entry.uptime) {
                let item = NSMenuItem(title: uptime, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let cornerItem = NSMenuItem(title: "Corner", action: nil, keyEquivalent: "")
        let corners = NSMenu()
        for option in Corner.allCases {
            let item = NSMenuItem(title: option.title, action: #selector(chooseCorner(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = option.rawValue
            item.state = option == state.corner ? .on : .off
            corners.addItem(item)
        }
        cornerItem.submenu = corners
        menu.addItem(cornerItem)

        let background = NSMenuItem(title: "Show Background Ports", action: #selector(toggleBackground), keyEquivalent: "")
        background.target = self
        background.state = model.showBackground ? .on : .off
        menu.addItem(background)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Portpeek", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)

        let location = event?.locationInWindow ?? panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        menuOpen = true
        menu.popUp(positioning: nil, at: view.convert(location, from: nil), in: view)
        menuOpen = false
        pointerMoved()
    }

    @objc private func chooseCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let chosen = Corner(rawValue: raw), chosen != state.corner else { return }
        // Close where it was, then show itself in its new home so the move is visible.
        state.open = false
        pointerInside = false
        corner = chosen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.state.corner = chosen
                self.layoutTriggers()
                self.reveal(for: 3)
            }
        }
    }

    @objc private func copyText(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { model.copy(text) }
    }

    @objc private func toggleBackground() {
        model.showBackground.toggle()
    }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change the login item"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

// MARK: App

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = CornerController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        if let directory = value(after: "--snapshot") {
            Snapshot.render(to: directory, scale: value(after: "--scale").flatMap(Double.init).map { CGFloat($0) } ?? 2,
                            checks: args.contains("--checks"))
        } else {
            controller.start()
        }
    }

    // Opening the app again while it is running is the way to find it when the corner is forgotten.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        controller.reveal(for: 4)
        return false
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

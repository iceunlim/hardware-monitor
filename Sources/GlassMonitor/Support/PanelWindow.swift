import SwiftUI
import AppKit
import Core

/// The real desktop blur behind the panel. `glassEffect` samples whatever is
/// already in the window, so without this layer the cards would sit on grey.
struct BlurBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Borderless, non-activating window at menu-bar level.
///
/// `NSPopover` was the wrong tool here: it always draws its arrow, and
/// `.transient` only dismisses while the owning app is active. A menu bar extra
/// normally never activates its app, so the popover stayed visible when people
/// clicked another app. A panel has neither problem: it has no arrow, it can
/// become key without stealing focus, and it is dismissed by explicit outside
/// click tracking instead of relying on activation changes.
final class MenuBarPanel: NSPanel {
    /// Called for Escape and other "cancel" gestures while the panel is key.
    var onCancel: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        isMovable = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        // The panel closes itself when a click lands outside it, so AppKit's
        // activation-based hiding would only fight that behavior.
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        title = AppInfo.displayName
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        // A non-key panel otherwise swallows the click that makes it key.
        if event.type == .leftMouseDown, !isKeyWindow {
            makeKey()
        }
        super.sendEvent(event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Owns the panel, keeps it anchored under the status item, and installs the
/// dismissal monitors only while it is on screen.
///
/// The monitors are the important part: a global mouse monitor sees clicks in
/// other apps (mouse events do not need Accessibility permission), while the
/// local monitor handles clicks inside this app, Escape, and keeps menu
/// tracking (`NSMenu` popups such as the gear menu) from closing the panel.
@MainActor
final class PanelController {
    private let statusItem: NSStatusItem
    private let panel: MenuBarPanel
    private let width: CGFloat
    private let maxHeight: CGFloat
    private var height: CGFloat

    private var monitors: [Any] = []
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?

    private(set) var isShown = false

    init(statusItem: NSStatusItem, monitor: HardwareMonitor, settings: AppSettings) {
        self.statusItem = statusItem
        width = Panel.cardWidth * 2 + Panel.spacing * 3
        // Use the tightest screen so the same SwiftUI height cap is valid
        // wherever the status item currently lives.
        let usableHeight = NSScreen.screens.map(\.visibleFrame.height).min() ?? 900
        maxHeight = max(320, usableHeight - 24)
        height = min(640, maxHeight)

        panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: height))
        let host = NSHostingView(rootView: RootView(maxHeight: maxHeight, onHeight: { [weak self] height in
            self?.contentHeightChanged(height)
        })
        .environmentObject(monitor)
        .environmentObject(settings)
        .frame(width: width))
        panel.contentView = host
        panel.onCancel = { [weak self] in self?.hide() }
        panel.setContentSize(NSSize(width: width, height: height))
    }

    func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        guard !isShown, let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: width, height: height)
        let frame = self.frame(anchor: anchor, visible: visible)
        panel.setFrame(frame, display: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        isShown = true
        button.highlight(true)
        installMonitors()
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        removeMonitors()
        statusItem.button?.highlight(false)
        panel.orderOut(nil)
        panel.alphaValue = 1
    }

    /// The status item changes width whenever a readout is added or removed.
    /// Re-run the centering math so the panel keeps hanging under its icon.
    func reanchor() {
        guard isShown,
              let button = statusItem.button,
              let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let screen = buttonWindow.screen ?? NSScreen.main else { return }
        panel.setFrame(frame(anchor: anchor, visible: screen.visibleFrame), display: true)
    }

    /// RootView measures its real content height after layout and reshapes the
    /// window; the top edge stays pinned below the menu bar so it grows down.
    private func contentHeightChanged(_ newHeight: CGFloat) {
        let clamped = min(max(newHeight.rounded(.up), 1), maxHeight)
        guard abs(clamped - height) >= 0.5 else { return }
        height = clamped
        guard isShown else { return }
        var frame = panel.frame
        frame.origin.y = frame.maxY - clamped
        frame.size.height = clamped
        panel.setFrame(frame, display: true)
    }

    private func frame(anchor: NSRect, visible: NSRect) -> NSRect {
        let gap: CGFloat = 6
        let margin: CGFloat = 8
        let top = min(anchor.minY - gap, visible.maxY - gap)
        let shownHeight = min(height, max(80, top - visible.minY - margin))
        var x = anchor.midX - width / 2
        x = min(max(x, visible.minX + margin), visible.maxX - width - margin)
        return NSRect(x: x.rounded(), y: top - shownHeight, width: width, height: shownHeight)
    }

    private func installMonitors() {
        removeMonitors()

        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }) {
            monitors.append(global)
        }

        if let local = NSEvent.addLocalMonitorForEvents(matching: mouseMask.union(.keyDown), handler: { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                // Let an open menu (the header's gear menu) consume Escape
                // first; only close the panel when nothing is tracking.
                if event.keyCode == 53, !Self.isMenuOpen {
                    self.hide()
                    return nil
                }
                return event
            }
            if event.window === self.panel { return event }
            if event.window === self.statusItem.button?.window { return event }
            // Menus, alerts and other status-level chrome belong to the
            // current interaction; don't dismiss the panel under them.
            if (event.window?.level.rawValue ?? 0) >= NSWindow.Level.popUpMenu.rawValue { return event }
            self.hide()
            return event
        }) {
            monitors.append(local)
        }

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.hide() }
        }
        // Cmd-Tab (or any other app activation) must not leave the panel
        // floating above an app the user has just switched to. The panel is
        // non-activating, so NSApplication's own resign-active notification
        // never fires for it.
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            DispatchQueue.main.async { self?.hide() }
        }
    }

    private func removeMonitors() {
        for monitor in monitors {
            NSEvent.removeMonitor(monitor)
        }
        monitors.removeAll()
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
            self.spaceObserver = nil
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        if let appObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appObserver)
            self.appObserver = nil
        }
    }

    /// Menus live in pop-up-level windows; while one tracks the pointer,
    /// Escape belongs to the menu, not to the panel.
    private static var isMenuOpen: Bool {
        NSApp.windows.contains {
            $0.isVisible && $0.level.rawValue >= NSWindow.Level.popUpMenu.rawValue
        }
    }
}

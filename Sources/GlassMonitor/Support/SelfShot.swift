import SwiftUI
import AppKit
import Core

/// `GlassMonitor --selfshot` opens the real panel in a plain window and keeps it
/// on screen for a few seconds so an external `screencapture` can grab it with
/// the glass material fully composited.
enum SelfShot {
    @MainActor
    static func runIfRequested(monitor: HardwareMonitor, settings: AppSettings) {
        guard CommandLine.arguments.contains("--selfshot") else { return }

        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        // 没有高度上限时 RootView 里的 ScrollView 会拿到无限高度，窗口在
        // setContentSize 时直接崩溃；按当前屏幕可见高度给一个有限值。
        let maxHeight = max(480, (NSScreen.main?.visibleFrame.height ?? 900) - 48)
        let host = NSHostingView(rootView: RootView(maxHeight: maxHeight)
            .environmentObject(monitor)
            .environmentObject(settings)
            .frame(width: Panel.cardWidth * 2 + Panel.spacing * 3))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 494, height: 600),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.setFrameAutosaveName("")
        window.center()
        window.makeKeyAndOrderFront(nil)
        application.activate(ignoringOtherApps: true)
        monitor.start(interval: 1)

        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            exit(0)
        }

        application.run()
    }
}

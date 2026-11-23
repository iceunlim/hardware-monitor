import AppKit
import SwiftUI
import Combine
import ServiceManagement
import Core

/// Menu bar presence built on NSStatusItem so the readout refreshes on every
/// sample (SwiftUI's MenuBarExtra label does not), with a borderless NSPanel
/// hosting the Liquid Glass panel. Left click toggles the panel, right click
/// offers the display-combination menu directly on the icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = HardwareMonitor()
    let settings = AppSettings()

    private var statusItem: NSStatusItem!
    private var panelController: PanelController!
    private var settingsWindowController: SettingsWindowController?
    private var settingsObserver: NSObjectProtocol?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--selftest-loginitem") {
            runLoginItemSelfTest()
            return
        }
        SelfShot.runIfRequested(monitor: monitor, settings: settings)
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imageHugsTitle = true
        }

        panelController = PanelController(statusItem: statusItem, monitor: monitor, settings: settings)
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .openSettingsWindow, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.showSettings() }
        }

        monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLabel() }
            .store(in: &cancellables)
        settings.$menuBarItems
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshLabel()
                self?.panelController.reanchor()
            }
            .store(in: &cancellables)
        settings.$selectedGPU
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshLabel() }
            .store(in: &cancellables)
        settings.$interval
            .receive(on: DispatchQueue.main)
            .sink { [weak self] interval in self?.monitor.updateInterval(interval) }
            .store(in: &cancellables)

        refreshLabel()
        monitor.start(interval: settings.interval)

        if CommandLine.arguments.contains("--selfpanel") || CommandLine.arguments.contains("--selfpopover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.panelController.show()
            }
        }
    }

    /// One glyph per hardware domain followed by its selected readouts (temp
    /// in °C, load in %), drawn into a single image so one status item shows
    /// icon-labelled groups. Colors resolve inside the drawing handler so
    /// dark/light menu bars and wallpaper tinting stay correct without
    /// rebuilding on appearance changes.
    private func refreshLabel() {
        guard let button = statusItem.button else { return }
        var snapshot = monitor.snapshot
        if let selected = settings.selectedGPU,
           let gpu = snapshot.gpus.first(where: { $0.id == selected }) {
            snapshot.gpu = gpu
        }
        let groups = MenuBarItem.Domain.allCases.compactMap { domain -> (symbol: String, text: String)? in
            let texts = MenuBarItem.allCases
                .filter { $0.domain == domain && settings.menuBarItems.contains($0) }
                .map { $0.text(snapshot) }
            guard !texts.isEmpty else { return nil }
            return (domain.symbol, texts.joined(separator: " "))
        }
        button.title = ""
        button.imagePosition = .imageOnly

        guard !groups.isEmpty else {
            let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            button.image = NSImage(systemSymbolName: "gauge.medium", accessibilityDescription: AppInfo.displayName)?
                .withSymbolConfiguration(configuration)
            button.image?.isTemplate = true
            return
        }

        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let iconTextGap: CGFloat = 3
        let segmentGap: CGFloat = 8
        let texts = groups.map(\.text)

        var widths: [CGFloat] = []
        var glyphWidths: [CGFloat] = []
        var total: CGFloat = 0
        for (index, group) in groups.enumerated() {
            let glyph = NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(symbolConfiguration)
            let glyphWidth = glyph?.size.width ?? 0
            let textWidth = ceil((texts[index] as NSString).size(withAttributes: attributes).width)
            glyphWidths.append(glyphWidth)
            widths.append(glyphWidth + iconTextGap + textWidth)
            total += glyphWidth + iconTextGap + textWidth
        }
        total += segmentGap * CGFloat(groups.count - 1)
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { rect in
            let color = NSColor.labelColor
            let tinted = NSImage.SymbolConfiguration(paletteColors: [color])
            var x = rect.minX
            for (index, group) in groups.enumerated() {
                if let glyph = NSImage(systemSymbolName: group.symbol, accessibilityDescription: nil)?
                    .withSymbolConfiguration(symbolConfiguration)?
                    .withSymbolConfiguration(tinted) {
                    let size = glyph.size
                    glyph.draw(in: NSRect(x: x, y: (rect.height - size.height) / 2,
                                          width: size.width, height: size.height))
                }
                let text = texts[index] as NSString
                let textSize = text.size(withAttributes: [.font: font, .foregroundColor: color])
                text.draw(at: NSPoint(x: x + glyphWidths[index] + iconTextGap,
                                      y: (rect.height - textSize.height) / 2),
                          withAttributes: [.font: font, .foregroundColor: color])
                x += widths[index] + segmentGap
            }
            return true
        }
        image.isTemplate = false
        button.image = image
    }

    /// Registers then immediately unregisters the login item, printing each
    /// status so the SMAppService path can be verified without leaving a
    /// persistent change behind.
    private func runLoginItemSelfTest() {
        let service = SMAppService.mainApp
        print("status before: \(service.status.rawValue)")
        do {
            try service.register()
            print("register ok, status: \(service.status.rawValue)")
            try service.unregister()
            print("unregister ok, status: \(service.status.rawValue)")
        } catch {
            print("selftest error: \(error)")
        }
        NSApp.terminate(nil)
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, monitor: monitor)
        }
        settingsWindowController?.present()
    }

    /// Left click toggles the panel; right click dismisses it and drops the
    /// display-combination menu right under the icon.
    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            panelController.hide()
            showModeMenu()
            return
        }
        panelController.toggle()
    }

    private func showModeMenu() {
        let menu = NSMenu()
        for item in MenuBarItem.allCases {
            let entry = NSMenuItem(title: item.title, action: #selector(toggleItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.rawValue
            entry.state = settings.menuBarItems.contains(item) ? .on : .off
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let quit = NSMenuItem(title: L10n.format("menu.quit", AppInfo.displayName), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        if let button = statusItem.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 6), in: button)
        }
    }

    @objc private func toggleItem(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let item = MenuBarItem(rawValue: raw) else { return }
        if settings.menuBarItems.contains(item) {
            settings.menuBarItems.remove(item)
        } else {
            settings.menuBarItems.insert(item)
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
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
    let settings: AppSettings
    let updater: UpdateController

    override init() {
        let settings = AppSettings()
        self.settings = settings
        updater = UpdateController(settings: settings)
        super.init()
    }

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
        let groups = MenuBarItem.Domain.allCases.compactMap { domain -> (symbol: String?, text: String)? in
            let texts = MenuBarItem.allCases
                .filter { $0.domain == domain && settings.menuBarItems.contains($0) }
                .compactMap { $0.text(snapshot) }
            guard !texts.isEmpty else { return nil }
            // 只有网络的上下行拆成两行；CPU/GPU 的温度和占用保持单行，
            // 否则两列短行看起来比横排更零碎。
            let separator = domain == .net ? "\n" : " "
            return (domain.symbol, texts.joined(separator: separator))
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
        // 网速上下行拆成两行：10 pt 配合紧凑行距刚好落在 22 pt 状态栏内，
        // 横向只占一行的宽度。
        let stackedFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        let iconTextGap: CGFloat = 6
        let iconBoxWidth: CGFloat = 18
        let segmentGap: CGFloat = 10
        let texts = groups.map(\.text)
        let stackedLineHeight: CGFloat = 10.5

        func attributes(for text: String, color: NSColor? = nil,
                        alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] {
            let stacked = text.contains("\n")
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byClipping
            paragraph.alignment = alignment
            if stacked {
                paragraph.minimumLineHeight = stackedLineHeight
                paragraph.maximumLineHeight = stackedLineHeight
            }
            var result: [NSAttributedString.Key: Any] = [
                .font: stacked ? stackedFont : font,
                .paragraphStyle: paragraph,
            ]
            if let color { result[.foregroundColor] = color }
            return result
        }

        func measured(_ text: String, alignment: NSTextAlignment) -> NSSize {
            if !text.contains("\n") {
                let size = (text as NSString).size(
                    withAttributes: attributes(for: text, alignment: alignment))
                return NSSize(width: ceil(size.width), height: ceil(size.height))
            }
            let size = (text as NSString).boundingRect(
                with: NSSize(width: 1_000, height: 1_000),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: attributes(for: text, alignment: alignment)).size
            return NSSize(width: ceil(size.width), height: ceil(size.height))
        }

        var widths: [CGFloat] = []
        var textSizes: [NSSize] = []
        var total: CGFloat = 0
        for (index, group) in groups.enumerated() {
            let hasIcon = group.symbol != nil
            let textSize = measured(texts[index], alignment: hasIcon ? .right : .left)
            textSizes.append(textSize)
            let width = (hasIcon ? iconBoxWidth + iconTextGap : 0) + textSize.width
            widths.append(width)
            total += width
        }
        total += segmentGap * CGFloat(groups.count - 1)
        let height: CGFloat = 22

        let image = NSImage(size: NSSize(width: ceil(total), height: height), flipped: false) { rect in
            let color = NSColor.labelColor
            let tinted = NSImage.SymbolConfiguration(paletteColors: [color])
            var x = rect.minX
            for (index, group) in groups.enumerated() {
                if let symbol = group.symbol,
                   let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                       .withSymbolConfiguration(symbolConfiguration)?
                       .withSymbolConfiguration(tinted) {
                    let size = glyph.size
                    glyph.draw(in: NSRect(x: x + (iconBoxWidth - size.width) / 2,
                                          y: (rect.height - size.height) / 2,
                                          width: size.width, height: size.height))
                }
                let text = texts[index] as NSString
                let textSize = textSizes[index]
                let alignment: NSTextAlignment = group.symbol == nil ? .left : .right
                let textRect = NSRect(x: x + (group.symbol == nil ? 0 : iconBoxWidth + iconTextGap),
                                      y: (rect.height - textSize.height) / 2,
                                      width: textSize.width, height: textSize.height)
                if texts[index].contains("\n") {
                    text.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                              attributes: attributes(for: texts[index], color: color,
                                                     alignment: alignment))
                } else {
                    text.draw(at: NSPoint(x: textRect.minX, y: textRect.minY),
                              withAttributes: attributes(for: texts[index], color: color,
                                                         alignment: alignment))
                }
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
            settingsWindowController = SettingsWindowController(settings: settings,
                                                                monitor: monitor,
                                                                updater: updater)
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
        let updates = NSMenuItem(title: L10n.t("menu.checkUpdates"),
                                 action: #selector(checkForUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
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

    @objc private func checkForUpdates() {
        showSettings()
        Task { await updater.check() }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
import SwiftUI
import AppKit
import Combine
import ServiceManagement

/// Language selected in the panel's settings. The actual localization is
/// resolved by `Bundle.main` from `en.lproj` / `zh-Hans.lproj`; an explicit
/// choice is stored as the app-domain `AppleLanguages` key, the same key
/// System Settings writes for per-app languages. Changing it requires a
/// relaunch because Foundation caches the preferred localization at launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case chinese
    case english

    var id: String { rawValue }

    /// Value for the app-domain `AppleLanguages` key; `nil` removes the
    /// override and lets the system language apply.
    var appleLanguages: [String]? {
        switch self {
        case .system: nil
        case .chinese: ["zh-Hans"]
        case .english: ["en"]
        }
    }

    /// Reads only this app's preferences domain, not the global system
    /// language, so "Follow System" can be distinguished from an explicit
    /// English choice.
    static var current: AppLanguage {
        guard let bundleID = Bundle.main.bundleIdentifier,
              let values = UserDefaults.standard.persistentDomain(forName: bundleID)?["AppleLanguages"] as? [String],
              let first = values.first else { return .system }
        if first.hasPrefix("zh") { return .chinese }
        if first.hasPrefix("en") { return .english }
        return .system
    }
}

/// User-facing preferences, mirrored into `UserDefaults` so the panel restarts
/// the way it was left.
@MainActor
final class AppSettings: ObservableObject {
    static let defaults = UserDefaults.standard

    @Published var interval: Double {
        didSet { Self.defaults.set(interval, forKey: "interval") }
    }
    @Published var showsPerCore: Bool {
        didSet { Self.defaults.set(showsPerCore, forKey: "showsPerCore") }
    }
    @Published var curveMinutes: Double {
        didSet { Self.defaults.set(curveMinutes, forKey: "curveMinutes") }
    }
    @Published var menuBarItems: Set<MenuBarItem> {
        didSet { Self.defaults.set(menuBarItems.map(\.rawValue), forKey: "menuBarItems") }
    }
    /// Which GPU the panel and menu bar report. Registry entry IDs are
    /// per-boot, so this is deliberately session-only; every launch starts
    /// on the discrete card.
    @Published var selectedGPU: String?
    /// CPU 卡片显示哪一路风扇；`nil` 表示自动（CPUFAN → 水泵 → 在转风扇）。
    /// 通道名（`CPUFAN`/`SYSFAN`/`AUXFAN0`…）跨重启稳定，可以持久化。
    @Published var cpuFanChannel: String? {
        didSet {
            if let cpuFanChannel { Self.defaults.set(cpuFanChannel, forKey: "cpuFanChannel") }
            else { Self.defaults.removeObject(forKey: "cpuFanChannel") }
        }
    }
    /// 顶部信息条的风扇读数：自动只显示当前在转的，关掉后按用户勾选显示。
    @Published var headerFansAuto: Bool {
        didSet { Self.defaults.set(headerFansAuto, forKey: "headerFansAuto") }
    }
    @Published var headerFanChannels: Set<String> {
        didSet { Self.defaults.set(headerFanChannels.sorted(), forKey: "headerFanChannels") }
    }
    /// Mirrors the system login-item registration, which is the source of
    /// truth — the user can also flip it in System Settings.
    @Published private(set) var launchAtLogin = false
    @Published private(set) var language: AppLanguage = .system

    init() {
        interval = Self.defaults.object(forKey: "interval") as? Double ?? 2
        showsPerCore = Self.defaults.object(forKey: "showsPerCore") as? Bool ?? true
        curveMinutes = Self.defaults.object(forKey: "curveMinutes") as? Double ?? 5
        cpuFanChannel = Self.defaults.string(forKey: "cpuFanChannel")
        headerFansAuto = Self.defaults.object(forKey: "headerFansAuto") as? Bool ?? true
        headerFanChannels = Set(Self.defaults.array(forKey: "headerFanChannels") as? [String] ?? [])

        if let raw = Self.defaults.array(forKey: "menuBarItems") as? [String] {
            menuBarItems = Set(raw.compactMap(MenuBarItem.init(rawValue:)))
        } else if let legacy = Self.defaults.string(forKey: "menuBarMode") {
            menuBarItems = Self.migrate(legacy)
        } else {
            menuBarItems = [.cpuTemp, .gpuTemp]
        }
        if menuBarItems.isEmpty { menuBarItems = [.cpuTemp, .gpuTemp] }
        language = AppLanguage.current
        refreshLaunchAtLogin()
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("登录项切换失败: \(error)")
        }
        refreshLaunchAtLogin()
    }

    /// Writes the per-app language override and relaunches. Bundle.main
    /// resolves its localization once per process, so there is no supported
    /// way to swap languages in place; Apple's per-app language setting in
    /// System Settings relaunches the app for the same reason.
    func setLanguage(_ newLanguage: AppLanguage) {
        guard newLanguage != language else { return }
        language = newLanguage
        if let codes = newLanguage.appleLanguages {
            Self.defaults.set(codes, forKey: "AppleLanguages")
        } else {
            Self.defaults.removeObject(forKey: "AppleLanguages")
        }
        Self.defaults.synchronize()
        Self.relaunch()
    }

    private static func relaunch() {
        let url = Bundle.main.bundleURL
        guard url.pathExtension == "app" else {
            // Running the raw SwiftPM binary during development: the choice is
            // still saved and applies on the next packaged launch.
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error == nil else { return }
            DispatchQueue.main.async {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private static func migrate(_ legacy: String) -> Set<MenuBarItem> {
        switch legacy {
        case "cpuTemp": return [.cpuTemp]
        case "gpuTemp": return [.gpuTemp]
        case "temps": return [.cpuTemp, .gpuTemp]
        case "cpuLoad": return [.cpuLoad]
        case "loads": return [.cpuLoad, .gpuLoad]
        case "memory": return [.memory]
        case "net": return [.net]
        case "netTemp": return [.cpuTemp, .net]
        default: return [.cpuTemp, .gpuTemp]
        }
    }
}
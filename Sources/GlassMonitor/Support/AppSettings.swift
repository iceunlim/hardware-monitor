import SwiftUI
import Combine
import ServiceManagement

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
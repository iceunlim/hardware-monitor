import SwiftUI
import AppKit
import Core

extension Notification.Name {
    static let openSettingsWindow = Notification.Name("openSettingsWindow")
}

/// A regular window rather than the SwiftUI `Settings` scene: the panel is a
/// manually hosted view, and a menu bar app has no app menu to reach the scene.
@MainActor
final class SettingsWindowController: NSWindowController {
    init(settings: AppSettings, monitor: HardwareMonitor, updater: UpdateController) {
        let root = SettingsView()
            .environmentObject(settings)
            .environmentObject(monitor)
            .environmentObject(updater)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.title = L10n.t("settings.window.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 440))
        window.center()
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The app's preferences live in a regular Settings window instead of one very
/// long menu. Tabs keep the three independent groups scannable and leave room
/// for new options without turning the panel's gear into a scrollable menu.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(L10n.t("settings.tab.general"), systemImage: "gearshape") }
            FanSettings()
                .tabItem { Label(L10n.t("settings.tab.fans"), systemImage: "fanblades") }
            MenuBarSettings()
                .tabItem { Label(L10n.t("settings.tab.menuBar"), systemImage: "menubar.rectangle") }
            UpdateSettings()
                .tabItem { Label(L10n.t("settings.tab.updates"), systemImage: "arrow.triangle.2.circlepath") }
        }
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject private var settings: AppSettings

    private var languageBinding: Binding<AppLanguage> {
        Binding(get: { settings.language }, set: { settings.setLanguage($0) })
    }

    var body: some View {
        Form {
            Section(L10n.t("settings.section.general")) {
                Picker(L10n.t("menu.language"), selection: languageBinding) {
                    Text(L10n.t("language.system")).tag(AppLanguage.system)
                    Text("简体中文").tag(AppLanguage.chinese)
                    Text("English").tag(AppLanguage.english)
                }
                .pickerStyle(.menu)
                Toggle(L10n.t("menu.launchAtLogin"), isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.setLaunchAtLogin($0) }
                ))
            }

            Section(L10n.t("settings.section.display")) {
                Picker(L10n.t("menu.chartWindow"), selection: $settings.curveMinutes) {
                    Text(L10n.t("menu.chartWindow.1m")).tag(1.0)
                    Text(L10n.t("menu.chartWindow.3m")).tag(3.0)
                    Text(L10n.t("menu.chartWindow.5m")).tag(5.0)
                }
                Picker(L10n.t("menu.interval"), selection: $settings.interval) {
                    Text(L10n.t("menu.interval.1s")).tag(1.0)
                    Text(L10n.t("menu.interval.2s")).tag(2.0)
                    Text(L10n.t("menu.interval.3s")).tag(3.0)
                    Text(L10n.t("menu.interval.5s")).tag(5.0)
                }
                Toggle(L10n.t("menu.perCore"), isOn: $settings.showsPerCore)
            }

        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct FanSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var monitor: HardwareMonitor

    private var runningFans: [FanSample] {
        monitor.snapshot.fans.filter { ($0.currentRPM ?? 0) > 0 }
    }

    /// Turning auto off starts from the fans that are actually spinning, so
    /// the header doesn't suddenly go blank.
    private var autoBinding: Binding<Bool> {
        Binding(
            get: { settings.headerFansAuto },
            set: { on in
                if !on, settings.headerFanChannels.isEmpty {
                    settings.headerFanChannels = Set(runningFans.map(\.channel))
                }
                settings.headerFansAuto = on
            })
    }

    private func fanBinding(_ fan: FanSample) -> Binding<Bool> {
        Binding(
            get: {
                if settings.headerFansAuto { return (fan.currentRPM ?? 0) > 0 }
                return settings.headerFanChannels.contains(fan.channel)
            },
            set: { on in
                if on { settings.headerFanChannels.insert(fan.channel) }
                else { settings.headerFanChannels.remove(fan.channel) }
            })
    }

    private func fanTitle(_ fan: FanSample) -> String {
        let rpm = fan.currentRPM ?? 0
        let value = rpm > 0 ? "\(Int(rpm.rounded())) RPM" : L10n.t("fan.stopped")
        return "\(fan.name) · \(fan.channel) · \(value)"
    }

    var body: some View {
        Form {
            Section(L10n.t("menu.headerFans")) {
                Toggle(L10n.t("menu.headerFans.auto"), isOn: autoBinding)
                ForEach(monitor.snapshot.fans, id: \.channel) { fan in
                    Toggle(fanTitle(fan), isOn: fanBinding(fan))
                        .disabled(settings.headerFansAuto)
                }
                if monitor.snapshot.fans.isEmpty {
                    Text(L10n.t("menu.noFans")).foregroundStyle(.secondary)
                }
            }

            Section(L10n.t("menu.cpuFan")) {
                Picker(L10n.t("settings.cpuFan.picker"), selection: $settings.cpuFanChannel) {
                    Text(L10n.t("menu.cpuFan.auto")).tag(Optional<String>.none)
                    ForEach(monitor.snapshot.fans, id: \.channel) { fan in
                        Text(fanTitle(fan)).tag(Optional(fan.channel))
                    }
                }
                .pickerStyle(.menu)
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct MenuBarSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section(L10n.t("menu.menuBar")) {
                ForEach(MenuBarItem.allCases) { item in
                    Toggle(item.title, isOn: Binding(
                        get: { settings.menuBarItems.contains(item) },
                        set: { on in
                            if on { settings.menuBarItems.insert(item) }
                            else { settings.menuBarItems.remove(item) }
                        }))
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct UpdateSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var updater: UpdateController

    private var lastCheckText: String {
        guard let last = updater.lastCheck else { return L10n.t("update.never") }
        return L10n.format("update.lastCheck",
                           last.formatted(date: .abbreviated, time: .shortened))
    }

    var body: some View {
        Form {
            Section(L10n.t("update.section")) {
                LabeledContent {
                    Text(updater.currentVersion)
                } label: {
                    Text(L10n.t("update.currentVersion"))
                }
                Toggle(L10n.t("update.autoCheck"), isOn: $settings.autoCheckUpdates)
                Toggle(L10n.t("update.autoInstall"), isOn: $settings.autoInstallUpdates)
                    .disabled(!settings.autoCheckUpdates)
                HStack {
                    Button(L10n.t("update.check")) {
                        Task { await updater.check() }
                    }
                    .disabled(updater.isBusy)
                    Spacer()
                    Text(lastCheckText).foregroundStyle(.secondary)
                }
                status
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }

    @ViewBuilder private var status: some View {
        switch updater.state {
        case .idle:
            EmptyView()
        case .checking:
            Text(L10n.t("update.checking")).foregroundStyle(.secondary)
        case .upToDate:
            Text(L10n.t("update.upToDate")).foregroundStyle(.secondary)
        case .available(let info):
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.format("update.available", info.version))
                HStack {
                    Button(L10n.t("update.install")) {
                        Task { await updater.installAvailable() }
                    }
                    Button(L10n.t("update.openPage")) {
                        NSWorkspace.shared.open(info.pageURL)
                    }
                }
            }
        case .downloading:
            HStack(spacing: 8) {
                ProgressView()
                Text(L10n.t("update.downloading")).foregroundStyle(.secondary)
            }
        case .installing:
            HStack(spacing: 8) {
                ProgressView()
                Text(L10n.t("update.installing")).foregroundStyle(.secondary)
            }
        case .failed(let message):
            Text(message).foregroundStyle(.red).textSelection(.enabled)
        }
    }
}

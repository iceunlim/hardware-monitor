import Foundation

/// Thin wrapper around the system localization APIs.
///
/// Keys are semantic (`menu.quit`) rather than English source strings, which
/// keeps context-specific translations apart — for example the metric
/// "Compressed" and the memory legend "Compressed" are different Chinese words.
/// `Localizable.strings` ships in `en.lproj` and `zh-Hans.lproj`; `Bundle.main`
/// picks the right one from the system language or the per-app override.
enum L10n {
    static func t(_ key: String) -> String {
        String(localized: String.LocalizationValue(key))
    }

    /// Interpolated strings use positional format specifiers so translations
    /// may reorder the arguments.
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: t(key), locale: .current, arguments: arguments)
    }
}

/// The localized bundle name, used for the window title, accessibility
/// description and the Quit menu item.
enum AppInfo {
    static var displayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "GlassMonitor"
    }
}

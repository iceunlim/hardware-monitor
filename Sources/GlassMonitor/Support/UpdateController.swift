import Foundation
import AppKit
import Combine
import CryptoKit

/// 从 GitHub Releases 检查并安装更新。
///
/// 项目没有 Developer ID 与 appcast，因此不走 Sparkle：这里直接读取
/// GitHub API，按本机架构选择 zip，用 GitHub 提供的 SHA256 digest 校验
/// 下载内容，再交给一个独立脚本在应用退出后替换 bundle。任何一步失败
/// 都保留或恢复旧版本，不会把半成品留在 /Applications。
@MainActor
final class UpdateController: ObservableObject {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateInfo)
        case downloading
        case installing
        case failed(String)
    }

    struct UpdateInfo: Equatable {
        let version: String
        let pageURL: URL
        let assetURL: URL
        let assetName: String
        let digest: String?
        let notes: String?
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastCheck: Date?
    let currentVersion: String

    var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: true
        default: false
        }
    }

    private let settings: AppSettings
    private let repository = "iceunlim/hardware-monitor"
    private let session: URLSession
    private var task: Task<Void, Never>?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: AppSettings) {
        self.settings = settings
        currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        lastCheck = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 60
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)

        settings.$autoCheckUpdates
            .removeDuplicates()
            .sink { [weak self] enabled in
                if enabled { self?.start() } else { self?.stop() }
            }
            .store(in: &cancellables)
    }

    /// 启动后延迟半分钟再检查，避免和首帧采样抢资源；之后每 24 小时一次。
    func start() {
        guard settings.autoCheckUpdates else { return }
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.check()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 86_400_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.check()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func check() async {
        guard !isBusy else { return }
        state = .checking

        do {
            let release = try await fetchLatest()
            lastCheck = Date()
            UserDefaults.standard.set(lastCheck, forKey: "lastUpdateCheck")

            guard let version = release.version,
                  compare(version, currentVersion) > 0 else {
                state = .upToDate
                return
            }
            guard let asset = release.assets.first(where: { $0.name == expectedAssetName(version) }) else {
                throw UpdateError.invalidAsset
            }

            let info = UpdateInfo(version: version,
                                  pageURL: release.htmlURL,
                                  assetURL: asset.browserDownloadURL,
                                  assetName: asset.name,
                                  digest: asset.digest,
                                  notes: release.body)
            state = .available(info)

            if settings.autoInstallUpdates {
                await install(info)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func installAvailable() async {
        guard case .available(let info) = state else { return }
        await install(info)
    }

    // MARK: - GitHub

    private func fetchLatest() async throws -> Release {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            throw UpdateError.invalidAsset
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GlassMonitor/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdateError.server(-1)
        }
        guard http.statusCode == 200 else {
            throw UpdateError.server(http.statusCode)
        }

        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else {
            throw UpdateError.noRelease
        }
        return release
    }

    private var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private func expectedAssetName(_ version: String) -> String {
        "GlassMonitor-\(version)-\(architecture).zip"
    }

    // MARK: - Download and install

    private func install(_ info: UpdateInfo) async {
        state = .downloading
        do {
            let archive = try await download(info)
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("GlassMonitor-update-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try await run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path])

            let app = staging.appendingPathComponent("GlassMonitor.app")
            try await verify(app, version: info.version)

            state = .installing
            try launchInstaller(newApp: app)
            NSApp.terminate(nil)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func download(_ info: UpdateInfo) async throws -> URL {
        let (url, response) = try await session.download(from: info.assetURL)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError.server((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let digest = info.digest, digest.hasPrefix("sha256:") else {
            throw UpdateError.missingChecksum
        }

        let data = try Data(contentsOf: url)
        let actual = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        guard actual.caseInsensitiveCompare(String(digest.dropFirst(7))) == .orderedSame else {
            throw UpdateError.checksum
        }
        return url
    }

    private func verify(_ app: URL, version: String) async throws {
        guard let bundle = Bundle(url: app),
              bundle.bundleIdentifier == "app.glassmonitor.panel",
              bundle.infoDictionary?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError.invalidBundle
        }
        try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
    }

    /// 应用必须先退出才能安全替换自身，所以把替换交给一个独立脚本：
    /// 脚本等待进程消失、备份旧 bundle、替换并校验，失败时恢复旧 bundle。
    private func launchInstaller(newApp: URL) throws {
        let installed = Bundle.main.bundleURL
        guard installed.pathExtension == "app" else {
            throw UpdateError.notInstalled
        }
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable
        }

        let backup = parent.appendingPathComponent(".GlassMonitor-backup-\(UUID().uuidString).app")
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("GlassMonitor-install-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        set -euo pipefail
        APP="$1"
        NEW="$2"
        BACKUP="$3"
        trap 'open "$APP" 2>/dev/null || true' EXIT

        for _ in $(seq 1 100); do
          pgrep -x GlassMonitor >/dev/null || break
          sleep 0.2
        done

        rm -rf "$(dirname "$APP")"/.GlassMonitor-backup-*.app
        mv "$APP" "$BACKUP"
        if ditto "$NEW" "$APP" && xattr -cr "$APP" && codesign --verify --deep --strict "$APP"; then
          rm -rf "$NEW"
        else
          rm -rf "$APP"
          mv "$BACKUP" "$APP"
        fi
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, installed.path, newApp.path, backup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private func run(_ executable: String, _ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()
                    guard process.terminationStatus == 0 else {
                        let text = String(data: data, encoding: .utf8) ?? ""
                        throw UpdateError.command(String(text.prefix(300)))
                    }
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Version

    private func compare(_ lhs: String, _ rhs: String) -> Int {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? -1 : 1 }
        }
        return 0
    }

    // MARK: - API models

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: URL
        let body: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        var version: String? {
            let trimmed = tagName.hasPrefix("v") || tagName.hasPrefix("V")
                ? String(tagName.dropFirst())
                : tagName
            return trimmed.isEmpty ? nil : trimmed
        }

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case body, draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    private enum UpdateError: LocalizedError {
        case server(Int)
        case noRelease
        case invalidAsset
        case checksum
        case missingChecksum
        case invalidBundle
        case notInstalled
        case notWritable
        case command(String)

        var errorDescription: String? {
            switch self {
            case .server(let code): L10n.format("update.error.server", code)
            case .noRelease: L10n.t("update.error.noRelease")
            case .invalidAsset: L10n.t("update.error.noAsset")
            case .checksum: L10n.t("update.error.checksum")
            case .missingChecksum: L10n.t("update.error.missingChecksum")
            case .invalidBundle: L10n.t("update.error.invalidBundle")
            case .notInstalled: L10n.t("update.error.notInstalled")
            case .notWritable: L10n.t("update.error.notWritable")
            case .command(let output): output.isEmpty ? L10n.t("update.error.command") : output
            }
        }
    }
}

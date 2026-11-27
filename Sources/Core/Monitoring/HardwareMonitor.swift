import Foundation
import Combine

/// Drives the sampling loop and keeps rolling history for the sparklines.
///
/// Sampling happens off the main thread — SMC reads and registry walks add up
/// across ~100 keys — and only the finished snapshot is published.
public final class HardwareMonitor: ObservableObject {
    @Published public private(set) var snapshot = SystemSnapshot()
    @Published public private(set) var cpuHistory: [Double] = []
    /// Keyed by `GPUSnapshot.id` so switching the card between GPUs never
    /// blends one device's curve into another's.
    @Published public private(set) var gpuHistories: [String: [Double]] = [:]
    @Published public private(set) var memoryHistory: [Double] = []
    @Published public private(set) var downloadHistory: [Double] = []
    @Published public private(set) var uploadHistory: [Double] = []
    @Published public private(set) var cpuTempHistory: [Double] = []
    @Published public private(set) var gpuTempHistories: [String: [Double]] = [:]
    @Published public private(set) var sessionPeakDownload: Double = 0
    @Published public private(set) var sessionPeakUpload: Double = 0
    @Published public private(set) var isSampling = false

    public let deviceInfo = DeviceInfo.shared
    public private(set) var interval: TimeInterval = 2

    private let cpu = CPUSampler()
    private let memory = MemorySampler()
    private let network = NetworkSampler()
    private let gpu = GPUSampler()
    private let fans = FanReader()
    private let temperatures = TemperatureReader()

    private let queue = DispatchQueue(label: "glassmonitor.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private let historyLength = 300

    public init() {}

    deinit { timer?.cancel() }

    public func start(interval: TimeInterval = 2) {
        stop()
        self.interval = max(0.5, interval)

        // Prime the delta-based samplers so the first published tick is real.
        queue.async { [weak self] in
            guard let self else { return }
            _ = self.cpu.read()
            _ = self.network.read()
        }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + self.interval, repeating: self.interval)
        source.setEventHandler { [weak self] in self?.sample() }
        timer = source
        source.resume()

        DispatchQueue.main.async { self.isSampling = true }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        DispatchQueue.main.async { self.isSampling = false }
    }

    public func updateInterval(_ newValue: TimeInterval) {
        guard newValue != interval else { return }
        // Histories are evenly spaced at `interval`; mixing cadences would
        // distort the time axis of the trend charts.
        cpuHistory = []
        gpuHistories = [:]
        memoryHistory = []
        downloadHistory = []
        uploadHistory = []
        cpuTempHistory = []
        gpuTempHistories = [:]
        start(interval: newValue)
    }

    private func sample() {
        var next = SystemSnapshot()
        next.date = Date()

        // SMC is opened lazily and stays open; failure just means no fan/temp data.
        SMCClient.shared.open()

        next.cpu = cpu.read()
        next.memory = memory.read()
        next.network = network.read()
        next.gpus = gpu.readAll()
        next.gpu = next.gpus[0]
        next.fans = fans.read()
        next.temperatures = temperatures.read()
        next.cpu.temperatureC = next.cpuTemperature
        if next.gpu.temperatureC == nil { next.gpu.temperatureC = temperatures.gpuTemperature }
        next.gpus[0] = next.gpu

        let download = next.network.downloadBps
        let upload = next.network.uploadBps

        DispatchQueue.main.async {
            self.snapshot = next
            self.append(download, to: \.downloadHistory, scaling: 1)
            self.append(upload, to: \.uploadHistory, scaling: 1)
            self.append(next.cpu.totalUsage, to: \.cpuHistory, scaling: 1)
            self.appendGPUs(next.gpus)
            self.append(next.memory.pressurePercent, to: \.memoryHistory, scaling: 1)
            self.append(next.cpu.temperatureC ?? self.cpuTempHistory.last ?? 0,
                        to: \.cpuTempHistory, scaling: 1)
            self.sessionPeakDownload = max(self.sessionPeakDownload, download)
            self.sessionPeakUpload = max(self.sessionPeakUpload, upload)
        }
    }

    private func appendGPUs(_ gpus: [GPUSnapshot]) {
        let ids = Set(gpus.map(\.id))
        gpuHistories = gpuHistories.filter { ids.contains($0.key) }
        gpuTempHistories = gpuTempHistories.filter { ids.contains($0.key) }
        for gpu in gpus {
            let usage = gpuHistories[gpu.id] ?? []
            gpuHistories[gpu.id] = Array((usage + [gpu.utilization ?? 0]).suffix(historyLength))
            let temps = gpuTempHistories[gpu.id] ?? []
            gpuTempHistories[gpu.id] = Array(
                (temps + [gpu.temperatureC ?? temps.last ?? 0]).suffix(historyLength))
        }
    }

    private func append(_ value: Double,
                        to keyPath: ReferenceWritableKeyPath<HardwareMonitor, [Double]>,
                        scaling: Double) {
        let series = self[keyPath: keyPath] + [value * scaling]
        self[keyPath: keyPath] = Array(series.suffix(historyLength))
    }
}

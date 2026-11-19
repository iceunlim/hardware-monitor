import Foundation
import Core

func f0(_ value: Double) -> String { String(format: "%.0f", value) }
func f1(_ value: Double) -> String { String(format: "%.1f", value) }
func f2(_ value: Double) -> String { String(format: "%.2f", value) }
func optional(_ value: Double?, _ format: (Double) -> String = f1, suffix: String = "") -> String {
    value.map { format($0) + suffix } ?? "-"
}

print("GlassMonitor sysdump")
print(String(repeating: "=", count: 62))

let info = DeviceInfo.shared
print("model        : \(info.macModel)")
print("cpu          : \(info.cpuBrand) (\(info.physicalCores)p/\(info.logicalCores)t)")
print("memory       : \(ByteFormat.string(info.memoryBytes))")
print("os           : \(info.osVersion)")
print("hackintosh   : \(info.isHackintosh)")

SMCClient.shared.open()
print("smc available  : \(SMCClient.shared.isAvailable)   keys: \(SMCClient.shared.keyCount)")

let cpu = CPUSampler()
let memory = MemorySampler()
let network = NetworkSampler()
let gpu = GPUSampler()
let fans = FanReader()
let temperatures = TemperatureReader()

_ = cpu.read()
_ = network.read()

var cpuSnap = CPUSnapshot()
var gpuSnaps: [GPUSnapshot] = []
var netSnap = NetworkSnapshot()

for tick in 1...3 {
    Thread.sleep(forTimeInterval: 1.0)
    cpuSnap = cpu.read()
    gpuSnaps = gpu.readAll()
    netSnap = network.read()

    print("""

    tick \(tick)
      cpu  total=\(f1(cpuSnap.totalUsage))%  user=\(f1(cpuSnap.user))%  sys=\(f1(cpuSnap.system))%  \
    freq=\(optional(cpuSnap.frequencyGHz, f2, suffix: "GHz"))  temp=\(optional(cpuSnap.temperatureC, f1, suffix: "C"))
      cores [\(cpuSnap.cores.count)]: \(cpuSnap.cores.map { f0($0.usage) }.joined(separator: " "))
    """)
    for (index, gpuSnap) in gpuSnaps.enumerated() {
        print("""
      gpu[\(index)] name=\(gpuSnap.name)  integrated=\(gpuSnap.isIntegrated)  supported=\(gpuSnap.isSupported)
            util=\(optional(gpuSnap.utilization))%  temp=\(optional(gpuSnap.temperatureC))C  power=\(optional(gpuSnap.powerW))W  \
    core=\(optional(gpuSnap.coreClockMHz, f0))MHz  mem=\(optional(gpuSnap.memoryClockMHz, f0))MHz  fan=\(optional(gpuSnap.fanRPM, f0))RPM
            vram used=\(gpuSnap.vramUsedBytes.map { ByteFormat.string($0) } ?? "-")  cached=\(gpuSnap.vramCachedBytes.map { ByteFormat.string($0) } ?? "-")  free=\(gpuSnap.vramFreeBytes.map { ByteFormat.string($0) } ?? "-")  total=\(gpuSnap.vramTotalBytes.map { ByteFormat.string($0) } ?? "-")  shared=\(gpuSnap.sharedMemoryBytes.map { ByteFormat.string($0) } ?? "-")
    """)
    }
    print("      net  down=\(ByteFormat.bitsPerSecond(netSnap.downloadBps))  up=\(ByteFormat.bitsPerSecond(netSnap.uploadBps))  iface=\(netSnap.activeInterface ?? "-")")
}

let mem = memory.read()
print("""

MEMORY
  total      \(ByteFormat.string(mem.totalBytes))
  used       \(ByteFormat.string(mem.usedBytes))  (\(f1(mem.pressurePercent))%)
  app        \(ByteFormat.string(mem.appBytes))
  wired      \(ByteFormat.string(mem.wiredBytes))
  compressed \(ByteFormat.string(mem.compressedBytes))
  cached     \(ByteFormat.string(mem.cachedBytes))
  free       \(ByteFormat.string(mem.freeBytes))
  swap       \(ByteFormat.string(mem.swapUsedBytes)) / \(ByteFormat.string(mem.swapTotalBytes))
""")

print("\nNETWORK INTERFACES")
for item in netSnap.interfaces {
    print("  \(item.name.padding(toLength: 8, withPad: " ", startingAt: 0)) in=\(ByteFormat.string(item.sessionInBytes).padding(toLength: 12, withPad: " ", startingAt: 0)) out=\(ByteFormat.string(item.sessionOutBytes))")
}

let fanSamples = fans.read()
print("\nFANS (supported: \(fans.hasFans))")
if fanSamples.isEmpty { print("  none") }
for fan in fanSamples {
    print("  \(fan.name.padding(toLength: 10, withPad: " ", startingAt: 0)) [\(fan.channel)] now=\(optional(fan.currentRPM, f0))  min=\(optional(fan.minRPM, f0))  max=\(optional(fan.maxRPM, f0))  target=\(optional(fan.targetRPM, f0))")
}

var fanSnapshot = SystemSnapshot()
fanSnapshot.fans = fanSamples
if let cooler = fanSnapshot.coolerFan {
    print("  CPU 卡片显示: \(cooler.name) [\(cooler.channel)] \(optional(cooler.currentRPM, f0)) RPM")
}

let temps = temperatures.read()
print("\nTEMPERATURES (\(temps.count))")
for temp in temps {
    print("  \(temp.key)  \(temp.label.padding(toLength: 16, withPad: " ", startingAt: 0)) [\(temp.group.rawValue)] \(f1(temp.celsius))C")
}

import XCTest
@testable import Core

final class NetworkSamplerTests: XCTestCase {
    func testNormalThroughputCalculationInBitsPerSecond() {
        var now: TimeInterval = 100.0
        var reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 1_000_000, sent: 500_000)],
            is64Bit: true
        )
        let sampler = NetworkSampler(now: { now }, counters: { reading }, primaryInterface: { "en2" })

        let prime = sampler.read()
        XCTAssertEqual(prime.downloadBps, 0)
        XCTAssertEqual(prime.uploadBps, 0)
        XCTAssertEqual(prime.sessionInBytes, 0)

        // +50,000,000 bytes received and +10,000,000 bytes sent over 2 seconds:
        // download = 50,000,000 / 2 * 8 = 200,000,000 bps (200 Mbps)
        // upload   = 10,000,000 / 2 * 8 =  40,000,000 bps (40 Mbps)
        now = 102.0
        reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 51_000_000, sent: 10_500_000)],
            is64Bit: true
        )
        let snap = sampler.read()
        XCTAssertEqual(snap.downloadBps, 200_000_000, accuracy: 1.0)
        XCTAssertEqual(snap.uploadBps, 40_000_000, accuracy: 1.0)
        XCTAssertEqual(snap.sessionInBytes, 50_000_000, accuracy: 1.0)
        XCTAssertEqual(snap.sessionOutBytes, 10_000_000, accuracy: 1.0)
        XCTAssertEqual(ByteFormat.bitsPerSecond(snap.downloadBps), "200.0 Mbps")
    }

    func test64BitCounterResetDoesNotCreatePhantomSpike() {
        var now: TimeInterval = 10.0
        var reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 500_000_000, sent: 200_000_000)],
            is64Bit: true
        )
        let sampler = NetworkSampler(now: { now }, counters: { reading })
        _ = sampler.read()

        // Wi-Fi reconnect resets interface counters near zero.
        now = 12.0
        reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 10_000, sent: 5_000)],
            is64Bit: true
        )
        let afterReset = sampler.read()
        XCTAssertEqual(afterReset.downloadBps, 0)
        XCTAssertEqual(afterReset.uploadBps, 0)
        XCTAssertEqual(afterReset.sessionInBytes, 0)
        XCTAssertEqual(afterReset.sessionOutBytes, 0)

        // Subsequent traffic after reset resumes accurately.
        now = 14.0
        reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 1_010_000, sent: 255_000)],
            is64Bit: true
        )
        let resumed = sampler.read()
        XCTAssertEqual(resumed.downloadBps, 4_000_000, accuracy: 1.0)
        XCTAssertEqual(resumed.uploadBps, 1_000_000, accuracy: 1.0)
        XCTAssertEqual(resumed.sessionInBytes, 1_000_000, accuracy: 1.0)
        XCTAssertEqual(resumed.sessionOutBytes, 250_000, accuracy: 1.0)
    }

    func testShortElapsedWindowPreservesBaseline() {
        var now: TimeInterval = 50.0
        var reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 1_000_000, sent: 0)],
            is64Bit: true
        )
        let sampler = NetworkSampler(now: { now }, counters: { reading })
        _ = sampler.read()

        // 80ms burst (< 200ms minElapsed) should be ignored without advancing baseline.
        now = 50.08
        reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 11_000_000, sent: 0)],
            is64Bit: true
        )
        let tooSoon = sampler.read()
        XCTAssertEqual(tooSoon.downloadBps, 0)

        // Full 2.0s window from t=50.0 sees all 20 MB cleanly -> 80 Mbps.
        now = 52.0
        reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 21_000_000, sent: 0)],
            is64Bit: true
        )
        let full = sampler.read()
        XCTAssertEqual(full.downloadBps, 80_000_000, accuracy: 1.0)
        XCTAssertEqual(full.sessionInBytes, 20_000_000, accuracy: 1.0)
    }

    func testVirtualInterfacesAreNotDoubleCounted() {
        var now: TimeInterval = 1.0
        var reading = NetworkSampler.CounterReading(
            counters: [
                "en2": .init(received: 1_000_000, sent: 0),
                "utun0": .init(received: 1_000_000, sent: 0),
                "awdl0": .init(received: 1_000_000, sent: 0),
                "lo0": .init(received: 1_000_000, sent: 0),
            ],
            is64Bit: true
        )
        let sampler = NetworkSampler(now: { now }, counters: { reading })
        _ = sampler.read()

        now = 2.0
        reading = NetworkSampler.CounterReading(
            counters: [
                "en2": .init(received: 2_000_000, sent: 0),
                "utun0": .init(received: 2_000_000, sent: 0),
                "awdl0": .init(received: 2_000_000, sent: 0),
                "lo0": .init(received: 2_000_000, sent: 0),
            ],
            is64Bit: true
        )
        let snap = sampler.read()
        // Only en2 (+1 MB / 1s = 8 Mbps) counts.
        XCTAssertEqual(snap.downloadBps, 8_000_000, accuracy: 1.0)
        XCTAssertEqual(snap.sessionInBytes, 1_000_000, accuracy: 1.0)
    }

    func test32BitFallbackDistinguishesRolloverFromReset() {
        let wrap: UInt64 = 1 << 32
        var now: TimeInterval = 0.0
        var reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: wrap - 10_000_000, sent: 500_000_000)],
            is64Bit: false
        )
        let sampler = NetworkSampler(now: { now }, counters: { reading })
        _ = sampler.read()

        // received genuinely wrapped (+25 MB over 2s = 100 Mbps),
        // sent reset from 500 MB down to 10 KB (would imply ~3.79 GB / 2s > 10 Gbps -> rejected).
        now = 2.0
        reading = NetworkSampler.CounterReading(
            counters: ["en2": .init(received: 15_000_000, sent: 10_000)],
            is64Bit: false
        )
        let snap = sampler.read()
        XCTAssertEqual(snap.downloadBps, 100_000_000, accuracy: 1.0)
        XCTAssertEqual(snap.uploadBps, 0)
    }
}

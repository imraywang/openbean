// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import OpenBeanKit

final class SyncEstimateTests: XCTestCase {
    func testBytesAndSeconds() {
        // 1 分钟 64 kbps = 480 000 字节
        XCTAssertEqual(SyncEstimate.audioBytes(durationMs: 60_000), 480_000)
        XCTAssertEqual(SyncEstimate.seconds(bytes: 480_000, bytesPerSecond: 40_000), 12)
        XCTAssertEqual(SyncEstimate.seconds(bytes: 250_000, bytesPerSecond: 0), 10)
        XCTAssertEqual(SyncEstimate.seconds(bytes: -5, bytesPerSecond: 40_000), 0)
    }

    func testBlend() {
        XCTAssertEqual(SyncEstimate.blend(old: nil, measured: 40_000), 40_000)
        XCTAssertEqual(SyncEstimate.blend(old: 20_000, measured: 40_000), 26_000)
        XCTAssertEqual(SyncEstimate.blend(old: 20_000, measured: 0), 20_000)
    }

    func testDisplay() {
        XCTAssertEqual(SyncEstimate.display(59), .underMinute)
        XCTAssertEqual(SyncEstimate.display(61), .minutes(2))
        XCTAssertEqual(SyncEstimate.display(19 * 60), .minutes(19))
        XCTAssertEqual(SyncEstimate.display(62 * 60), .hours(1, minutes: 0))
        XCTAssertEqual(SyncEstimate.display(97 * 60), .hours(1, minutes: 35))
    }
}

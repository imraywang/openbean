// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

final class ConnectPlanTests: XCTestCase {
    func testForegroundFirstTryIsTimedAndFallsBackToScan() {
        XCTAssertEqual(ConnectPlan.iOS(knownDevice: true, background: false, attempt: 0),
                       .direct(timeout: ConnectPlan.foregroundDirectTimeout, scanAssist: true, fallbackScan: true))
    }

    func testBackgroundNeverTimesOut() {
        XCTAssertEqual(ConnectPlan.iOS(knownDevice: true, background: true, attempt: 0),
                       .direct(timeout: nil, scanAssist: true, fallbackScan: false))
    }

    func testLaterForegroundTriesKeepAPendingConnect() {
        // 第一次限时直连 + 扫描都没找到（录音豆在盒子里睡着）：之后挂着不超时的 connect，等它醒
        for n in 1...5 {
            XCTAssertEqual(ConnectPlan.iOS(knownDevice: true, background: false, attempt: n),
                           .direct(timeout: nil, scanAssist: true, fallbackScan: false))
        }
    }

    func testUnknownDeviceScansWithServiceFilterInBackground() {
        XCTAssertEqual(ConnectPlan.iOS(knownDevice: false, background: true, attempt: 0), .scan(seconds: 30, servicesOnly: true))
        XCTAssertEqual(ConnectPlan.iOS(knownDevice: false, background: false, attempt: 3), .scan(seconds: 6, servicesOnly: false))
    }

    /// 续传点：被系统中断后，下次从「连续收到的片数 × 166」接着要（真机实测的口径，见 Resume.swift）
    func testResumeAfterBackgroundInterruption() {
        // 中断前零星收到的后面几片不算：从第一个洞续
        let got = SeqRanges([0...1199, 1500...1500])
        let next = ResumePlan.next(received: got, firstSeq: 0, total: 3000)
        XCTAssertEqual(next.offset, 1200 * 166)
        XCTAssertEqual(next.fromSeq, 1200)
    }

    func testResumeWhenOnlyTheEndPacketWasMissing() {
        let got = SeqRanges([0...499])
        let next = ResumePlan.next(received: got, firstSeq: 0, total: 500)
        XCTAssertEqual(next.fromSeq, 499, "差结束包：从最后一片再要，不整个重下")
        XCTAssertEqual(next.offset, 499 * 166)
    }
}

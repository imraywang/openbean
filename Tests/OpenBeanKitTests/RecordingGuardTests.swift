// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanKit
import XCTest

final class RecordingGuardTests: XCTestCase {
    typealias P = DictationStartPolicy

    func testDictationInProgressIsStopped() {
        // App 自己开始的语音输入正在进行时再按一次：结束它
        XCTAssertEqual(P.onToggle(dictating: true), .stopDictation)
        XCTAssertEqual(P.onToggle(dictating: false), .checkRecorder)
    }

    func testIdleRecorderStarts() {
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: false, recorderRecording: false), .start)
    }

    func testRecordOnlyRunningRefuses() {
        // 设备说在录：旁听那段只录音
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: true, recorderRecording: true), .listenIn)
        // 读不到状态：不旁听也不开始
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: true, recorderRecording: nil), .refuse(.recordOnlyRunning))
        // 记录是旧的（错过了停止事件），设备明确说没在录：可以开始
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: true, recorderRecording: false), .start)
    }

    func testRecorderRecordingListensIn() {
        // App 不知道的录音（心力模式整天录、连上之前按键录的会议）：旁听，不开始新录音，也不去停它
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: false, recorderRecording: true), .listenIn)
    }

    func testRelinkRetriesThenHandsOver() {
        XCTAssertEqual(RelinkPolicy.next(afterFailures: 1), .retry(after: 0.5))
        XCTAssertEqual(RelinkPolicy.next(afterFailures: 2), .retry(after: 2))
        XCTAssertEqual(RelinkPolicy.next(afterFailures: RelinkPolicy.attempts), .handOver)
        XCTAssertEqual(RelinkPolicy.next(afterFailures: 9), .handOver)
    }

    func testRelinkOnlyWhenStillConnected() {
        XCTAssertTrue(RelinkPolicy.shouldRelink(requestedStream: true, connected: true))
        // 已经断了：录音豆自己就停了
        XCTAssertFalse(RelinkPolicy.shouldRelink(requestedStream: true, connected: false))
        XCTAssertFalse(RelinkPolicy.shouldRelink(requestedStream: false, connected: true))
    }

    func testRelinkBudgetsCoverScanFallback() {
        // 等重连的时间要盖住一次直连超时（8 秒）+ 扫描（6 秒）+ 重试间隔
        XCTAssertGreaterThan(RelinkPolicy.waitForLink, 8 + 6 + 0.5 + 2)
    }

    func testUnknownStatusStartsButNeverStopsTheFile() {
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: false, recorderRecording: nil), .start)
        XCTAssertFalse(P.mayStopFile(pausedByApp: true, startedByApp: true, recordingBeforeStart: nil))
    }

    func testMayStopFile() {
        XCTAssertTrue(P.mayStopFile(pausedByApp: true, startedByApp: true, recordingBeforeStart: false))
        // 开始前在录、不是 App 开始的、按录音豆按键停的：都不发结束
        XCTAssertFalse(P.mayStopFile(pausedByApp: true, startedByApp: true, recordingBeforeStart: true))
        XCTAssertFalse(P.mayStopFile(pausedByApp: true, startedByApp: false, recordingBeforeStart: nil))
        XCTAssertFalse(P.mayStopFile(pausedByApp: false, startedByApp: true, recordingBeforeStart: false))
    }
}

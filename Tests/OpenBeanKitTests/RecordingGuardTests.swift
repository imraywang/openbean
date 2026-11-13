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
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: true, recorderRecording: true), .refuse(.recordOnlyRunning))
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: true, recorderRecording: nil), .refuse(.recordOnlyRunning))
        // 记录是旧的（错过了停止事件），设备明确说没在录：可以开始
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: true, recorderRecording: false), .start)
    }

    func testRecorderRecordingRefuses() {
        // App 不知道的录音（例如连上之前按键录的会议）：不开始，也不去停它
        XCTAssertEqual(P.afterCheck(recordOnlyRunning: false, recorderRecording: true), .refuse(.recorderRecording))
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

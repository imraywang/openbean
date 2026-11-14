// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class SyncRunTests: XCTestCase {
    private typealias P = SyncRun.StepProgress

    private func makeRun(_ ids: [UInt32] = [1, 2, 3], options: SyncRun.Options = .init()) -> SyncRun {
        SyncRun(ids: ids, options: options, now: Date(timeIntervalSince1970: 0))
    }

    func testStartsWithDownloadRunningAndTheRestWaiting() {
        let r = makeRun()
        XCTAssertEqual(r.progress(.download), P(step: .download, state: .running, done: 0, total: 3))
        XCTAssertEqual(r.progress(.transcribe), P(step: .transcribe, state: .waiting, total: 3))
        XCTAssertEqual(r.progress(.diary), P(step: .diary, state: .waiting))
        XCTAssertEqual(r.progress(.cleanUp), P(step: .cleanUp, state: .waiting))
        XCTAssertFalse(r.settled)
    }

    func testCountsWhileRunning() {
        var r = makeRun()
        r.recordDownloaded(1)
        r.recordDownloaded(2)
        r.recordTranscribed(1, ok: true)
        XCTAssertEqual(r.progress(.download), P(step: .download, state: .running, done: 2, total: 3))
        XCTAssertEqual(r.progress(.transcribe), P(step: .transcribe, state: .running, done: 1, total: 3))
        XCTAssertEqual(r.progress(.diary), P(step: .diary, state: .running, done: 0))
    }

    func testHappyPathSettlesOnceAndCountsDeletions() {
        var r = makeRun([1, 2])
        for id: UInt32 in [1, 2] { r.recordDownloaded(id) }
        r.downloadEnded()
        XCTAssertFalse(r.markFinishedIfSettled())
        for id: UInt32 in [1, 2] {
            r.recordTranscribed(id, ok: true)
            r.recordDiary(id, .written)
            r.recordCleanUp(id, .deleted)
        }
        XCTAssertEqual(r.steps.map(\.state), [.done, .done, .done, .done])
        XCTAssertEqual(r.progress(.cleanUp), P(step: .cleanUp, state: .done, done: 2, total: 2))
        XCTAssertEqual(r.deletedFromRecorder, 2)
        XCTAssertEqual(r.keptOnRecorder, 0)
        XCTAssertTrue(r.markFinishedIfSettled(), "第一次结算发通知")
        XCTAssertFalse(r.markFinishedIfSettled(), "只发一次")
        XCTAssertTrue(r.isFinished)
    }

    func testLLMUnreachableSkipsDiaryButRunStillFinishes() {
        var r = makeRun([1])
        r.recordDownloaded(1)
        r.downloadEnded()
        r.recordTranscribed(1, ok: true)
        r.recordDiary(1, .serviceUnavailable)
        r.recordCleanUp(1, .deleted)
        XCTAssertEqual(r.progress(.diary), P(step: .diary, state: .skipped, done: 0, total: 1, note: .llmUnreachable))
        XCTAssertTrue(r.settled)
    }

    func testLLMUnreachableShowsBeforeAllAreReported() {
        var r = makeRun([1, 2])
        r.recordDownloaded(1)
        r.recordTranscribed(1, ok: true)
        r.recordDiary(1, .serviceUnavailable)
        XCTAssertEqual(r.progress(.diary).note, .llmUnreachable)
        XCTAssertEqual(r.progress(.diary).state, .running)
    }

    func testCleanUpOffInSettings() {
        var r = makeRun([1], options: .init(deletesFromRecorder: false))
        r.recordDownloaded(1)
        r.downloadEnded()
        r.recordTranscribed(1, ok: true)
        r.recordDiary(1, .written)
        XCTAssertEqual(r.progress(.cleanUp), P(step: .cleanUp, state: .skipped, note: .settingOff))
        XCTAssertEqual(r.keptOnRecorder, 0)
        XCTAssertTrue(r.settled)
    }

    func testKeptAndFailedTranscriptionsCountAsKept() {
        var r = makeRun([1, 2, 3])
        for id: UInt32 in [1, 2, 3] { r.recordDownloaded(id) }
        r.downloadEnded()
        r.recordTranscribed(1, ok: true)
        r.recordTranscribed(2, ok: true)
        r.recordTranscribed(3, ok: false)
        r.recordDiary(1, .written)
        r.recordDiary(2, .written)
        r.recordCleanUp(1, .deleted)
        r.recordCleanUp(2, .kept)
        XCTAssertEqual(r.progress(.transcribe), P(step: .transcribe, state: .done, done: 2, total: 3, note: .failedCount(1)))
        XCTAssertEqual(r.progress(.diary), P(step: .diary, state: .done, done: 2, total: 2))
        XCTAssertEqual(r.progress(.cleanUp), P(step: .cleanUp, state: .done, done: 1, total: 3, note: .kept(2)))
        XCTAssertTrue(r.settled)
    }

    func testBusyDeviceCountsAsSettledAndUpdatesLater() {
        var r = makeRun([1])
        r.recordDownloaded(1)
        r.downloadEnded()
        r.recordTranscribed(1, ok: true)
        r.recordDiary(1, .written)
        r.recordCleanUp(1, .busy)
        XCTAssertEqual(r.progress(.cleanUp), P(step: .cleanUp, state: .running, done: 0, total: 1, note: .deviceBusy))
        XCTAssertTrue(r.markFinishedIfSettled(), "等连接的不挡住通知")
        r.recordCleanUp(1, .deleted)
        XCTAssertEqual(r.progress(.cleanUp).state, .done)
        XCTAssertEqual(r.deletedFromRecorder, 1)
        r.recordCleanUp(1, .busy)
        XCTAssertEqual(r.deletedFromRecorder, 1, "删掉了就是删掉了，之后的「忙」不改")
    }

    func testInterruptedDownloadFailsWithLeftCount() {
        var r = makeRun([1, 2, 3])
        r.recordDownloaded(1)
        r.downloadEnded()
        XCTAssertEqual(r.progress(.download), P(step: .download, state: .failed, done: 1, total: 3, note: .left(2)))
        XCTAssertEqual(r.progress(.transcribe), P(step: .transcribe, state: .running, done: 0, total: 1))
    }

    func testNothingDownloaded() {
        var r = makeRun([1])
        r.downloadEnded()
        XCTAssertEqual(r.progress(.download), P(step: .download, state: .failed, done: 0, total: 1, note: .left(1)))
        XCTAssertEqual(r.progress(.transcribe).note, .nothingNew)
        XCTAssertEqual(r.progress(.diary).note, .nothingNew)
        XCTAssertEqual(r.progress(.cleanUp).note, .nothingNew)
        XCTAssertTrue(r.settled)
        XCTAssertFalse(r.broughtSomething)
    }

    func testPauseForVoiceTypingThenResumeMergesIds() {
        var r = makeRun([1, 2])
        r.recordDownloaded(1)
        r.downloadPaused()
        XCTAssertEqual(r.progress(.download).note, .pausedForVoiceTyping)
        XCTAssertFalse(r.settled)
        r.downloadStarted([2])
        XCTAssertEqual(r.expected, [1, 2])
        XCTAssertEqual(r.progress(.download), P(step: .download, state: .running, done: 1, total: 2))
    }

    func testIgnoresRecordingsFromOutsideTheRun() {
        var r = makeRun([1])
        r.recordTranscribed(9, ok: true)
        r.recordDiary(9, .written)
        r.recordCleanUp(9, .deleted)
        XCTAssertEqual(r.deletedFromRecorder, 0)
        XCTAssertTrue(r.transcribed.isEmpty)
    }

    func testTranscriptionOffSkipsDiary() {
        var r = makeRun([1], options: .init(autoTranscribe: false))
        r.recordDownloaded(1)
        r.downloadEnded()
        XCTAssertEqual(r.progress(.transcribe).note, .settingOff)
        XCTAssertEqual(r.progress(.diary).state, .skipped)
        XCTAssertEqual(r.keptOnRecorder, 1, "没转写不会从心力豆删")
        XCTAssertTrue(r.settled)
    }

    func testDiaryFailure() {
        var r = makeRun([1, 2])
        r.recordDownloaded(1); r.recordDownloaded(2)
        r.downloadEnded()
        r.recordTranscribed(1, ok: true); r.recordTranscribed(2, ok: true)
        r.recordDiary(1, .written); r.recordDiary(2, .failed)
        XCTAssertEqual(r.progress(.diary), P(step: .diary, state: .failed, done: 1, total: 2, note: .failedCount(1)))
    }
}

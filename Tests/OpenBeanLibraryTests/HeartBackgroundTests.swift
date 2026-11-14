// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class HeartBackgroundTests: XCTestCase {
    private let work2 = HeartWork(untranscribed: 2, seconds: 3600)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    // MARK: 口袋里的一次完整流程

    func testPocketFlowSchedulesProcessingAfterDownload() {
        var p = HeartPipeline(app: .background)
        XCTAssertEqual(p.handle(.syncStarted), [.holdBackgroundTime])
        XCTAssertEqual(p.phase, .syncing)
        XCTAssertEqual(p.handle(.syncEnded(failed: false, work: work2)), [.releaseBackgroundTime, .scheduleProcessing(.standard)])
        XCTAssertEqual(p.phase, .waitingToProcess)
        XCTAssertEqual(p.handle(.processingLaunched(work: work2)), [.processNow])
        XCTAssertEqual(p.phase, .processing)
        XCTAssertEqual(p.handle(.processingFinished(work: .none)), [])
        XCTAssertEqual(p.phase, .idle)
    }

    func testProcessingRequestDoesNotNeedPowerOrNetwork() {
        XCTAssertFalse(ProcessingRequest.standard.requiresExternalPower)
        XCTAssertFalse(ProcessingRequest.standard.requiresNetwork)
    }

    func testExpiredTaskStopsAndReschedulesTheRest() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncEnded(failed: false, work: work2))
        _ = p.handle(.processingLaunched(work: work2))
        XCTAssertEqual(p.handle(.processingExpired(work: HeartWork(untranscribed: 1))), [.stopProcessing, .scheduleProcessing(.standard)])
        XCTAssertEqual(p.phase, .waitingToProcess)
    }

    func testForegroundCatchesUpAndCancelsTheScheduledTask() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncEnded(failed: false, work: work2))
        XCTAssertEqual(p.handle(.becameActive(work: work2)), [.cancelProcessing, .processNow])
        XCTAssertEqual(p.phase, .processing)
        XCTAssertEqual(p.app, .active)
    }

    func testForegroundWithNothingLeftJustCancels() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncEnded(failed: false, work: work2))
        XCTAssertEqual(p.handle(.becameActive(work: .none)), [.cancelProcessing])
        XCTAssertEqual(p.phase, .idle)
    }

    func testGoingToBackgroundMidProcessingHandsOverToTheTask() {
        var p = HeartPipeline(app: .active)
        XCTAssertEqual(p.handle(.syncEnded(failed: false, work: work2)), [.releaseBackgroundTime, .processNow])
        XCTAssertEqual(p.handle(.enteredBackground(work: HeartWork(untranscribed: 1))), [.stopProcessing, .scheduleProcessing(.standard)])
        XCTAssertEqual(p.phase, .waitingToProcess)
    }

    func testBackgroundSyncHoldsTimeWhenAppLeavesMidDownload() {
        var p = HeartPipeline(app: .active)
        XCTAssertEqual(p.handle(.syncStarted), [])
        XCTAssertEqual(p.handle(.enteredBackground(work: .none)), [.holdBackgroundTime])
    }

    func testTaskLaunchedDuringADownloadWaitsForIt() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncEnded(failed: false, work: work2))
        _ = p.handle(.syncStarted) // 又一批（比如断了以后续传）
        XCTAssertEqual(p.handle(.processingLaunched(work: work2)), [.scheduleProcessing(.standard)])
        XCTAssertEqual(p.phase, .syncing)
    }

    func testANewDownloadPausesBackgroundProcessing() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncEnded(failed: false, work: work2))
        _ = p.handle(.processingLaunched(work: work2))
        XCTAssertEqual(p.handle(.syncStarted), [.holdBackgroundTime, .stopProcessing])
    }

    func testNothingDownloadedNeedsNoTask() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncStarted)
        XCTAssertEqual(p.handle(.syncEnded(failed: false, work: .none)), [.releaseBackgroundTime])
        XCTAssertEqual(p.phase, .idle)
    }

    // MARK: 要用户处理的事

    func testRepeatedFailuresNotifyOnceUntilTheIntervalPasses() {
        var p = HeartPipeline(app: .background)
        for n in 1..<HeartPipeline.failuresBeforeNotice {
            XCTAssertEqual(p.handle(.syncEnded(failed: true, work: .none), now: t0), [.releaseBackgroundTime], "第 \(n) 次")
        }
        XCTAssertEqual(p.handle(.syncEnded(failed: true, work: .none), now: t0), [.releaseBackgroundTime, .notify(.syncKeepsFailing)])
        XCTAssertEqual(p.handle(.syncEnded(failed: true, work: .none), now: t0.addingTimeInterval(3600)), [.releaseBackgroundTime])
        XCTAssertEqual(p.handle(.syncEnded(failed: true, work: .none), now: t0.addingTimeInterval(HeartPipeline.noticeInterval + 1)),
                       [.releaseBackgroundTime, .notify(.syncKeepsFailing)])
    }

    func testASuccessResetsTheFailureCount() {
        var p = HeartPipeline(app: .background)
        _ = p.handle(.syncEnded(failed: true, work: .none))
        _ = p.handle(.syncEnded(failed: true, work: .none))
        _ = p.handle(.syncEnded(failed: false, work: .none))
        XCTAssertEqual(p.failures, 0)
        XCTAssertEqual(p.handle(.syncEnded(failed: true, work: .none)), [.releaseBackgroundTime])
    }

    func testMissingSpeechModelNotifiesInsteadOfScheduling() {
        var p = HeartPipeline(app: .background, speechModelReady: false)
        XCTAssertEqual(p.handle(.syncEnded(failed: false, work: work2), now: t0), [.releaseBackgroundTime, .notify(.speechModelMissing)])
        XCTAssertEqual(p.phase, .idle)
        // 回到前台也不硬做（模型下载在设置里）
        XCTAssertEqual(p.handle(.becameActive(work: work2)), [])
        p.speechModelReady = true
        XCTAssertEqual(p.handle(.becameActive(work: work2)), [.cancelProcessing, .processNow])
    }

    // MARK: 四步条

    func testMobileStepsFollowTheSharedRun() {
        var r = SyncRun(ids: [1, 2], options: .init(), now: t0)
        var rows = MobileSyncSteps.rows(r)
        XCTAssertEqual(rows.map(\.step), [.sync, .transcribe, .segment, .diary])
        XCTAssertEqual(MobileSyncSteps.current(r)?.step, .sync)
        r.recordDownloaded(1); r.recordDownloaded(2); r.downloadEnded()
        r.recordTranscribed(1, ok: true)
        rows = MobileSyncSteps.rows(r)
        XCTAssertEqual(rows[2].progress.state, .running)
        XCTAssertEqual(rows[2].progress.done, 1)
        XCTAssertEqual(MobileSyncSteps.current(r)?.step, .transcribe)
        r.recordTranscribed(2, ok: false)
        rows = MobileSyncSteps.rows(r)
        XCTAssertEqual(rows[1].progress.state, .done) // 一条成功一条失败：转写算完成，带「1 条失败」
        XCTAssertEqual(rows[2].progress, SyncRun.StepProgress(step: .transcribe, state: .done, done: 1))
    }

    func testSegmentSkippedWhenEveryTranscriptionFailed() {
        var r = SyncRun(ids: [1], options: .init(), now: t0)
        r.recordDownloaded(1); r.downloadEnded()
        r.recordTranscribed(1, ok: false)
        XCTAssertEqual(MobileSyncSteps.rows(r)[2].progress.state, .skipped)
    }

    // MARK: 待办勾选

    func testTodoStateKeepsOnlyCurrentItems() {
        let current = ["回复刘经理", "发提案"]
        var s = DayTodoState()
        s = s.setting("回复刘经理", done: true, current: current)
        XCTAssertTrue(s.isDone("回复刘经理"))
        s = DayTodoState(done: ["旧的一条", "回复刘经理"]).setting("发提案", done: true, current: current)
        XCTAssertEqual(s.done, ["回复刘经理", "发提案"])
        s = s.setting("回复刘经理", done: false, current: current)
        XCTAssertEqual(s.done, ["发提案"])
        let round = try? JSONDecoder().decode(DayTodoState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(round, s)
    }
}

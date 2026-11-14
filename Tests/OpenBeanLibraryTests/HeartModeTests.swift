// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class HeartModeTests: XCTestCase {
    // MARK: 心力模式介绍（替代静默迁移）

    func testFreshInstallSeesIntroAfterOnboardingWithDefaults() {
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: nil, introSeen: false, onboardingDone: false, legacyDailyDiary: false),
                       .show(.afterOnboarding, HeartIntro.Prefill(deleteFromRecorder: true, audioRetention: .sevenDays, hadDailyDiary: false)))
    }

    func testExistingUserSeesIntroAtLaunch() {
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: nil, introSeen: false, onboardingDone: true, legacyDailyDiary: false),
                       .show(.atLaunch, HeartIntro.Prefill()))
    }

    func testDiaryUserSeesIntroPrefilledButNothingTurnsOn() throws {
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: nil, introSeen: false, onboardingDone: true, legacyDailyDiary: true),
                       .show(.atLaunch, HeartIntro.Prefill(deleteFromRecorder: true, audioRetention: .sevenDays, hadDailyDiary: true)))
        let name = "openbean-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: ModeKeys.legacyDailyDiary)
        d.set(true, forKey: "onboardingDone")
        guard case .show(.atLaunch, let p) = HeartIntro.run(d) else { return XCTFail("应该看到介绍") }
        XCTAssertTrue(p.hadDailyDiary)
        XCTAssertNil(d.object(forKey: ModeKeys.heartMode), "介绍之前不写心力模式开关")
        XCTAssertFalse(ModeDefaults(defaults: d).heartMode, "旧的日记开关不再自动打开心力模式")
        XCTAssertFalse(d.bool(forKey: ModeKeys.heartIntroSeen))
    }

    func testPrefillKeepsStoredChoices() {
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: false, introSeen: false, onboardingDone: true, legacyDailyDiary: false,
                                         storedDelete: false, storedRetention: .forever),
                       .show(.atLaunch, HeartIntro.Prefill(deleteFromRecorder: false, audioRetention: .forever)))
    }

    func testAlreadyOnStaysOnAndIsNotAsked() throws {
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: true, introSeen: false, onboardingDone: true, legacyDailyDiary: true), .alreadyOn)
        let name = "openbean-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: ModeKeys.heartMode)
        XCTAssertEqual(HeartIntro.run(d), .alreadyOn)
        XCTAssertTrue(ModeDefaults(defaults: d).heartMode)
        XCTAssertTrue(d.bool(forKey: ModeKeys.heartIntroSeen), "以后关掉再启动也不会自动弹介绍")
        d.set(false, forKey: ModeKeys.heartMode)
        XCTAssertEqual(HeartIntro.run(d), .seen)
    }

    func testSeenIntroIsNotShownAgain() {
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: false, introSeen: true, onboardingDone: true, legacyDailyDiary: true), .seen)
        XCTAssertEqual(HeartIntro.decide(storedHeartMode: nil, introSeen: true, onboardingDone: false, legacyDailyDiary: false), .seen)
    }

    func testDefaultsReadFromEmptyPreferences() throws {
        let name = "openbean-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        let m = ModeDefaults(defaults: d)
        XCTAssertEqual(m, ModeDefaults(heartMode: false))
        XCTAssertTrue(m.heartDeleteFromRecorder)
        XCTAssertFalse(m.heartRecordingNotes)
        XCTAssertFalse(m.heartAgentTranscripts)
        XCTAssertEqual(m.heartAudioRetention, .sevenDays)
    }

    // MARK: 随模式变的取值

    func testNormalModeKeepsExistingSettings() {
        let m = ModeDefaults(heartMode: false, autoSyncSetting: false, notesSetting: true, heartRecordingNotes: false)
        XCTAssertEqual(m.landing, .today, "关着时也落在心力模式页")
        XCTAssertFalse(m.autoSync)
        XCTAssertFalse(m.autoSyncLocked)
        XCTAssertFalse(m.writesDiary)
        XCTAssertTrue(m.writesRecordingNotes)
        XCTAssertEqual(m.sourceForSync, .normal)
        XCTAssertFalse(m.deletesFromRecorderAfterSync)
        XCTAssertEqual(m.audioRetention, .forever)
        XCTAssertFalse(m.callsDeviceHeartBean)
    }

    func testHeartModeDefaults() {
        let m = ModeDefaults(heartMode: true, autoSyncSetting: false, notesSetting: true)
        XCTAssertEqual(m.landing, .today)
        XCTAssertTrue(m.autoSync, "心力模式下放回充电盒固定自动同步")
        XCTAssertTrue(m.autoSyncLocked)
        XCTAssertTrue(m.writesDiary)
        XCTAssertFalse(m.writesRecordingNotes, "心力模式默认只写日记，普通模式的笔记开关不算")
        XCTAssertEqual(m.sourceForSync, .heart)
        XCTAssertTrue(m.deletesFromRecorderAfterSync)
        XCTAssertEqual(m.audioRetention, .sevenDays)
        XCTAssertTrue(m.callsDeviceHeartBean)
    }

    func testHeartModeOptionalRecordingNotes() {
        XCTAssertTrue(ModeDefaults(heartMode: true, notesSetting: false, heartRecordingNotes: true).writesRecordingNotes)
    }

    // MARK: 来源

    func testSourceParsing() {
        XCTAssertEqual(RecordingSource(stored: nil), .normal)
        XCTAssertEqual(RecordingSource(stored: "heart"), .heart)
        XCTAssertEqual(RecordingSource(stored: "something-new"), .normal)
    }

    func testIndexWithoutSourceIsNormal() throws {
        let entry: [String: Any] = ["id": 7, "start": 800_000_000.0, "durationMs": 1000]
        XCTAssertEqual(Parse.recording(entry)?.source, .normal)
        var heart = entry
        heart["source"] = "heart"
        XCTAssertEqual(Parse.recording(heart)?.source, .heart)
    }

    // MARK: 本机音频保留期

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func keep(_ source: RecordingSource = .heart, _ retention: AudioRetention = .sevenDays, audio: Bool = true,
                      lines: Int? = 10, age: TimeInterval = 8 * 86_400, awaiting: Bool = false) -> AudioRetentionPolicy.Keep? {
        AudioRetentionPolicy.check(source: source, retention: retention, audioExists: audio, transcriptLines: lines,
                                   syncedAt: now.addingTimeInterval(-age), now: now, awaitingRecorderDelete: awaiting)
    }

    func testRetentionDeletesOldHeartAudio() {
        XCTAssertNil(keep())
    }

    func testRetentionNeverTouchesNormalRecordings() {
        XCTAssertEqual(keep(.normal, .afterTranscription), .notHeartSource)
    }

    func testRetentionForever() {
        XCTAssertEqual(keep(.heart, .forever, age: 400 * 86_400), .keepForever)
    }

    func testRetentionNeedsATranscript() {
        XCTAssertEqual(keep(lines: nil), .noTranscript)
        XCTAssertEqual(keep(lines: 0), .noTranscript)
    }

    func testRetentionWaitsSevenDays() {
        guard case let .tooRecent(left)? = keep(age: 6 * 86_400) else { return XCTFail() }
        XCTAssertEqual(left, 86_400, accuracy: 1)
    }

    func testRetentionAfterTranscription() {
        XCTAssertNil(keep(.heart, .afterTranscription, age: 0))
    }

    func testRetentionKeepsAudioWhileRecorderDeleteIsPending() {
        XCTAssertEqual(keep(.heart, .afterTranscription, age: 0, awaiting: true), .awaitingRecorderDelete)
    }

    func testRetentionNoAudio() {
        XCTAssertEqual(keep(audio: false), .noAudio)
    }

    func testHeartModeOffMeansKeepForever() {
        let m = ModeDefaults(heartMode: false, heartAudioRetention: .afterTranscription)
        XCTAssertEqual(keep(.heart, m.audioRetention, age: 0), .keepForever)
    }

    // MARK: 同步后自动从设备删除（前置条件）

    private func cleanup(mode: ModeDefaults = ModeDefaults(heartMode: true), source: RecordingSource = .heart,
                         thisSync: Bool = true, complete: Bool = true, transcript: Bool = true) -> RecorderCleanupPolicy.Refusal? {
        RecorderCleanupPolicy.check(mode: mode, source: source, downloadedThisSync: thisSync,
                                    downloadComplete: complete, transcriptExists: transcript)
    }

    func testCleanupAllowed() {
        XCTAssertNil(cleanup())
    }

    func testCleanupRefusals() {
        XCTAssertEqual(cleanup(mode: ModeDefaults(heartMode: false)), .settingOff)
        XCTAssertEqual(cleanup(mode: ModeDefaults(heartMode: true, heartDeleteFromRecorder: false)), .settingOff)
        XCTAssertEqual(cleanup(source: .normal), .notHeartSource)
        XCTAssertEqual(cleanup(thisSync: false), .notDownloadedThisSync)
        XCTAssertEqual(cleanup(complete: false), .downloadIncomplete)
        XCTAssertEqual(cleanup(transcript: false), .notTranscribed)
    }

    // MARK: Agent 读原文

    func testTranscriptVisibility() {
        XCTAssertTrue(HeartPrivacy.transcriptVisible(source: .normal, agentMayReadHeartTranscripts: false))
        XCTAssertFalse(HeartPrivacy.transcriptVisible(source: .heart, agentMayReadHeartTranscripts: false))
        XCTAssertTrue(HeartPrivacy.transcriptVisible(source: .heart, agentMayReadHeartTranscripts: true))
    }
}

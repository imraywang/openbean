// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class HeartModeTests: XCTestCase {
    // MARK: 迁移

    func testMigrationTurnsHeartModeOnForDiaryUsers() {
        XCTAssertEqual(HeartMigration.heartMode(stored: nil, legacyDailyDiary: true), true)
    }

    func testMigrationWritesOffOnceForOthers() {
        XCTAssertEqual(HeartMigration.heartMode(stored: nil, legacyDailyDiary: false), false)
    }

    func testMigrationNeverOverridesAChoice() {
        XCTAssertNil(HeartMigration.heartMode(stored: false, legacyDailyDiary: true))
        XCTAssertNil(HeartMigration.heartMode(stored: true, legacyDailyDiary: false))
    }

    func testMigrationOnUserDefaults() throws {
        let name = "openbean-test-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { d.removePersistentDomain(forName: name) }
        d.set(true, forKey: ModeKeys.legacyDailyDiary)
        XCTAssertEqual(HeartMigration.run(d), true)
        XCTAssertTrue(ModeDefaults(defaults: d).heartMode)
        // 用户之后关掉：再启动不会被旧开关改回去
        d.set(false, forKey: ModeKeys.heartMode)
        XCTAssertNil(HeartMigration.run(d))
        XCTAssertFalse(ModeDefaults(defaults: d).heartMode)
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
        XCTAssertEqual(m.landing, .library)
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

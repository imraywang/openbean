// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class VoiceTypingTests: XCTestCase {
    /// 录音 id 1794629301 = 开始时刻（Unix 秒）
    let start = Date(timeIntervalSince1970: 1_794_629_301)

    func at(_ s: Double) -> Date { start.addingTimeInterval(s) }

    func testStoreRoundTripAndAppendSorts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = VoiceTypingLog.url(library: dir)
        XCTAssertEqual(VoiceTypingLog.read(url).intervals, [])
        try VoiceTypingLog.append(.init(start: at(100), end: at(110)), to: url)
        try VoiceTypingLog.append(.init(start: at(20), end: at(30)), to: url)
        let l = VoiceTypingLog.read(url)
        XCTAssertEqual(l.intervals.map(\.start), [at(20), at(100)])
        XCTAssertEqual(l.version, VoiceTypingLog.currentVersion)
    }

    func testReadIsLenient() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = VoiceTypingLog.url(library: dir)
        try Data(#"{"intervals":[{"start":"2026-11-13T10:00:00Z","end":"2026-11-13T10:00:05Z"},{"start":"junk"},{}],"extra":1}"#.utf8).write(to: url)
        XCTAssertEqual(VoiceTypingLog.read(url).intervals.count, 1)
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(VoiceTypingLog.read(url).intervals, [])
    }

    func testEndBeforeStartIsClamped() {
        XCTAssertEqual(VoiceTypingLog.Interval(start: at(10), end: at(5)).end, at(10))
    }

    func testLinesInsideIntervalAreSkipped() {
        let log = VoiceTypingLog(intervals: [.init(start: at(60), end: at(70))])
        let spans: [(start: Double, end: Double)] = [
            (10, 14),     // 0 早得多
            (55, 57.5),   // 1 放宽 1.5 秒后只碰到边：重叠不到一半
            (59, 62),     // 2 跨进开始：大半在里面
            (63, 68),     // 3 完全在里面
            (69, 72),     // 4 跨出结束（加上放宽）：大半在里面
            (71, 76),     // 5 只有一小截在放宽范围里
            (65, 65),     // 6 零长度、在里面
            (90, 95),     // 7 之后
        ]
        XCTAssertEqual(log.voiceTypingLines(spans, recordingStart: start), [2, 3, 4, 6])
    }

    func testOnlyHeartRecordingsAreFiltered() {
        let log = VoiceTypingLog(intervals: [.init(start: at(0), end: at(100))])
        let spans: [(start: Double, end: Double)] = [(10, 20)]
        XCTAssertEqual(log.voiceTypingLines(source: .heart, spans: spans, recordingStart: start), [0])
        XCTAssertEqual(log.voiceTypingLines(source: .normal, spans: spans, recordingStart: start), [])
    }

    func testEmptyLogSkipsNothing() {
        XCTAssertEqual(VoiceTypingLog().voiceTypingLines([(0, 1)], recordingStart: start), [])
    }

    // MARK: 切段

    typealias L = ConversationFile.Line

    /// 两场谈话（中间停了 10 分钟），第一场里插了一段语音输入
    var lines: [L] {
        [L(start: 0, end: 5, text: "a"), L(start: 6, end: 10, text: "b"),
         L(start: 11, end: 14, text: "dictated 1"), L(start: 15, end: 18, text: "dictated 2"),
         L(start: 19, end: 22, text: "c"),
         L(start: 700, end: 705, text: "d"), L(start: 706, end: 710, text: "e")]
    }

    func testNoVoiceTypingIsUnchanged() {
        let a = ConversationFile.build(lines, recordingStart: start, wallApprox: false)
        let b = ConversationFile.build(lines, recordingStart: start, wallApprox: false, voiceTyping: [])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.voiceTyping, [])
        XCTAssertTrue(a.segments.allSatisfy { $0.voiceTyping.isEmpty })
    }

    func testVoiceTypingLinesAreLeftOutOfSegments() {
        let plain = ConversationFile.build(lines, recordingStart: start, wallApprox: false)
        let f = ConversationFile.build(lines, recordingStart: start, wallApprox: false, voiceTyping: [2, 3])
        XCTAssertEqual(f.voiceTyping, [2, 3])
        XCTAssertEqual(f.segments.count, 2)
        // 段仍然首尾相接、盖住整份转写（详情页靠这个分节）
        XCTAssertEqual(f.segments.first?.from, 0)
        XCTAssertEqual(f.segments.last?.to, lines.count)
        XCTAssertEqual(f.segments[0].to, f.segments[1].from)
        XCTAssertEqual(f.segments[0].voiceTyping, [2, 3])
        XCTAssertEqual(f.segments[0].spokenLines, [0, 1, 4])
        XCTAssertEqual(f.segments[1].spokenLines, [5, 6])
        // 段的指纹只看说的话：变了，段摘要会重写
        XCTAssertNotEqual(f.segments[0].hash, plain.segments[0].hash)
        XCTAssertEqual(f.segments[0].hash, ConversationFile.fingerprint([lines[0], lines[1], lines[4]]))
        XCTAssertEqual(f.segments[1].hash, plain.segments[1].hash)
        // 文件仍对得上转写，但语音输入句子变了就算过时
        let h = ConversationFile.fingerprint(lines)
        XCTAssertTrue(f.isCurrent(transcriptHash: h, voiceTyping: [2, 3]))
        XCTAssertFalse(f.isCurrent(transcriptHash: h))
        XCTAssertFalse(plain.isCurrent(transcriptHash: h, voiceTyping: [2]))
    }

    func testVoiceTypingAtEdgesStillCoversTranscript() {
        // 开头和两场之间的句子是语音输入：开头的归第一段，中间的归前一段
        let f = ConversationFile.build(lines, recordingStart: start, wallApprox: false, voiceTyping: [0, 4])
        XCTAssertEqual(f.segments.map(\.from), [0, 5])
        XCTAssertEqual(f.segments.map(\.to), [5, 7])
        XCTAssertEqual(f.segments[0].voiceTyping, [0, 4])
        // 段的起止按说的话算
        XCTAssertEqual(f.segments[0].start, 6)
        XCTAssertEqual(f.segments[0].end, 18)
    }

    func testAllVoiceTypingGivesNoSegments() {
        let f = ConversationFile.build(lines, recordingStart: start, wallApprox: false, voiceTyping: Set(0..<7))
        XCTAssertEqual(f.segments, [])
    }

    func testVoiceTypingRoundTripsAndIsOmittedWhenEmpty() throws {
        let f = ConversationFile.build(lines, recordingStart: start, wallApprox: false, voiceTyping: [2, 3])
        let d = try f.encoded()
        XCTAssertEqual(try JSONDecoder().decode(ConversationFile.self, from: d), f)
        let plain = try ConversationFile.build(lines, recordingStart: start, wallApprox: false).encoded()
        XCTAssertFalse(String(decoding: plain, as: UTF8.self).contains("voiceTyping"))
    }
}

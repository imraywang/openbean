// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanLibrary
import XCTest

final class SegmenterTests: XCTestCase {
    /// 按「开始时刻、时长」造句子
    private func lines(_ items: [(Double, Double)]) -> [Segmenter.Line] {
        items.map { Segmenter.Line(start: $0.0, end: $0.0 + $0.1) }
    }

    /// 连续说话：每 gap 秒一句、每句 len 秒，从 t0 开始 n 句
    private func talk(from t0: Double, count n: Int, every gap: Double = 6, len: Double = 4) -> [(Double, Double)] {
        (0..<n).map { (t0 + Double($0) * gap, len) }
    }

    func testEmptyTranscriptHasNoSegments() {
        XCTAssertEqual(Segmenter.split([]), [])
    }

    func testSingleSentenceIsOneSegment() {
        let p = Segmenter.split(lines([(3.5, 2)]))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].lines, 0..<1)
        XCTAssertEqual(p[0].start, 3.5)
        XCTAssertEqual(p[0].end, 5.5)
        XCTAssertEqual(p[0].cut, .recordingStart)
        XCTAssertEqual(p[0].candidates, [])
    }

    func testShortRecordingIsOneSegment() {
        let p = Segmenter.split(lines(talk(from: 1, count: 8, every: 5)))
        XCTAssertEqual(p.map(\.lines), [0..<8])
    }

    func testLongSilenceSplits() {
        // 两段谈话中间隔了 16 分钟
        let a = talk(from: 0, count: 10), b = talk(from: 60 + 960, count: 10)
        let p = Segmenter.split(lines(a + b))
        XCTAssertEqual(p.map(\.lines), [0..<10, 10..<20])
        XCTAssertEqual(p.map(\.cut), [.recordingStart, .silence])
        XCTAssertEqual(p[1].start, 1020)
        XCTAssertEqual(p[0].end, 58)
    }

    func testHardGapIsInclusive() {
        // 停顿正好 120 秒：切；119.9 秒：不切，记作候选
        let exact = Segmenter.split(lines([(0, 10), (130, 5)]))
        XCTAssertEqual(exact.count, 2)
        let under = Segmenter.split(lines([(0, 10), (129.9, 5)]))
        XCTAssertEqual(under.count, 1)
        XCTAssertEqual(under[0].candidates, [1])
    }

    func testSoftGapsAreCandidatesOnly() {
        // 一段谈话里停了 45 秒、29 秒、90 秒：只有 45 和 90 是候选，都不切
        let p = Segmenter.split(lines([(0, 5), (50, 5), (84, 5), (179, 5), (185, 5)]))
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].candidates, [1, 3])
    }

    func testCandidatesBelongToTheirSegment() {
        let p = Segmenter.split(lines([(0, 5), (40, 5), (400, 5), (440, 5)]))
        XCTAssertEqual(p.map(\.lines), [0..<2, 2..<4])
        XCTAssertEqual(p[0].candidates, [1])
        XCTAssertEqual(p[1].candidates, [3]) // 段的第一句前的长停顿不算段内候选
    }

    func testOverlongSegmentSplitsAtLargestPause() {
        // 100 分钟不停的谈话（每 10 秒一句），第 40 分钟停了 25 秒、第 70 分钟停了 40 秒
        var items: [(Double, Double)] = []
        var t = 0.0
        for i in 0..<600 {
            if i == 240 { t += 25 }
            if i == 420 { t += 40 }
            items.append((t, 8))
            t += 10
        }
        let p = Segmenter.split(lines(items))
        // 100 分钟分三份：等分点（约 33、67 分钟）附近分别挑 25 秒和 40 秒的停顿
        XCTAssertEqual(p.map(\.lines), [0..<240, 240..<420, 420..<600])
        XCTAssertEqual(p.map(\.cut), [.recordingStart, .maxLength, .maxLength])
        XCTAssertTrue(p.allSatisfy { $0.end - $0.start <= 45 * 60 })
    }

    func testOverlongSplitAvoidsSlivers() {
        // 最大的停顿在开头第二句前：切那里只会切下一句；在等分点附近挑那里最大的停顿
        var items: [(Double, Double)] = [(0, 5), (35, 5)]
        var t = 45.0
        for i in 0..<360 {
            if i == 180 { t += 20 }
            items.append((t, 8))
            t += 10
        }
        let p = Segmenter.split(lines(items))
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[1].lines.lowerBound, 182)
    }

    func testOverlongWithoutPausesSplitsNearMiddle() {
        // 一个小时，句子首尾相接没有停顿：在中间切
        let p = Segmenter.split(lines((0..<360).map { (Double($0) * 10, 10) }))
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0].lines.count, 180)
    }

    func testSingleHugeSentenceIsNotSplit() {
        // 一句话本身超过最大长度（例如整段直接识别的兜底）：没法再切
        let p = Segmenter.split(lines([(0, 4000)]))
        XCTAssertEqual(p.count, 1)
    }

    func testOutOfOrderAndOverlappingTimestampsDoNotSplit() {
        // 时间戳乱序（后一句比前一句早）和重叠：停顿是负数，不切；段的起止取最早和最晚
        let p = Segmenter.split(lines([(100, 10), (50, 5), (105, 20), (110, 2), (300, 5)]))
        // 第 4 句之前最晚的结束是 125，停顿 175 秒：切
        XCTAssertEqual(p.map(\.lines), [0..<4, 4..<5])
        XCTAssertEqual(p[0].start, 50)
        XCTAssertEqual(p[0].end, 125)
    }

    func testEndBeforeStartAndNonFiniteValues() {
        let raw = [Segmenter.Line(start: 10, end: 5), Segmenter.Line(start: .nan, end: .nan),
                   Segmenter.Line(start: 20, end: .infinity), Segmenter.Line(start: 400, end: 405)]
        let p = Segmenter.split(raw)
        XCTAssertEqual(p.map(\.lines), [0..<3, 3..<4])
        XCTAssertEqual(p[0].start, 5)
        XCTAssertEqual(p[0].end, 20)
        XCTAssertTrue(p.allSatisfy { $0.start.isFinite && $0.end.isFinite })
    }

    func testAllNonFiniteGivesOneSegmentAtZero() {
        let p = Segmenter.split([Segmenter.Line(start: .nan, end: .nan), Segmenter.Line(start: .nan, end: .nan)])
        XCTAssertEqual(p.count, 1)
        XCTAssertEqual(p[0].start, 0)
    }

    func testParamsAreRespected() {
        let items = lines([(0, 5), (70, 5), (140, 5)])
        XCTAssertEqual(Segmenter.split(items, params: .init(hardGap: 60, softGap: 20, maxLength: 3600)).count, 3)
        XCTAssertEqual(Segmenter.split(items).count, 1)
        // 关掉最大长度（0）：再长也不切
        let long = lines((0..<400).map { (Double($0) * 10, 9) })
        XCTAssertEqual(Segmenter.split(long, params: .init(maxLength: 0)).count, 1)
    }

    func testSegmentsCoverAllLinesInOrder() {
        var items: [(Double, Double)] = []
        var t = 0.0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            items.append((t, Double.random(in: 1...15, using: &rng)))
            t += Double.random(in: 0...200, using: &rng) < 2 ? Double.random(in: 120...3000, using: &rng) : Double.random(in: 2...40, using: &rng)
        }
        let p = Segmenter.split(lines(items))
        XCTAssertEqual(p.first?.lines.lowerBound, 0)
        XCTAssertEqual(p.last?.lines.upperBound, 2000)
        for (a, b) in zip(p, p.dropFirst()) { XCTAssertEqual(a.lines.upperBound, b.lines.lowerBound) }
        XCTAssertTrue(p.allSatisfy { !$0.lines.isEmpty })
    }
}

final class ConversationFileTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_550_000)

    private func transcript() -> [ConversationFile.Line] {
        [.init(start: 1, end: 4, text: "早上好"), .init(start: 5, end: 9, text: "我们开始吧"),
         .init(start: 700, end: 705, text: "下一个会"), .init(start: 708, end: 712, text: "好")]
    }

    func testBuildSetsWallClockAndHashes() {
        let f = ConversationFile.build(transcript(), recordingStart: t0, wallApprox: false)
        XCTAssertEqual(f.segments.count, 2)
        XCTAssertEqual(f.segments[1].wallStart, t0.addingTimeInterval(700))
        XCTAssertEqual(f.segments[1].wallEnd, t0.addingTimeInterval(712))
        XCTAssertEqual(f.segments.map(\.index), [0, 1])
        XCTAssertNotEqual(f.segments[0].hash, f.segments[1].hash)
        XCTAssertTrue(f.isCurrent(transcriptHash: ConversationFile.fingerprint(transcript())))
        XCTAssertNil(f.segments[0].summary)
        XCTAssertEqual(f.segments[0].marks, [])
    }

    func testFingerprintChangesWithTextAndTime() {
        var t = transcript()
        let h = ConversationFile.fingerprint(t)
        t[1].text = "我们开始"
        XCTAssertNotEqual(ConversationFile.fingerprint(t), h)
        t = transcript()
        t[0].start = 1.5
        XCTAssertNotEqual(ConversationFile.fingerprint(t), h)
        XCTAssertEqual(ConversationFile.fingerprint(transcript()), h)
    }

    func testStaleWhenParamsOrVersionChange() {
        let f = ConversationFile.build(transcript(), recordingStart: t0, wallApprox: false)
        let h = ConversationFile.fingerprint(transcript())
        XCTAssertFalse(f.isCurrent(transcriptHash: h, params: .init(hardGap: 60)))
        var old = f
        old.segmenter = 0
        XCTAssertFalse(old.isCurrent(transcriptHash: h))
    }

    func testRebuildKeepsSummaryOfUnchangedSegments() {
        var f = ConversationFile.build(transcript(), recordingStart: t0, wallApprox: false)
        f.segments[0].summary = ConversationSummary(title: "早会")
        f.segments[0].kind = "conversation"
        f.segments[1].summary = ConversationSummary(title: "下一个")
        var t = transcript()
        t[3].text = "好的" // 只改第二段
        let g = ConversationFile.build(t, recordingStart: t0, wallApprox: false, previous: f)
        XCTAssertEqual(g.segments[0].summary?.title, "早会")
        XCTAssertEqual(g.segments[0].kind, "conversation")
        XCTAssertNil(g.segments[1].summary)
    }

    func testRoundTripUsesISODates() throws {
        var f = ConversationFile.build(transcript(), recordingStart: t0, wallApprox: true)
        f.segments[0].summarizedAt = t0
        let data = try f.encoded()
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try XCTUnwrap((json["segments"] as? [[String: Any]])?.first)
        XCTAssertTrue(first["wallStart"] is String)
        XCTAssertTrue(first["summary"] is NSNull)
        let back = try JSONDecoder().decode(ConversationFile.self, from: data)
        XCTAssertEqual(back, f)
        XCTAssertTrue(back.segments[0].wallApprox)
    }

    func testDecodingIsLenient() throws {
        // 缺字段、多字段、类型不对、坏掉的段；日期写成数字（参考时间秒数）
        let json = """
        {"version": 1, "segmenter": 1, "future": {"x": 1}, "transcriptHash": "abc",
         "segments": [
           {"from": 0, "to": 3, "start": 1, "wallStart": 815000000, "summary": {"title": "t", "todos": ["a", 3, "b"], "extra": true}},
           {"from": "oops"},
           {"from": 5, "to": 2},
           {"from": 3, "to": 7, "kind": 12, "marks": "no", "cut": "llm", "wallStart": "2026-11-13T09:12:05+08:00"}
         ]}
        """
        let f = try JSONDecoder().decode(ConversationFile.self, from: Data(json.utf8))
        XCTAssertEqual(f.params, .standard)
        XCTAssertEqual(f.segments.count, 2)
        XCTAssertEqual(f.segments[0].summary?.todos, ["a", "b"])
        XCTAssertEqual(f.segments[0].wallStart, Date(timeIntervalSinceReferenceDate: 815_000_000))
        XCTAssertEqual(f.segments[0].end, 1)
        XCTAssertNil(f.segments[1].kind)
        XCTAssertEqual(f.segments[1].marks, [])
        XCTAssertEqual(f.segments[1].cut, .silence) // 不认识的切段原因
        XCTAssertEqual(f.segments[1].wallStart, ISODate.parse("2026-11-13T01:12:05Z"))
        XCTAssertFalse(f.isCurrent(transcriptHash: "abc", params: .init(hardGap: 1)))
    }

    func testGarbageFileReadsAsNil() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("seg-\(UUID()).json")
        try Data("[1, 2]".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(ConversationFile.read(url))
        XCTAssertNil(ConversationFile.read(url.appendingPathExtension("missing")))
    }

    func testLikelyPaused() {
        XCTAssertFalse(ConversationFile.likelyPaused(start: t0, end: t0.addingTimeInterval(601.3), duration: 600))
        XCTAssertTrue(ConversationFile.likelyPaused(start: t0, end: t0.addingTimeInterval(900), duration: 600))
        XCTAssertFalse(ConversationFile.likelyPaused(start: t0, end: nil, duration: 600))
        // 设备给的结束时刻是 0（存成 1970 年）：不知道，不当作暂停
        XCTAssertFalse(ConversationFile.likelyPaused(start: t0, end: Date(timeIntervalSince1970: 0), duration: 600))
    }
}

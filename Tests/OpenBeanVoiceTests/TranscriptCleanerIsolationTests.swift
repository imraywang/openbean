// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

/// 干净版只给人读：存着的转写和发给大模型的内容，设置开着关着都一字不差
final class TranscriptCleanerIsolationTests: XCTestCase {
    private let segs = [
        TranscriptSegment(start: 0, end: 3, text: "呃，然后，我我觉得这个这个方案可以。", raw: "呃，然后，我我觉得这个这个方案可以。", isWearer: true),
        TranscriptSegment(start: 3, end: 4, text: "嗯。"),
        TranscriptSegment(start: 4, end: 9, text: "我们要合合合作，下周一呃再碰一下。", isWearer: false),
    ]

    /// 摘要要够长才写：后面再接几句正常的话
    private var long: [TranscriptSegment] {
        segs + (0..<6).map { TranscriptSegment(start: 10 + Double($0) * 5, end: 14 + Double($0) * 5,
                                               text: "第\($0)句，我们讨论了项目进度、预算和下一步的安排。") }
    }

    private func encoded(_ s: [TranscriptSegment]) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return try e.encode(s)
    }

    func testStoredTranscriptAndLLMInputAreIdenticalWithCleanOnOrOff() async throws {
        let stored = try encoded(segs)
        var bodies: [Data] = []
        for clean in [false, true, false] {
            // 读的时候（详情、复制、导出、笔记）按设置取每句的文字……
            let shown = TranscriptCleaner.lines(segs.map(\.text), clean: clean)
            XCTAssertEqual(shown.count, segs.count)
            // ……摘要拿的还是原文
            let stub = try StubServer { _ in #"{"title":"方案","summary":"讨论了方案。","key_points":["方案可以"],"action_items":[]}"# }
            _ = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)
                .summarize(long.map { TimedLine(start: $0.start, text: $0.text) })
            stub.stop()
            let req = try XCTUnwrap(stub.requests.first)
            bodies.append(try JSONSerialization.data(withJSONObject: req["messages"] ?? [], options: .sortedKeys))
            XCTAssertEqual(try encoded(segs), stored)
        }
        XCTAssertEqual(bodies[0], bodies[1])
        XCTAssertEqual(bodies[1], bodies[2])
        let prompt = String(decoding: bodies[0], as: UTF8.self)
        XCTAssertTrue(prompt.contains("合合合作"), "the LLM gets the original sentences")
    }

    func testReadingLinesKeepIndices() {
        let shown = TranscriptCleaner.lines(segs.map(\.text), clean: true)
        XCTAssertEqual(shown, ["我觉得这个方案可以。", "", "我们要合作，下周一再碰一下。"])
        XCTAssertEqual(TranscriptCleaner.lines(segs.map(\.text), clean: false), segs.map(\.text))
        XCTAssertEqual(TranscriptCleaner.cached("嗯，好的。"), TranscriptCleaner.clean("嗯，好的。"))
    }

    func testNoteSkipsEmptyLinesButKeepsMarkedOnes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let lines = TranscriptCleaner.lines(segs.map(\.text), clean: true).enumerated()
            .map { TimedLine(start: segs[$0.offset].start, text: $0.element) }
        var v = NoteTemplate.Values(title: "t", start: start, duration: 9, recordingID: 1, summary: nil, lines: lines,
                                    timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertEqual(v.dictionary["transcript"], "[00:00] 我觉得这个方案可以。\n\n[00:04] 我们要合作，下周一再碰一下。")
        v.marks = [1: [3.2]]
        XCTAssertEqual(v.dictionary["transcript"], "[00:00] 我觉得这个方案可以。\n\n[00:03] ⚑ [00:03] \n\n[00:04] 我们要合作，下周一再碰一下。")
    }
}

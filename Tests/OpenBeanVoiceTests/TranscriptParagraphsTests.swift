// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class TranscriptParagraphsTests: XCTestCase {
    private func seg(_ start: Double, _ end: Double, _ text: String = "好的") -> TranscriptSegment {
        TranscriptSegment(start: start, end: end, text: text)
    }

    func testEmpty() {
        XCTAssertEqual(TranscriptParagraphs.group([]), [])
    }

    func testSplitsOnLongPause() {
        let s = [seg(0, 2), seg(2.5, 4), seg(7, 9), seg(9.3, 10)]
        XCTAssertEqual(TranscriptParagraphs.group(s, gap: 2), [0..<2, 2..<4])
    }

    func testPauseExactlyAtGapStaysTogether() {
        XCTAssertEqual(TranscriptParagraphs.group([seg(0, 1), seg(3, 4)], gap: 2), [0..<2])
    }

    func testSplitsLongParagraphByLength() {
        let long = String(repeating: "字", count: 150)
        let s = (0..<5).map { seg(Double($0), Double($0) + 0.9, long) }
        // 每段到 280 字以上就断：150、300 → 断；所以两句一段
        XCTAssertEqual(TranscriptParagraphs.group(s, maxChars: 280), [0..<2, 2..<4, 4..<5])
    }

    func testJoiner() {
        XCTAssertEqual(TranscriptParagraphs.joiner(after: "I think we can.", before: "OK"), " ")
        XCTAssertEqual(TranscriptParagraphs.joiner(after: "好的。", before: "OK"), "")
        XCTAssertEqual(TranscriptParagraphs.joiner(after: "version B", before: "转化更好"), "")
        XCTAssertEqual(TranscriptParagraphs.joiner(after: "", before: "a"), "")
    }
}

// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class TranscriptCorrectionTests: XCTestCase {
    typealias T = TranscriptCorrection

    private func apply(_ terms: [String], _ text: String, raw: String? = nil) -> T.Line {
        T.apply(GlossaryCorrector(terms: terms), text: text, raw: raw)
    }

    func testAliasKeepsRaw() {
        let l = apply(["大模型 = 大冒险"], "我们用大冒险写了摘要")
        XCTAssertEqual(l, T.Line(text: "我们用大模型写了摘要", raw: "我们用大冒险写了摘要"))
    }

    func testUnchangedHasNoRaw() {
        XCTAssertEqual(apply(["大模型 = 大冒险"], "今天天气不错"), T.Line(text: "今天天气不错"))
        XCTAssertEqual(apply([], "我们用大冒险写了摘要"), T.Line(text: "我们用大冒险写了摘要"))
    }

    func testIdempotent() {
        let terms = ["大模型 = 大冒险", "录音豆"]
        let once = apply(terms, "大冒险和录音逗")
        let twice = apply(terms, once.text, raw: once.raw)
        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.text, "大模型和录音豆")
    }

    func testRecomputeFromRawAfterGlossaryChange() {
        // 别名写错了：改成 LLM 之后，从原文重算，而不是在已经改坏的文字上再改
        let first = apply(["大模型 = 大冒险"], "大冒险")
        let second = apply(["LLM = 大冒险"], first.text, raw: first.raw)
        XCTAssertEqual(second, T.Line(text: "LLM", raw: "大冒险"))
    }

    func testRemovedTermRestoresRaw() {
        let first = apply(["大模型 = 大冒险"], "玩大冒险")
        XCTAssertEqual(first.text, "玩大模型")
        let restored = apply([], first.text, raw: first.raw)
        XCTAssertEqual(restored, T.Line(text: "玩大冒险"))
    }

    // MARK: 长文本的误改保护

    func testTranscriptModeIsStricterForHomophones() {
        let c = GlossaryCorrector(terms: ["张伟", "大模型"])
        // 两字词条：语音输入会改，转写不改（长篇里同音两字组合太多）
        XCTAssertEqual(c.correct("张维今天来了").text, "张伟今天来了")
        XCTAssertEqual(c.correct("张维今天来了", mode: .transcript).text, "张维今天来了")
        // 三字词条错两个字：语音输入会改，转写不改
        XCTAssertEqual(c.correct("打魔型").text, "大模型")
        XCTAssertEqual(c.correct("打魔型", mode: .transcript).text, "打魔型")
        // 三字词条只错一个字：转写也改
        XCTAssertEqual(c.correct("交给大模星整理", mode: .transcript).text, "交给大模型整理")
    }

    func testTranscriptModeStillAppliesAliasesAndLatin() {
        let c = GlossaryCorrector(terms: ["张伟 = 章维", "Claude Code = cloud code", "OpenBean"])
        XCTAssertEqual(c.correct("章维说 cloud code 和 open bean 都好用", mode: .transcript).text,
                       "张伟说 Claude Code 和 OpenBean 都好用")
    }

    func testLongTranscriptNoFalsePositives() {
        // 一段编的会议转写：常见说法里有不少和词条同音或近音的两字、三字组合，转写模式下一个都不该改
        let terms = ["公式", "识别", "实时", "张伟", "模型", "工具", "周报", "大模型", "录音豆", "知识库"]
        let text = """
        今天下午开会，我们先公事公办把上周的周报过一遍。出门时别忘了带钥匙，开始时间是三点。\
        张维说这个工具的攻势很猛，模形还要再调。大家一致认为录音都很清楚，知识也够用。\
        办公室的空调坏了，实施计划推迟到下周。他识别出了问题，然后我们讨论了实时字幕。
        """
        let c = GlossaryCorrector(terms: terms)
        let r = c.correct(text, mode: .transcript)
        XCTAssertEqual(r.text, text, "误改：\(r.replacements)")
    }

    // MARK: 回填

    func testGlossaryHash() {
        let a = T.glossaryHash(["# 我的词表", "大模型 = 大冒险", "", "录音豆"])
        // 注释、空行、等号两边的空格不影响
        XCTAssertEqual(a, T.glossaryHash(["大模型=大冒险", "录音豆", "# 另一条注释"]))
        // 改别名、加词条、删词条都会变
        XCTAssertNotEqual(a, T.glossaryHash(["大模型 = 大冒险, 打模型", "录音豆"]))
        XCTAssertNotEqual(a, T.glossaryHash(["大模型 = 大冒险", "录音豆", "知识库"]))
        XCTAssertNotEqual(a, T.glossaryHash(["录音豆"]))
    }

    func testNeedsBackfill() {
        let h = T.glossaryHash(["大模型 = 大冒险"])
        XCTAssertFalse(T.needsBackfill(currentHash: h, lastApplied: h))
        XCTAssertTrue(T.needsBackfill(currentHash: h, lastApplied: nil))
        XCTAssertTrue(T.needsBackfill(currentHash: h, lastApplied: T.glossaryHash([])))
        XCTAssertTrue(T.needsBackfill(currentHash: h, lastApplied: h, force: true))
    }
}

final class TranscriptSegmentTests: XCTestCase {
    func testCodingWithAndWithoutRaw() throws {
        let segs = [TranscriptSegment(start: 0, end: 1.5, text: "大模型", raw: "大冒险"),
                    TranscriptSegment(start: 1.5, end: 3, text: "没改过")]
        let data = try JSONEncoder().encode(segs)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(json[0]["raw"] as? String, "大冒险")
        XCTAssertNil(json[1]["raw"], "没改过的句子不写 raw")
        XCTAssertEqual(try JSONDecoder().decode([TranscriptSegment].self, from: data), segs)
        // 老文件：没有 raw 字段照常能读
        let old = Data(#"[{"start":0,"end":1,"text":"老的一句"}]"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode([TranscriptSegment].self, from: old),
                       [TranscriptSegment(start: 0, end: 1, text: "老的一句")])
    }

    func testBackfillOneTranscript() {
        var segs = [TranscriptSegment(start: 0, end: 1, text: "玩大冒险"),
                    TranscriptSegment(start: 1, end: 2, text: "今天天气不错")]
        let c = GlossaryCorrector(terms: ["大模型 = 大冒险"])
        XCTAssertEqual(TranscriptCorrection.apply(c, to: &segs), 1)
        XCTAssertEqual(segs[0], TranscriptSegment(start: 0, end: 1, text: "玩大模型", raw: "玩大冒险"))
        XCTAssertEqual(segs[1], TranscriptSegment(start: 1, end: 2, text: "今天天气不错"))
        // 第二遍：什么都不变
        XCTAssertEqual(TranscriptCorrection.apply(c, to: &segs), 0)
        // 删掉词条：还原，raw 去掉
        XCTAssertEqual(TranscriptCorrection.apply(GlossaryCorrector(terms: []), to: &segs), 1)
        XCTAssertEqual(segs[0], TranscriptSegment(start: 0, end: 1, text: "玩大冒险"))
    }
}

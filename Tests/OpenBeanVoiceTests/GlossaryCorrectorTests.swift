// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class GlossaryCorrectorTests: XCTestCase {
    private func fix(_ terms: [String], _ s: String) -> String { GlossaryCorrector(terms: terms).correct(s).text }

    func testPinyin() {
        XCTAssertEqual(Pinyin.latin("录"), "lu")
        XCTAssertEqual(Pinyin.latin("绿"), "lv")          // ü 不和 u 混
        XCTAssertTrue(Pinyin.readings("行").isSuperset(of: ["xing", "hang"]))
        XCTAssertEqual(Pinyin.fuzzy("zhang"), "zan")
        XCTAssertEqual(Pinyin.fuzzy("ling"), "nin")
    }

    func testChineseHomophone() {
        let c = GlossaryCorrector(terms: ["录音豆", "大模型"])
        let r = c.correct("我用录音逗录了一段，然后交给大模星整理。")
        XCTAssertEqual(r.text, "我用录音豆录了一段，然后交给大模型整理。")
        XCTAssertEqual(r.replacements, [.init(original: "录音逗", replacement: "录音豆"),
                                        .init(original: "大模星", replacement: "大模型")])
    }

    func testPolyphone() {
        // 「行」默认读 xing，异读 hang 也要能对上
        XCTAssertEqual(fix(["招商银行"], "我在招商银航开了户"), "我在招商银行开了户")
        XCTAssertEqual(fix(["重庆"], "我下周去崇庆出差"), "我下周去重庆出差")
    }

    func testNoOpWhenCorrect() {
        let c = GlossaryCorrector(terms: ["录音豆", "OpenBean", "Claude Code"])
        let s = "录音豆配合 OpenBean 和 Claude Code 一起用。"
        let r = c.correct(s)
        XCTAssertEqual(r.text, s)
        XCTAssertTrue(r.replacements.isEmpty)
    }

    func testLongestMatch() {
        // 「录音豆」和「录音豆子」都在词表里，取长的
        XCTAssertEqual(fix(["录音豆", "录音豆子"], "这个录音逗子挺好"), "这个录音豆子挺好")
        // 已经正确的长词不被短词拆坏
        XCTAssertEqual(fix(["智能录音豆", "录音逗"], "智能录音豆来了"), "智能录音豆来了")
    }

    func testLatinCasingAndSpacing() {
        let terms = ["OpenBean", "Claude Code", "SenseVoice", "macOS"]
        XCTAssertEqual(fix(terms, "open bean 很好用"), "OpenBean 很好用")
        XCTAssertEqual(fix(terms, "我在用openbean做语音输入"), "我在用OpenBean做语音输入")
        XCTAssertEqual(fix(terms, "Open-Bean"), "OpenBean")
        XCTAssertEqual(fix(terms, "用 claude code 写的"), "用 Claude Code 写的")
        XCTAssertEqual(fix(terms, "claudecode"), "Claude Code")
        XCTAssertEqual(fix(terms, "sense voice 识别"), "SenseVoice 识别")
        XCTAssertEqual(fix(terms, "MACOS 26"), "macOS 26")
        // 小写单词条：长片段允许中间一个空格
        XCTAssertEqual(fix(["openbean"], "Open Bean 和 OPENBEAN"), "openbean 和 openbean")
    }

    func testLatinWordBoundaries() {
        let terms = ["OpenBean", "Code"]
        XCTAssertEqual(fix(terms, "openbeans"), "openbeans")
        XCTAssertEqual(fix(terms, "reopenbean"), "reopenbean")
        XCTAssertEqual(fix(terms, "barcode"), "barcode")
        XCTAssertEqual(fix(terms, "code2"), "code2")
        XCTAssertEqual(fix(terms, "写code"), "写Code")
    }

    func testPunctuationUntouched() {
        XCTAssertEqual(fix(["录音豆"], "录音逗，录音逗！录音逗？"), "录音豆，录音豆！录音豆？")
        // 标点把字隔开时不算一个词
        XCTAssertEqual(fix(["录音豆"], "录音，逗你玩"), "录音，逗你玩")
        XCTAssertEqual(fix(["Claude Code"], "Claude, code"), "Claude, code")
    }

    func testMixedLanguage() {
        let terms = ["录音豆", "OpenBean", "D3200", "K Tempo"]
        XCTAssertEqual(fix(terms, "录音逗 d3200 接上 open bean 以后，k tempo 也能用"),
                       "录音豆 D3200 接上 OpenBean 以后，K Tempo 也能用")
        XCTAssertEqual(fix(["SenseVoice模型"], "sensevoice魔型"), "SenseVoice模型")
    }

    func testEmptyList() {
        let c = GlossaryCorrector(terms: [])
        XCTAssertTrue(c.isEmpty)
        XCTAssertEqual(c.correct("录音逗").text, "录音逗")
        XCTAssertTrue(GlossaryCorrector(terms: ["# 注释", "  ", "豆"]).isEmpty)
    }

    func testFunctionCharacterGuard() {
        // 「都」与「豆」同音，但「都」是高频虚词，不改
        XCTAssertEqual(fix(["录音豆"], "这几段录音都很清楚"), "这几段录音都很清楚")
    }

    func testTwoCharacterTerms() {
        // 只错一个字、且两个字不是现成的词：改
        XCTAssertEqual(fix(["张伟"], "张维今天来了"), "张伟今天来了")
        // 现成的常用词：不改
        XCTAssertEqual(fix(["公式"], "我们公事公办"), "我们公事公办")
        // 两个字都不同：不改
        XCTAssertEqual(fix(["公式"], "攻势很猛"), "攻势很猛")
        // 和邻字连成词、或带虚词：不改
        XCTAssertEqual(fix(["实时"], "开始时间到了"), "开始时间到了")
        XCTAssertEqual(fix(["公式"], "去办公室"), "去办公室")
        XCTAssertEqual(fix(["识别"], "出门时别忘了带钥匙"), "出门时别忘了带钥匙")
    }

    func testFuzzyOnlyForLongTerms() {
        // n/l、前后鼻音：3 字以上且只差一个字时才改
        XCTAssertEqual(fix(["牛肉面"], "来一碗流肉面"), "来一碗牛肉面")
        XCTAssertEqual(fix(["大模型"], "大模性"), "大模型")
        XCTAssertEqual(fix(["大模型"], "大模森"), "大模森")       // xing/sen 不算近音
        XCTAssertEqual(fix(["牛肉面"], "流肉免"), "流肉免")       // 近音时其余字必须原样
        XCTAssertEqual(fix(["牛奶"], "流奶"), "流奶")             // 两字词不开近音
    }

    func testCommonPhrasesUnchanged() {
        let terms = ["录音豆", "大模型", "openbean", "公式", "工具", "张伟", "模型", "识别", "实时", "李明",
                     "Claude Code", "SenseVoice", "周报", "飞书", "微信"]
        let sentences = [
            "今天下午3点，我们在会议室讨论一下新版本的发布计划。",
            "我们来测试一下，用录音豆实时录音的一个效果。",
            "我看了这个效果好像还不错哎，但是这个识别的成功率，包括说这个错字该怎么来提高呢？",
            "我觉得这个整体的速度还是可以的，准确度其实也还不错。",
            "这几段录音都很清楚，录音都已经传上去了。",
            "这个公事公办吧，别拖了。",
            "他的攻势很猛，我们要注意。",
            "这些都是很实际的问题。",
            "我们识别一下这个声音。",
            "实时识别其实是一个很难的事。",
            "这个工具很好用，但是工具箱里还缺一把扳手。",
            "他们公司今年的营收很好。",
            "我喜欢读书，也喜欢写东西。",
            "黎明的时候我们出发。",
            "周报明天交，飞书上提醒我。",
            "这是一个模型，那个是魔性的舞蹈。",
            "代码写完了要 code review。",
            "我们打开微信看看。",
            "这个事情的实质是什么？",
            "历史上这件事很有名。",
        ]
        let c = GlossaryCorrector(terms: terms)
        for s in sentences {
            let r = c.correct(s)
            XCTAssertEqual(r.text, s, "误改：\(r.replacements)")
        }
    }

    func testOverheadIsSmall() {
        let terms = (0..<200).map { "术语\($0)" } + ["录音豆", "大模型", "OpenBean", "Claude Code", "张伟"]
        let c = GlossaryCorrector(terms: terms)
        let s = "我觉得这个整体的速度还是可以的，准确度其实也还不错，录音逗配合 open bean 很方便。"
        _ = c.correct(s)
        let t0 = Date()
        for _ in 0..<100 { _ = c.correct(s) }
        let ms = Date().timeIntervalSince(t0) * 1000 / 100
        print("每句耗时 \(String(format: "%.3f", ms)) ms（205 个词条）")
        XCTAssertLessThan(ms, 20)
    }
}

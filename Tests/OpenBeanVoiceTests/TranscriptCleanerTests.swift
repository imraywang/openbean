// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class TranscriptCleanerTests: XCTestCase {
    private func clean(_ s: String) -> String { TranscriptCleaner.clean(s) }

    // MARK: 语气词

    func testFillerSoundsAnywhere() {
        XCTAssertEqual(clean("我们呃下午再开会。"), "我们下午再开会。")
        XCTAssertEqual(clean("嗯，这个方案可以。"), "这个方案可以。")
        XCTAssertEqual(clean("回复之后呃，大概要两天。"), "回复之后，大概要两天。")
        XCTAssertEqual(clean("先看品类嗯嗯，再定价格。"), "先看品类，再定价格。")
    }

    func testStandaloneInterjections() {
        XCTAssertEqual(clean("啊，我想起来了。"), "我想起来了。")
        XCTAssertEqual(clean("哦，原来是这样。"), "原来是这样。")
        XCTAssertEqual(clean("好的，哎，我们走吧。"), "好的，我们走吧。")
        XCTAssertEqual(clean("嗯哼。"), "")
    }

    func testInterjectionsInsideWordsStay() {
        // 句末语气、词里的字都不动
        XCTAssertEqual(clean("这家店好快啊。"), "这家店好快啊。")
        XCTAssertEqual(clean("金额不对。"), "金额不对。")
        XCTAssertEqual(clean("哎呀，忘带钥匙了。"), "哎呀，忘带钥匙了。")
        XCTAssertEqual(clean("额外的费用谁出？"), "额外的费用谁出？")
    }

    func testWholeSentenceOfFillersIsEmpty() {
        XCTAssertEqual(clean("嗯。"), "")
        XCTAssertEqual(clean("呃呃，啊。"), "")
        XCTAssertEqual(clean("嗯，嗯。"), "")
        XCTAssertEqual(clean("。"), "")
        XCTAssertEqual(clean(""), "")
        XCTAssertEqual(clean("um."), "")
    }

    func testEnglishFillers() {
        XCTAssertEqual(clean("I um think so."), "I think so.")
        XCTAssertEqual(clean("Uh, let's start."), "let's start.")
        // 词里的 um、er 不动
        XCTAssertEqual(clean("The umbrella is under the tree."), "The umbrella is under the tree.")
    }

    // MARK: 口吃

    func testStutteredCharacters() {
        XCTAssertEqual(clean("我们要合合合作。"), "我们要合作。")
        XCTAssertEqual(clean("我我觉得可以。"), "我觉得可以。")
        XCTAssertEqual(clean("你你你知道吗？"), "你知道吗？")
        XCTAssertEqual(clean("他们在做产产品。"), "他们在做产品。")
    }

    func testReduplicationIsProtected() {
        XCTAssertEqual(clean("你先看看这个文件。"), "你先看看这个文件。")
        XCTAssertEqual(clean("我们刚刚到公司。"), "我们刚刚到公司。")
        XCTAssertEqual(clean("慢慢来，不着急。"), "慢慢来，不着急。")
        XCTAssertEqual(clean("谢谢你们的支持。"), "谢谢你们的支持。")
        XCTAssertEqual(clean("他天天都来。"), "他天天都来。")
        XCTAssertEqual(clean("哈哈哈，太好笑了。"), "哈哈哈，太好笑了。")
        XCTAssertEqual(clean("要认认真真地做。"), "要认认真真地做。")
        XCTAssertEqual(clean("我们去试试吧。"), "我们去试试吧。")
    }

    func testWordBoundaryRepeatsAreProtected() {
        // 前一个字属于前面的词、后一个字属于后面的词，不是口吃
        XCTAssertEqual(clean("中国国家队赢了。"), "中国国家队赢了。")
        XCTAssertEqual(clean("工厂生产产品。"), "工厂生产产品。")
        XCTAssertEqual(clean("以后后面的事再说。"), "以后后面的事再说。")
        XCTAssertEqual(clean("他现在在家。"), "他现在在家。")
    }

    func testNumbersAndUnitsAreProtected() {
        XCTAssertEqual(clean("预算是1000块。"), "预算是1000块。")
        XCTAssertEqual(clean("2025年年底上线。"), "2025年年底上线。")
        XCTAssertEqual(clean("上上周我们见过。"), "上上周我们见过。")
        XCTAssertEqual(clean("一一对应就行。"), "一一对应就行。")
    }

    func testNamesAtClauseEndAreProtected() {
        XCTAssertEqual(clean("谢谢春春。"), "谢谢春春。")
    }

    func testAnswersCollapse() {
        XCTAssertEqual(clean("对对对，就是这样。"), "对，就是这样。")
        XCTAssertEqual(clean("好好好。"), "好。")
    }

    // MARK: 重复的词、短语

    func testRepeatedWordsAndPhrases() {
        XCTAssertEqual(clean("我也我也去过。"), "我也去过。")
        XCTAssertEqual(clean("然后然后我们就回家了。"), "然后我们就回家了。")
        XCTAssertEqual(clean("你现在你现在在哪？"), "你现在在哪？")
        XCTAssertEqual(clean("我们相互学习相互学习。"), "我们相互学习。")
        XCTAssertEqual(clean("他把门关掉了，关掉了。"), "他把门关掉了。")
    }

    func testCommaRepeatThatContinuesStays() {
        // 第二遍接着往下说，可能是有意的
        XCTAssertEqual(clean("要看我的水平，我的水平是有点差的。"), "要看我的水平，我的水平是有点差的。")
    }

    func testDistributivesAndVerbReduplicationStay() {
        XCTAssertEqual(clean("一个一个地检查。"), "一个一个地检查。")
        XCTAssertEqual(clean("我们一点一点来。"), "我们一点一点来。")
        XCTAssertEqual(clean("这件事我们再研究研究。"), "这件事我们再研究研究。")
    }

    func testRepeatsMustFollowWordBoundaries() {
        // 「我感」不是一个词：拿不准，留着
        XCTAssertEqual(clean("我感我感觉不错。"), "我感我感觉不错。")
        XCTAssertEqual(clean("你现在在哪？"), "你现在在哪？")
    }

    func testEnglishRepeats() {
        XCTAssertEqual(clean("I think the the plan works."), "I think the plan works.")
        XCTAssertEqual(clean("I know that that is true."), "I know that that is true.")
        XCTAssertEqual(clean("Bye bye."), "Bye bye.")
    }

    // MARK: 话头

    func testLeadingDiscourseWithComma() {
        XCTAssertEqual(clean("然后，我们去了上海。"), "我们去了上海。")
        XCTAssertEqual(clean("就是说，这个不行。"), "这个不行。")
        XCTAssertEqual(clean("那个，你明天有空吗？"), "你明天有空吗？")
        XCTAssertEqual(clean("好的。然后，下一个问题。"), "好的。下一个问题。")
    }

    func testDiscourseWordsWithoutPauseStay() {
        XCTAssertEqual(clean("然后我们去了上海。"), "然后我们去了上海。")
        XCTAssertEqual(clean("这个方案可以。"), "这个方案可以。")
        XCTAssertEqual(clean("我们先吃饭，然后，再去看电影。"), "我们先吃饭，然后，再去看电影。")
        XCTAssertEqual(clean("这就是我们要的。"), "这就是我们要的。")
        XCTAssertEqual(clean("对，就是这样。"), "对，就是这样。")
    }

    func testDiscourseWordNextToFiller() {
        XCTAssertEqual(clean("能力很强，然后就是呃你只要说一句话。"), "能力很强，然后你只要说一句话。")
        XCTAssertEqual(clean("就是呃如果你愿意的话。"), "如果你愿意的话。")
        XCTAssertEqual(clean("我们看一下。那个呃，报价单在这里。"), "我们看一下。报价单在这里。")
        // 「这个」后面直接是名词时是「这个文件」，不删
        XCTAssertEqual(clean("你看这个呃文件。"), "你看这个文件。")
        // 「这就是」是判断，不是话头
        XCTAssertEqual(clean("这就是呃一个例子。"), "这就是一个例子。")
    }

    func testGuardKeepsDiscourseWhenItWouldHalveTheSentence() {
        // 话头删掉一半以上的字时不删话头（语气词照删）
        XCTAssertEqual(clean("就是说，好。"), "就是说，好。")
    }

    // MARK: 标点、混合、性质

    func testPunctuationTidying() {
        XCTAssertEqual(clean("好的，呃。"), "好的。")
        XCTAssertEqual(clean("我们，嗯，，下午见。"), "我们，下午见。")
        XCTAssertEqual(clean("呃，，下午见。"), "下午见。")
        XCTAssertEqual(clean("OK, um, let's go."), "OK, let's go.")
    }

    func testMixedChineseAndEnglish() {
        XCTAssertEqual(clean("我们用AI呃做一个demo demo。"), "我们用AI做一个demo。")
        XCTAssertEqual(clean("这个app app呃很好用。"), "这个app很好用。")
        XCTAssertEqual(clean("用GPT写PPT。"), "用GPT写PPT。")
    }

    func testCleanTextIsUnchanged() {
        let s = "今天下午三点在会议室开会，记得带上电脑。"
        XCTAssertEqual(clean(s), s)
    }

    func testIdempotent() {
        for s in sentences { XCTAssertEqual(clean(clean(s)), clean(s), s) }
    }

    /// 只删不加、不换顺序：干净版是原文的子序列
    func testOnlyDeletes() {
        for s in sentences {
            var it = s.makeIterator()
            for c in clean(s) {
                var found = false
                while let o = it.next() { if o == c { found = true; break } }
                XCTAssertTrue(found, s)
            }
        }
    }

    func testLongSentence() {
        let piece = "然后呃我我觉得这个这个方案还是可以的，就是呃预算需要再看看，"
        let long = String(repeating: piece, count: 60) + "好的。"
        let out = clean(long)
        XCTAssertFalse(out.contains("呃"))
        XCTAssertFalse(out.contains("我我"))
        XCTAssertTrue(out.contains("再看看"))
        XCTAssertEqual(clean(out), out)
        XCTAssertLessThan(out.count, long.count)
    }

    func testTraceCountsRules() {
        let t = TranscriptCleaner.trace("嗯，我我也我也去过。")
        XCTAssertEqual(t.text, "我也去过。")
        XCTAssertEqual(t.removed[.fillerSound], 1)
        XCTAssertEqual(t.removed[.stutter], 1)
        XCTAssertEqual(t.removed[.repeatedPhrase], 2)
        XCTAssertEqual(t.removed[.punctuation], 1)
    }

    private let sentences = [
        "然后呃我我觉得这个这个方案还是可以的。", "嗯，对对对，就是这样。", "合合合作的事情我们再聊聊。",
        "你现在你现在在哪？", "OK, um, let's go.", "啊，。", "就是说，好。", "这个app app呃很好用。",
        "中国国家队赢了。", "哈哈哈，太好笑了。", "他把门关掉了，关掉了，关掉了。", "我我我我我我。", "呃呃嗯嗯。",
    ]
}

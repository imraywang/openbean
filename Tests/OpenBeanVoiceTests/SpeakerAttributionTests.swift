// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanVoice
import XCTest

// 「谁说的」：别人用「我」说自己的产品和工作、别人说的事实、对方主动替佩戴者做的事、不知道是谁说的句子。
// 全是合成的转写，模型用 StubServer 代替

private func userText(_ body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
}

private func systemText(_ body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
}

final class SpeakerAttributionSummaryTests: XCTestCase {
    /// 别人：0 2 4 6；本人：1 3 7；不知道：5
    private let lines = [
        TimedLine(start: 0, text: "我做的产品是可降解的咖啡袋，我在公司负责华东区的销售。"),
        TimedLine(start: 5, text: "听起来不错，我们店里一直想换环保的包装。"),
        TimedLine(start: 10, text: "现在可降解材料的成本比普通的高大概百分之三十。"),
        TimedLine(start: 15, text: "那我先拿几个样品回去给店长看看。"),
        TimedLine(start: 20, text: "没问题，我下周帮你安排一次二十人以内的试用课。"),
        TimedLine(start: 25, text: "周四下午三点我们在仓库见面。"),
        TimedLine(start: 30, text: "另外展会的报名截止日期是月底，别错过了。"),
        TimedLine(start: 35, text: "好的，我月底前把展会报名表填好交上去。"),
    ]
    private let me: Set<Int> = [1, 3, 7], other: Set<Int> = [0, 2, 4, 6]

    private func summarizer(_ stub: StubServer) -> ConversationSummarizer {
        ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
    }

    func testEveryLineIsTaggedWithItsSpeaker() async throws {
        let stub = try StubServer { _ in #"{"title":"咖啡袋","summary":"聊了咖啡袋。"}"# }
        defer { stub.stop() }
        _ = try await summarizer(stub).summarize(lines, wearer: me, other: other)
        let user = userText(stub.requests[0]).components(separatedBy: "\n").dropFirst()
        XCTAssertEqual(user.map { $0.components(separatedBy: " ")[1] },
                       ["[other]", "[me]", "[other]", "[me]", "[other]", "[?]", "[other]", "[me]"])
        XCTAssertTrue(user.first!.hasSuffix("[other] 我做的产品是可降解的咖啡袋，我在公司负责华东区的销售。"))
        let sys = systemText(stub.requests[0])
        XCTAssertTrue(sys.contains(#""I", "my", "我", "我的" in an [other] line mean that other speaker, never the wearer"#))
        XCTAssertTrue(sys.contains("Never attribute a [?] line to the wearer"))
        XCTAssertTrue(sys.contains("the direction comes from who said the committing line"))
        XCTAssertTrue(sys.contains(#""said_by""#))
    }

    func testKeyPointSpeakersAreCheckedByCode() async throws {
        // 模型把别人的产品和工作说成本人的，把不知道是谁说的那句说成本人的：代码改过来
        let stub = try StubServer { _ in
            #"""
            {"title":"咖啡袋","summary":"聊了咖啡袋。","key_points":[
              {"text":"做可降解咖啡袋，负责华东区销售","said_by":"me"},
              {"text":"可降解材料成本比普通的高约百分之三十","said_by":"other"},
              {"text":"打算带几个样品回去给店长看","said_by":"me"},
              {"text":"对方下周安排二十人以内的试用课","said_by":"?"},
              {"text":"周四下午三点在仓库见面","said_by":"me"}]}
            """#
        }
        defer { stub.stop() }
        let r = try await summarizer(stub).summarize(lines, wearer: me, other: other)
        let s = try XCTUnwrap(r.summary)
        XCTAssertEqual(s.keyPoints.count, 5)
        XCTAssertEqual(s.said, [.other, .other, .me, .other, .unknown])
        XCTAssertEqual(r.unverifiedMine, 2)
    }

    func testAnOfferByTheOtherSideIsNotTheWearersTodo() async throws {
        // 对方说「我下周帮你安排试用课」，模型却记成本人的待办：降成别人的；本人自己答应的那条留着
        let stub = try StubServer { _ in
            #"{"title":"咖啡袋","summary":"聊了咖啡袋。","my_todos":["下周安排二十人以内的试用课","月底前把展会报名表填好交上去"]}"#
        }
        defer { stub.stop() }
        let r = try await summarizer(stub).summarize(lines, wearer: me, other: other)
        let s = try XCTUnwrap(r.summary)
        XCTAssertEqual(s.myTodos, ["月底前把展会报名表填好交上去"])
        XCTAssertEqual(s.otherTodos, ["下周安排二十人以内的试用课"])
        XCTAssertEqual(r.droppedMine, 1)
    }

    func testAttributeRules() {
        let meText = "那我先拿几个样品回去给店长看看。", otherText = "我做的产品是可降解的咖啡袋，我在公司负责华东区的销售。"
        XCTAssertEqual(ConversationSummarizer.attribute("做可降解咖啡袋", claim: "me", me: meText, other: otherText), .other)
        XCTAssertEqual(ConversationSummarizer.attribute("拿样品回去给店长看", claim: "other", me: meText, other: otherText), .unknown)
        XCTAssertEqual(ConversationSummarizer.attribute("拿样品回去给店长看", claim: "me", me: meText, other: otherText), .me)
        // 核不出来：说是本人的算不知道，说是别人的算别人
        XCTAssertEqual(ConversationSummarizer.attribute("天气很好", claim: "me", me: meText, other: otherText), .unknown)
        XCTAssertEqual(ConversationSummarizer.attribute("天气很好", claim: "other", me: meText, other: otherText), .other)
    }

    func testFormatsAndOldFiles() throws {
        // 旧的带标签摘要（format 1，要点没有说话人）算旧的，手动写那天的日记时重写
        let t0 = Date(timeIntervalSince1970: 1_794_550_000)
        let scan = SpeakerScan(at: t0, outcome: .labelled)
        func conv(_ format: Int) -> Conversation {
            Conversation(index: 0, from: 0, to: 2, start: 0, end: 10, wallStart: t0, wallEnd: t0, kind: "conversation",
                         summary: ConversationSummary(title: "t"), summarizedAt: t0,
                         wearer: WearerStats(lines: 2, labelled: 2, wearerLines: 1, share: 0.5, labelsAt: t0, format: format))
        }
        XCTAssertTrue(WearerLabels.summaryIsStale(conv(1), enabled: true, scan: scan))
        XCTAssertFalse(WearerLabels.summaryIsStale(conv(WearerStats.currentFormat), enabled: true, scan: scan))
        let old = try JSONDecoder().decode(WearerStats.self, from: Data(#"{"lines":3,"labelled":3,"wearerLines":1,"share":0.3,"labelsAt":"2026-11-16T09:00:00+08:00"}"#.utf8))
        XCTAssertEqual(old.format, 1)

        let noSaid = try JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"keyPoints":["a","b"]}"#.utf8))
        XCTAssertNil(noSaid.said)
        XCTAssertNil(noSaid.speaker(ofKeyPoint: 0))
        let odd = try JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"keyPoints":["a","b","c"],"said":["me","who?"]}"#.utf8))
        XCTAssertEqual(odd.said, [.me, .unknown, .unknown])
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        XCTAssertFalse(String(decoding: try e.encode(noSaid), as: UTF8.self).contains("said"))
    }
}

final class SpeakerAttributionDiaryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_550_000)
    private let ref = ConversationRef(recording: 1, index: 0)

    private func input(keyPoints: [String], said: [Speaker]?, chars: Int = 900) -> DiaryWriter.Input {
        DiaryWriter.Input(ref: ref, wallStart: t0, wallEnd: t0.addingTimeInterval(600), kind: "conversation",
                          summary: ConversationSummary(title: "咖啡袋", summary: "你做咖啡袋。", keyPoints: keyPoints, mine: [], said: said),
                          chars: chars, wearerShare: 0.4)
    }

    private let points = ["做可降解咖啡袋，负责华东区销售", "可降解材料成本比普通的高约百分之三十", "打算带几个样品回去给店长看",
                          "展会报名月底截止"]
    private let said: [Speaker] = [.other, .other, .me, .other]

    func testKeyPointsAreGroupedBySpeakerAndTheFreeSummaryIsLeftOut() async throws {
        let stub = try StubServer { _ in #"{"overview":"……"}"# }
        defer { stub.stop() }
        _ = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
            .write([input(keyPoints: points, said: said)], languageSample: "今天聊咖啡袋")
        let user = userText(stub.requests[0])
        XCTAssertTrue(user.contains("Said by the wearer:\n- 打算带几个样品回去给店长看"))
        XCTAssertTrue(user.contains("Said by others:\n- 做可降解咖啡袋，负责华东区销售\n- 可降解材料成本比普通的高约百分之三十\n- 展会报名月底截止"))
        XCTAssertFalse(user.contains("Summary:")) // 模型自由写的段摘要（「你做咖啡袋」）不给
        let sys = systemText(stub.requests[0])
        XCTAssertTrue(sys.contains("is never the wearer's own statement, work, product or situation"))
        XCTAssertTrue(sys.contains("about half each"))
    }

    func testAWrongSpeakerHighlightIsDropped() async throws {
        let stub = try StubServer { _ in
            #"""
            {"overview":"……","highlights":[
              {"text":"你做的产品是可降解咖啡袋","said_by":"me","refs":["S1"]},
              {"text":"你负责华东区的销售","said_by":"?","refs":["S1"]},
              {"text":"对方说可降解材料成本比普通的高约三成","said_by":"other","refs":["S1"]},
              {"text":"你打算带样品回去给店长看","said_by":"me","refs":["S1"]},
              {"text":"你被告知展会报名月底截止","said_by":"other","refs":["S1"]}]}
            """#
        }
        defer { stub.stop() }
        let out = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
            .write([input(keyPoints: points, said: said, chars: 30000)], languageSample: "今天聊咖啡袋")
        let d = try XCTUnwrap(out.diary)
        XCTAssertEqual(d.highlights.map(\.text), ["对方说可降解材料成本比普通的高约三成", "你打算带样品回去给店长看", "你被告知展会报名月底截止"])
        XCTAssertEqual(d.highlights.map(\.mine), [false, true, false])
        XCTAssertEqual(out.dropReasons["highlights:wrongSpeaker"], 2)
    }

    func testOldLabelledSummariesWithoutSpeakersStayUnmarked() async throws {
        let stub = try StubServer { _ in #"{"overview":"……","highlights":[{"text":"你做的产品是可降解咖啡袋","said_by":"me","refs":["S1"]}]}"# }
        defer { stub.stop() }
        let out = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
            .write([input(keyPoints: points, said: nil)], languageSample: "今天聊咖啡袋")
        XCTAssertTrue(userText(stub.requests[0]).contains("Key points (speaker not known):"))
        // 出处不知道是谁说的：留下，但不标是谁的
        XCTAssertEqual(out.diary?.highlights.map(\.mine), [nil])
    }

    func testHighlightsAreMixed() {
        let m = (0..<5).map { DiaryItem(text: "m\($0)", refs: [ref], mine: true) }
        let o = (0..<2).map { DiaryItem(text: "o\($0)", refs: [ref], mine: false) }
        XCTAssertEqual(DiaryWriter.mixed(m + o, cap: 4).map(\.text), ["m0", "m1", "o0", "o1"])
        XCTAssertEqual(DiaryWriter.mixed(m + o, cap: 3).map(\.text), ["m0", "m1", "o0"])
        // 只有一种时不动
        XCTAssertEqual(DiaryWriter.mixed(m, cap: 3).count, 5)
        // 别人的少：本人的补上空位
        XCTAssertEqual(DiaryWriter.mixed(m + [o[0]], cap: 5).map(\.text), ["m0", "m1", "m2", "m3", "o0"])
    }

    func testReportedSpeechIsNotTheWearersOwn() {
        XCTAssertTrue(DiaryWriter.addressesWearer("你做的产品是咖啡袋"))
        XCTAssertTrue(DiaryWriter.addressesWearer("Your company makes bags"))
        XCTAssertFalse(DiaryWriter.addressesWearer("你被告知展会月底截止"))
        XCTAssertFalse(DiaryWriter.addressesWearer("You were told the fair closes at the end of the month"))
        XCTAssertFalse(DiaryWriter.addressesWearer("王经理说成本高三成"))
    }

    func testWearerWordIsScrubbedFromReplies() {
        XCTAssertEqual(WearerWord.scrub("介绍一位朋友给wearer做产品测试用户"), "介绍一位朋友给你做产品测试用户")
        XCTAssertEqual(WearerWord.scrub("Send the wearer's notes to Zhang"), "Send you notes to Zhang")
        XCTAssertEqual(WearerWord.scrub("没有这个词"), "没有这个词")
    }
}

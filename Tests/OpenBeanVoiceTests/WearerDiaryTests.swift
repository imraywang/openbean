// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import OpenBeanLibrary
@testable import OpenBeanVoice
import XCTest

// 「认出我的声音」的标签进段摘要和日记（全是合成的转写，模型用 StubServer 代替）

private func userText(_ body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
}

private func systemText(_ body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
}

private func fingerprint(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

/// 加标签这次改动之前的提示词的指纹：没有标签时提示词必须一字不差
private enum Before {
    static let segment = "f076771bcaaa7c6c", part = "b79f17639a5a1f30", merge = "c8e5af121aa92add"
    static let diary = ["d3486259c63d6db3", "81a9c7911ac5569f", "0923c51d1d2d263b", "d3403cbb24a396bb"]
    static let overview = ["e18354f0f27f1dca", "0ad15af789200ba5", "8334bbd802858fcc", "f9efb19cef81f703"]
}

final class WearerSummaryTests: XCTestCase {
    /// 一段对话：1、3 句是佩戴者说的，其余是别人说的
    private let lines = [
        TimedLine(start: 0, text: "张伟：远山咖啡的报价下周要定下来，三万个起订。"),
        TimedLine(start: 5, text: "好的，我周三之前把远山咖啡的报价整理好发给张伟。"),
        TimedLine(start: 10, text: "张伟：设计稿那边李娜会跟进，她下周一给初稿。"),
        TimedLine(start: 15, text: "那我顺便问一下物流的价格，再一起看。"),
        TimedLine(start: 20, text: "张伟：行，那就这么定，周五我们再碰一次。"),
        TimedLine(start: 25, text: "张伟：另外仓库那边的库存也要盘点一下，月底之前。"),
        TimedLine(start: 30, text: "张伟：还有下个月的展会，样品和宣传册都要提前准备，别到时候手忙脚乱。"),
    ]

    private func summarizer(_ stub: StubServer, budget: Int? = nil) -> ConversationSummarizer {
        ConversationSummarizer(budget.map { Summarizer(service: LLMService(endpoint: stub.url), budget: $0, timeout: 10) }
            ?? Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
    }

    func testPromptsWithoutLabelsAreUnchanged() {
        XCTAssertEqual(fingerprint(ConversationSummarizer.segmentPrompt), Before.segment)
        XCTAssertEqual(fingerprint(ConversationSummarizer.partPrompt), Before.part)
        XCTAssertEqual(fingerprint(ConversationSummarizer.mergePrompt), Before.merge)
    }

    func testNoLabelsSendsTheSamePromptAndNoMeTags() async throws {
        let reply = #"{"title":"报价","summary":"讨论了报价。","todos":["周三前发报价"],"people":["张伟"]}"#
        for wearer in [nil, Set<Int>()] {
            let stub = try StubServer { _ in reply }
            defer { stub.stop() }
            let r = try await summarizer(stub).summarize(lines, wearer: wearer)
            let sys = systemText(stub.requests[0])
            XCTAssertTrue(sys.hasPrefix(ConversationSummarizer.segmentPrompt + "\n"))
            XCTAssertEqual(fingerprint(String(sys.prefix(ConversationSummarizer.segmentPrompt.count))), Before.segment)
            XCTAssertFalse(userText(stub.requests[0]).contains(ConversationSummarizer.meTag))
            // 没有标签：不知道是谁的（nil）；有标签但这段一句本人的都没有：带标签写的、没有他的待办（[]）
            XCTAssertEqual(r.summary?.mine, wearer == nil ? nil : [])
            XCTAssertEqual(r.summary?.todos, ["周三前发报价"])
        }
    }

    func testWearerLinesAreTaggedAndThePromptSaysWhoMeIs() async throws {
        let stub = try StubServer { _ in #"{"title":"报价","summary":"你答应发报价。","my_todos":[],"todos":[]}"# }
        defer { stub.stop() }
        _ = try await summarizer(stub).summarize(lines, marked: [3], wearer: [1, 3])
        let user = userText(stub.requests[0]).components(separatedBy: "\n")
        XCTAssertEqual(user.filter { $0.contains("[me] ") }.count, 2)
        XCTAssertTrue(user[2].hasPrefix("[00:05] [me] 好的"))
        XCTAssertFalse(user[1].contains("[me]"))
        // 重点标记照常（标签在前，标记在后）
        XCTAssertTrue(user[4].hasPrefix("[00:15] [me] ") && user[4].hasSuffix(ConversationSummarizer.markNote))
        let sys = systemText(stub.requests[0])
        XCTAssertTrue(sys.contains("Lines that start with [me]"))
        XCTAssertTrue(sys.contains("\"my_todos\""))
        XCTAssertTrue(sys.contains("\"you\"")) // 默认口吻：你
    }

    func testChunkedPathTagsEveryPartAndMergesMyTodos() async throws {
        let stub = try StubServer { body in
            if userText(body).hasPrefix("Part summaries") {
                return #"{"title":"整场","summary":"合并。","my_todos":["周三之前把远山咖啡的报价发给张伟"],"todos":["李娜下周一给设计初稿"]}"#
            }
            return #"{"title":"部分","summary":"一部分。","my_todos":["发报价"],"people":["张伟"]}"#
        }
        defer { stub.stop() }
        let many = (0..<60).map { lines[$0 % lines.count] }.enumerated().map { TimedLine(start: Double($0.offset) * 5, text: $0.element.text) }
        let wearer = Set(many.indices.filter { $0 % lines.count == 1 || $0 % lines.count == 3 })
        let r = try await summarizer(stub, budget: 300).summarize(many, wearer: wearer)
        let parts = stub.requests.filter { userText($0).hasPrefix("Part ") && !userText($0).hasPrefix("Part summaries") }
        XCTAssertGreaterThan(parts.count, 1)
        for p in parts {
            XCTAssertTrue(userText(p).contains("[me] "))
            XCTAssertTrue(systemText(p).contains("Lines that start with [me]"))
        }
        let merges = stub.requests.filter { userText($0).hasPrefix("Part summaries") }
        XCTAssertFalse(merges.isEmpty)
        XCTAssertTrue(userText(merges[0]).contains("Wearer's to-dos:"))
        XCTAssertTrue(systemText(merges[0]).contains("my_todos"))
        let s = try XCTUnwrap(r.summary)
        XCTAssertEqual(s.todos, ["周三之前把远山咖啡的报价发给张伟", "李娜下周一给设计初稿"])
        XCTAssertEqual(s.mine, [0])
    }

    func testMineIsKeptOnlyWhenItMatchesWhatTheWearerSaid() async throws {
        // 第一条和本人那句话对得上；第二条是编的（本人和前后句都没说），留下当别人的待办
        let stub = try StubServer { _ in
            #"{"title":"报价","summary":"定了报价。","my_todos":["周三之前把远山咖啡的报价发给张伟","去火星采购咖啡豆"],"todos":["李娜下周一给设计初稿"]}"#
        }
        defer { stub.stop() }
        let r = try await summarizer(stub).summarize(lines, wearer: [1, 3])
        let s = try XCTUnwrap(r.summary)
        XCTAssertEqual(s.todos, ["周三之前把远山咖啡的报价发给张伟", "去火星采购咖啡豆"]) // 封顶 2 条，他的在前
        XCTAssertEqual(s.mine, [0])
        XCTAssertEqual(s.myTodos, ["周三之前把远山咖啡的报价发给张伟"])
        XCTAssertEqual(r.droppedMine, 1)
    }

    func testOthersAskingTheWearerCountsThroughTheNeighbouringLine() {
        // 别人说「你月底前盘点库存」，本人只回了一句：挨着本人那句的话也算
        XCTAssertTrue(ConversationSummarizer.overlaps("月底之前盘点仓库库存", "张伟：另外仓库那边的库存也要盘点一下，月底之前。\n好"))
        XCTAssertFalse(ConversationSummarizer.overlaps("去火星采购咖啡豆", "好的，我周三之前把远山咖啡的报价整理好发给张伟。"))
        XCTAssertTrue(ConversationSummarizer.overlaps("Send the quote to Zhang", "OK, I'll send the quote by Wednesday"))
        XCTAssertFalse(ConversationSummarizer.overlaps("Book the flight", "we will talk about it then"))
    }

    func testNoWearerLinesMeansNoMineEvenIfTheModelSaysSo() {
        let base = ConversationSummarizer(Summarizer(service: LLMService(endpoint: URL(string: "http://127.0.0.1:1")!), timeout: 1))
        var p = ConversationSummarizer.Parsed()
        p.summary = "s"
        p.myTodos = ["周三之前把远山咖啡的报价发给张伟"]
        let transcript = lines.map(\.text).joined()
        let r = base.finish(p, transcript: transcript, calls: 1, wearerText: "")
        XCTAssertEqual(r.summary?.todos, ["周三之前把远山咖啡的报价发给张伟"])
        XCTAssertEqual(r.summary?.mine, [])
        XCTAssertEqual(r.droppedMine, 1)
        // 没有标签时 my_todos 不存在（提示词里没有这一栏），结果和以前一样
        let old = base.finish(ConversationSummarizer.Parsed(summary: "s", todos: ["a 发报价给张伟"]), transcript: transcript, calls: 1)
        XCTAssertNil(old.summary?.mine)
    }

    /// 本人确实参与的一段：别人交代给他的事不挨着他的话也算他的；只说了一两句时要和他的话对得上
    func testTodoAskedByOthersCountsWhenTheWearerTookPart() {
        let base = ConversationSummarizer(Summarizer(service: LLMService(endpoint: URL(string: "http://127.0.0.1:1")!), timeout: 1))
        var p = ConversationSummarizer.Parsed()
        p.summary = "s"
        p.myTodos = ["月底之前盘点仓库库存", "去火星采购咖啡豆"]
        let transcript = "张伟：另外仓库那边的库存也要盘点一下，月底之前。" + String(repeating: "大家接着聊了很久别的事情。", count: 20)
        let took = base.finish(p, transcript: transcript, calls: 1, wearerText: "好的。\n行。\n嗯我知道了。", wearerLines: 3)
        XCTAssertEqual(took.summary?.mine, [0])
        XCTAssertEqual(took.summary?.todos.first, "月底之前盘点仓库库存")
        XCTAssertEqual(took.droppedMine, 1, "转写里找不到的那条还是不算他的")
        let thin = base.finish(p, transcript: transcript, calls: 1, wearerText: "好的。", wearerLines: 1)
        XCTAssertEqual(thin.summary?.mine, [])
    }

    func testOldFilesDecodeWithoutFlags() throws {
        let seg = #"""
        {"index":0,"from":0,"to":3,"start":0,"end":30,"wallStart":"2026-11-16T09:00:00+08:00","wallEnd":"2026-11-16T09:00:30+08:00",
         "wallApprox":false,"cut":"silence","candidates":[],"hash":"h","marks":[],"kind":"conversation",
         "summary":{"title":"t","summary":"s","keyPoints":[],"decisions":[],"todos":["a","b"],"people":[],"things":[]},
         "summaryModel":"m","summarizedAt":"2026-11-16T10:00:00+08:00"}
        """#
        let c = try JSONDecoder().decode(Conversation.self, from: Data(seg.utf8))
        XCTAssertNil(c.wearer)
        XCTAssertNil(c.summary?.mine)
        XCTAssertEqual(c.summary?.otherTodos, ["a", "b"])
        XCTAssertEqual(c.summary?.myTodos, [])
        // 写回去也没有新字段：签名和以前一样
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        let again = String(decoding: try e.encode(c.summary), as: UTF8.self)
        XCTAssertEqual(again, #"{"decisions":[],"keyPoints":[],"people":[],"summary":"s","things":[],"title":"t","todos":["a","b"]}"#)
        XCTAssertFalse(String(decoding: try e.encode(c), as: UTF8.self).contains("wearer"))

        let item = try JSONDecoder().decode(DiaryItem.self, from: Data(#"{"text":"x","refs":["1#0"]}"#.utf8))
        XCTAssertNil(item.mine)
        XCTAssertEqual(String(decoding: try e.encode(item), as: UTF8.self), #"{"refs":["1#0"],"text":"x"}"#)
        let dc = try JSONDecoder().decode(DayConversation.self, from: Data(#"{"ref":"1#0","wallStart":"2026-11-16T09:00:00+08:00"}"#.utf8))
        XCTAssertNil(dc.wearerShare)

        // 新字段读得回来；mine 里越界的下标丢掉
        let s = try JSONDecoder().decode(ConversationSummary.self, from: Data(#"{"todos":["a","b"],"mine":[1,5]}"#.utf8))
        XCTAssertEqual(s.mine, [1])
        XCTAssertEqual(s.myTodos, ["b"])
    }

    func testWearerStats() {
        let t = Date(timeIntervalSince1970: 0)
        // 4 秒本人、6 秒别人、2 秒不知道
        let s = WearerStats.measure([(0, 4, true), (4, 10, false), (10, 12, nil)], labelsAt: t)
        XCTAssertEqual(s.share, 0.33)
        XCTAssertEqual(s.wearerLines, 1)
        XCTAssertEqual(s.labelled, 2)
        // 判定过的太少、又没有本人的：不知道（不当作没说话）
        XCTAssertNil(WearerStats.measure([(0, 4, false), (4, 6, nil)], labelsAt: t).share)
        XCTAssertEqual(WearerStats.measure([(0, 4, false), (4, 6, false), (6, 9, false)], labelsAt: t).share, 0)
        XCTAssertNil(WearerStats.measure([(0, 4, nil)], labelsAt: t).share)
    }
}

final class WearerLabelsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_550_000)

    private func conv(_ i: Int, summary: Bool = true, labelsAt: Date? = nil) -> Conversation {
        Conversation(index: i, from: i * 2, to: i * 2 + 2, start: 0, end: 10, wallStart: t0, wallEnd: t0, kind: summary ? "conversation" : nil,
                     summary: summary ? ConversationSummary(title: "t") : nil, summarizedAt: summary ? t0 : nil,
                     wearer: labelsAt.map { WearerStats(lines: 2, labelled: 2, wearerLines: 1, share: 0.5, labelsAt: $0) })
    }

    func testOnlySummariesOlderThanTheLabelsAreStale() {
        let scan = SpeakerScan(at: t0.addingTimeInterval(100), outcome: .labelled, voiceprint: "v", wearerLines: 3, lines: 9)
        let convs = [conv(0), // 不带标签写的 → 旧
                     conv(1, labelsAt: t0), // 带的是更早一次扫描的标签 → 旧
                     conv(2, labelsAt: scan.at), // 带的就是这次的 → 不用重写
                     conv(3, summary: false)] // 还没摘要（由平常的补齐来写）
        XCTAssertEqual(convs.filter { WearerLabels.summaryIsStale($0, enabled: true, scan: scan) }.map(\.index), [0, 1])
        // 开关关着、没戴、学习中、没扫过：都不重写
        XCTAssertTrue(convs.allSatisfy { !WearerLabels.summaryIsStale($0, enabled: false, scan: scan) })
        for outcome in [SpeakerScan.Outcome.notWorn, .learning, .noAudio] {
            XCTAssertTrue(convs.allSatisfy { !WearerLabels.summaryIsStale($0, enabled: true, scan: SpeakerScan(at: scan.at, outcome: outcome)) })
        }
        XCTAssertTrue(convs.allSatisfy { !WearerLabels.summaryIsStale($0, enabled: true, scan: nil) })
    }

    func testStatsOnlyWithUsableLabelsAndWithoutVoiceTyping() {
        let segs = [TranscriptSegment(start: 0, end: 4, text: "a", isWearer: true), TranscriptSegment(start: 4, end: 8, text: "b", isWearer: false),
                    TranscriptSegment(start: 8, end: 12, text: "c", isWearer: true)]
        var c = Conversation(index: 0, from: 0, to: 3, start: 0, end: 12, wallStart: t0, wallEnd: t0)
        c.voiceTyping = [2]
        let scan = SpeakerScan(at: t0, outcome: .labelled)
        XCTAssertEqual(WearerLabels.stats(c, segments: segs, enabled: true, scan: scan)?.share, 0.5)
        XCTAssertNil(WearerLabels.stats(c, segments: segs, enabled: true, scan: SpeakerScan(at: t0, outcome: .notWorn)))
        XCTAssertNil(WearerLabels.stats(c, segments: segs, enabled: false, scan: scan))
    }
}

final class WearerDiaryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_550_000)

    private func input(_ i: Int, at minutes: Double, share: Double?, keyPoints: [String] = [], todos: [String] = [],
                       mine: [Int]? = nil, chars: Int = 800) -> DiaryWriter.Input {
        DiaryWriter.Input(ref: ConversationRef(recording: 1, index: i), wallStart: t0.addingTimeInterval(minutes * 60),
                          wallEnd: t0.addingTimeInterval(minutes * 60 + 600), kind: "conversation",
                          summary: ConversationSummary(title: "段\(i)", summary: "摘要\(i)", keyPoints: keyPoints, todos: todos, mine: mine),
                          chars: chars, wearerShare: share)
    }

    private func writer(_ stub: StubServer) -> DiaryWriter {
        DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
    }

    func testPromptsWithoutLabelsAreUnchanged() {
        for l in 0...3 {
            XCTAssertEqual(fingerprint(DiaryWriter.prompt(.init(level: l))), Before.diary[l])
            XCTAssertEqual(fingerprint(DiaryWriter.overviewPrompt(.init(level: l))), Before.overview[l])
        }
    }

    func testUnlabelledDaySendsTheSamePromptAndKeepsTheOldOrder() async throws {
        let stub = try StubServer { _ in
            #"{"overview":"开了会。","highlights":[{"text":"甲","refs":["S1"]},{"text":"乙","refs":["S2"]}],"todos":[{"text":"发报价","refs":["S2"]}]}"#
        }
        defer { stub.stop() }
        let inputs = [input(0, at: 0, share: nil, keyPoints: ["甲"]), input(1, at: 60, share: nil, keyPoints: ["乙"], todos: ["发报价"])]
        let out = try await writer(stub).write(inputs, languageSample: "今天开会")
        let sys = systemText(stub.requests[0])
        let t = DiaryWriter.target(DiaryWriter.usable(inputs))
        XCTAssertTrue(sys.hasPrefix(DiaryWriter.prompt(t) + "\n"))
        XCTAssertFalse(userText(stub.requests[0]).contains("Wearer"))
        XCTAssertFalse(out.labelled)
        let d = try XCTUnwrap(out.diary)
        XCTAssertEqual(d.highlights.map(\.text), ["甲", "乙"])
        XCTAssertNil(d.todos[0].mine)
    }

    func testTodosAreSplitAndMineComeFirst() async throws {
        let stub = try StubServer { _ in
            #"""
            {"overview":"你和张伟定了报价。",
             "my_todos":[{"text":"周三前把报价发给张伟","refs":["S1"]},{"text":"出处没有我的待办","refs":["S2"]}],
             "todos":[{"text":"李娜下周一给初稿","owner":"李娜","refs":["S2"]},{"text":"盘点库存","refs":["S1"]}]}
            """#
        }
        defer { stub.stop() }
        let inputs = [input(0, at: 0, share: 0.4, todos: ["周三前把报价发给张伟", "盘点库存"], mine: [0]),
                      input(1, at: 60, share: 0.1, todos: ["李娜下周一给初稿"], mine: [])]
        let out = try await writer(stub).write(inputs, languageSample: "今天开会")
        XCTAssertTrue(out.labelled)
        let sys = systemText(stub.requests[0]), user = userText(stub.requests[0])
        XCTAssertTrue(sys.contains("\"my_todos\""))
        XCTAssertTrue(sys.contains("\"you\""))
        XCTAssertTrue(user.contains("Wearer: spoke about 40% of the time"))
        XCTAssertTrue(user.contains("Wearer's to-dos:\n- 周三前把报价发给张伟"))
        XCTAssertTrue(user.contains("Other to-dos:\n- 盘点库存"))
        let d = try XCTUnwrap(out.diary)
        XCTAssertEqual(d.todos.map(\.text), ["周三前把报价发给张伟", "出处没有我的待办", "李娜下周一给初稿", "盘点库存"])
        XCTAssertEqual(d.myTodos.map(\.text), ["周三前把报价发给张伟"])
        XCTAssertEqual(Set(d.otherTodos.map(\.text)), ["李娜下周一给初稿", "出处没有我的待办", "盘点库存"])
        XCTAssertTrue(d.todos.allSatisfy { $0.mine != nil })
        XCTAssertEqual(out.droppedMine, 1)
    }

    func testAnOverheardConversationCannotLeadTheHighlights() async throws {
        // 模型把旁听段（本人没说话）的三条要点排在前面；代码把本人说过话的段排前面，旁听段最多留三分之一
        let stub = try StubServer { _ in
            #"""
            {"overview":"……",
             "highlights":[{"text":"邻桌在聊股票","refs":["S1"]},{"text":"邻桌在聊房价","refs":["S1"]},{"text":"邻桌说要去旅游","refs":["S1"]},
                           {"text":"报价定在三万个起订","refs":["S2"]},{"text":"不知道是谁说的那段","refs":["S3"]}]}
            """#
        }
        defer { stub.stop() }
        let inputs = [input(0, at: 0, share: 0, keyPoints: ["股票", "房价", "旅游"]),
                      input(1, at: 60, share: 0.3, keyPoints: ["三万个起订"]),
                      input(2, at: 120, share: nil, keyPoints: ["某事"])]
        let out = try await writer(stub).write(inputs, languageSample: "今天开会")
        let user = userText(stub.requests[0])
        XCTAssertTrue(user.contains("Wearer: did not speak (overheard)"))
        let d = try XCTUnwrap(out.diary)
        XCTAssertEqual(d.highlights.first?.text, "报价定在三万个起订")
        XCTAssertEqual(d.highlights.map(\.text), ["报价定在三万个起订", "不知道是谁说的那段", "邻桌在聊股票"])
        XCTAssertEqual(out.dropReasons["highlights:overheard"], 2)
    }

    func testNeutralVoiceIsOneSwitch() async throws {
        let stub = try StubServer { _ in #"{"overview":"开了会。"}"# }
        defer { stub.stop() }
        let inputs = [input(0, at: 0, share: 0.5, keyPoints: ["甲"])]
        _ = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10), voice: .neutral)
            .write(inputs, languageSample: "今天开会")
        let sys = systemText(stub.requests[0])
        XCTAssertTrue(sys.contains("do not write as \"I\" or \"you\""))
        XCTAssertFalse(sys.contains("Write to the wearer as \"you\""))
        XCTAssertEqual(WearerVoice.labelled, .you)
    }

    func testNoteSplitsTodos() {
        let ref = ConversationRef(recording: 1, index: 0)
        func render(_ todos: [DiaryItem]) -> String {
            let day = DayFile(date: "2026-11-16", timeZone: "Asia/Shanghai", dayStartHour: 4, signature: "s", status: .diary,
                              conversations: [DayConversation(ref: ref, wallStart: t0, wallEnd: t0.addingTimeInterval(60))],
                              diary: Diary(overview: "o", todos: todos), model: nil, createdAt: t0)
            return DiaryNote.render(.init(day: day, recordedSeconds: 60, recordings: [1], timeZone: TimeZone(identifier: "Asia/Shanghai")!,
                                          labels: .init()) { _ in "x.md" })
        }
        let both = render([DiaryItem(text: "我的", refs: [ref], mine: true), DiaryItem(text: "别人的", refs: [ref], mine: false)])
        XCTAssertTrue(both.contains("## My to-dos\n\n- [ ] 我的"))
        XCTAssertTrue(both.contains("## Other people's to-dos\n\n- [ ] 别人的"))
        XCTAssertFalse(both.contains("## To-dos"))
        let onlyMine = render([DiaryItem(text: "我的", refs: [ref], mine: true)])
        XCTAssertFalse(onlyMine.contains("Other people's"))
        let old = render([DiaryItem(text: "旧的", refs: [ref])])
        XCTAssertTrue(old.contains("## To-dos\n\n- [ ] 旧的"))
        XCTAssertFalse(old.contains("My to-dos"))
    }
}

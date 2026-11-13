// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanVoice
import XCTest

private func userText(_ body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
}

private func systemText(_ body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
}

final class ConversationSummarizerTests: XCTestCase {
    private let meeting = (0..<6).map { TimedLine(start: Double($0) * 5, text: "第\($0)句，张伟说下周三之前把远山咖啡的报价发给大家。") }

    func testTooShortIsAFragmentWithoutCallingTheModel() async throws {
        let stub = try StubServer { _ in "{}" }
        defer { stub.stop() }
        let r = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
            .summarize([TimedLine(start: 0, text: "喂？")])
        XCTAssertNil(r.summary)
        XCTAssertEqual(r.kind, "fragment")
        XCTAssertEqual(r.calls, 0)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testNamesMustAppearInTranscriptAndListsAreCapped() async throws {
        let stub = try StubServer { _ in
            #"{"title":"报价","summary":"讨论了报价。","kind":"Conversation","key_points":["a"],"decisions":["周三前发报价"],"todos":["1","2","3","4"],"people":["张伟","李娜","张 伟"],"things":["远山咖啡","星巴克"]}"#
        }
        defer { stub.stop() }
        let r = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)).summarize(meeting)
        let s = try XCTUnwrap(r.summary)
        XCTAssertEqual(s.people, ["张伟", "张 伟"]) // 不合并写法；转写里没有的「李娜」丢掉
        XCTAssertEqual(s.things, ["远山咖啡"])
        XCTAssertEqual(s.todos.count, 2)
        XCTAssertEqual(r.kind, "conversation") // 不认识的大小写写法按默认
        XCTAssertEqual(r.droppedNames, 2)
        XCTAssertEqual(r.calls, 1)
        XCTAssertTrue(systemText(stub.requests[0]).contains("Simplified Chinese"))
    }

    func testLongSegmentIsSummarisedInPartsAndMerged() async throws {
        let stub = try StubServer { body in
            if userText(body).hasPrefix("Part summaries") {
                return #"{"title":"整场","summary":"合并。","kind":"conversation","decisions":["定了"],"todos":["做"],"people":["编的人"],"things":[]}"#
            }
            return #"{"title":"部分","summary":"一部分。","kind":"conversation","people":["张伟"],"things":["远山咖啡"]}"#
        }
        defer { stub.stop() }
        let lines = (0..<120).map { TimedLine(start: Double($0) * 5, text: "第\($0)句，张伟在讲远山咖啡的进度和下一步的安排。") }
        let r = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), budget: 400, timeout: 10))
            .summarize(lines)
        XCTAssertEqual(r.summary?.title, "整场")
        // 人和事来自各部分，合并那一步写的不算
        XCTAssertEqual(r.summary?.people, ["张伟"])
        XCTAssertEqual(r.summary?.things, ["远山咖啡"])
        XCTAssertGreaterThan(r.calls, 2)
    }

    func testUnusableReplyThrowsAfterRetry() async throws {
        let stub = try StubServer { _ in "no json here" }
        defer { stub.stop() }
        do {
            _ = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)).summarize(meeting)
            XCTFail("expected failure")
        } catch Summarizer.Failure.unusable {}
        XCTAssertEqual(stub.requests.count, 2)
    }

    func testMergeOfOneSummaryDoesNotCallTheModel() async throws {
        let stub = try StubServer { _ in "{}" }
        defer { stub.stop() }
        let one = RecordingSummary(title: "t", summary: "s")
        let (m, calls) = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10).merge([one], languageSample: "")
        XCTAssertEqual(m, one)
        XCTAssertEqual(calls, 0)
    }
}

final class DiaryWriterTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_550_000)

    private func input(_ rec: UInt32, _ i: Int, at minutes: Double, kind: String? = "conversation", chars: Int = 400,
                       decisions: [String] = [], todos: [String] = [], people: [String] = []) -> DiaryWriter.Input {
        DiaryWriter.Input(ref: ConversationRef(recording: rec, index: i), wallStart: t0.addingTimeInterval(minutes * 60),
                          wallEnd: t0.addingTimeInterval(minutes * 60 + 600), kind: kind,
                          summary: ConversationSummary(title: "段\(i)", summary: "摘要\(i)", decisions: decisions, todos: todos, people: people),
                          chars: chars)
    }

    func testBriefDayDoesNotCallTheModel() async throws {
        let stub = try StubServer { _ in "{}" }
        defer { stub.stop() }
        let inputs = [input(1, 0, at: 0, chars: 80), input(1, 1, at: 30, kind: "fragment", chars: 900),
                      input(2, 0, at: 90, kind: "media", chars: 5000)]
        XCTAssertTrue(DiaryWriter.isBrief(inputs))
        let out = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)).write(inputs, languageSample: "")
        XCTAssertEqual(out.status, .brief)
        XCTAssertNil(out.diary)
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testItemsWithoutValidSourcesAreDropped() async throws {
        let stub = try StubServer { _ in
            #"""
            {"overview":"上午开了会，下午打了电话。",
             "decisions":[{"text":"报价按三万个算","refs":["S1"]},{"text":"编出来的决定","refs":["S9"]},{"text":"出处没有决定","refs":["S2"]}],
             "todos":[{"text":"周三前发报价","owner":"张伟","refs":"S1, S2"},{"text":"没出处","refs":[]},{"text":"数字出处","owner":"无","refs":[2]}]}
            """#
        }
        defer { stub.stop() }
        let inputs = [input(1, 0, at: 0, decisions: ["按三万个算"], todos: ["发报价"], people: ["张伟"]),
                      input(1, 1, at: 60, todos: ["回电话"], people: ["张伟", "刘经理"]),
                      input(2, 0, at: 300, kind: "media", people: ["主持人"])]
        let out = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
            .write(inputs, languageSample: "今天我们开会")
        let d = try XCTUnwrap(out.diary)
        XCTAssertEqual(out.status, .diary)
        XCTAssertEqual(d.overview, "上午开了会，下午打了电话。")
        XCTAssertEqual(d.decisions.map(\.text), ["报价按三万个算"])
        XCTAssertEqual(d.todos.map(\.text), ["周三前发报价", "数字出处"])
        XCTAssertEqual(d.todos[0].refs, [ConversationRef(recording: 1, index: 0), ConversationRef(recording: 1, index: 1)])
        XCTAssertEqual(d.todos[0].owner, "张伟")
        XCTAssertNil(d.todos[1].owner)
        XCTAssertEqual(out.dropped, 3)
        // 人由代码收集，媒体段里的不算
        XCTAssertEqual(d.people.map(\.name), ["张伟", "刘经理"])
        XCTAssertEqual(d.people[0].refs.count, 2)
        XCTAssertEqual(out.calls, 1)
        // 媒体段没有进提示
        XCTAssertFalse(userText(stub.requests[0]).contains("S3"))
    }

    func testManySegmentsAreGroupedAndOverviewsCombined() async throws {
        let stub = try StubServer { body in
            if systemText(body).hasPrefix("You are given overviews") { return #"{"overview":"全天。"}"# }
            return #"{"overview":"一部分。","decisions":[],"todos":[{"text":"同一条","refs":["S1"]}]}"#
        }
        defer { stub.stop() }
        let inputs = (0..<12).map { input(1, $0, at: Double($0) * 30, todos: ["事"]) }
        let out = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), budget: 200, timeout: 10))
            .write(inputs, languageSample: "")
        XCTAssertEqual(out.diary?.overview, "全天。")
        XCTAssertEqual(out.diary?.todos.count, 1) // 各组写的同一条合并
        XCTAssertGreaterThan(out.calls, 2)
    }

    func testRefLabels() {
        XCTAssertEqual(DiaryWriter.refLabels("S1, s2，S3"), ["S1", "S2", "S3"])
        XCTAssertEqual(DiaryWriter.refLabels([1, "S4"]), ["S1", "S4"])
        XCTAssertEqual(DiaryWriter.refLabels(nil), [])
    }
}

final class DiaryNoteTests: XCTestCase {
    func testRendersSectionsAndLinks() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let t = cal.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 9, minute: 12))!
        let a = ConversationRef(recording: 7, index: 0), b = ConversationRef(recording: 7, index: 1)
        let day = DayFile(date: "2026-11-13", timeZone: "Asia/Shanghai", dayStartHour: 4, signature: "x", status: .diary,
                          conversations: [DayConversation(ref: a, wallStart: t, wallEnd: t.addingTimeInterval(1680), title: "周会", summary: "过了进度。"),
                                          DayConversation(ref: b, wallStart: t.addingTimeInterval(7200), wallEnd: t.addingTimeInterval(7260), kind: "fragment")],
                          diary: Diary(overview: "开了周会。", decisions: [DiaryItem(text: "周五发布", refs: [a])],
                                       todos: [DiaryItem(text: "写文档", owner: "小王", refs: [a])],
                                       people: [DiaryName(name: "小王", refs: [a])]),
                          model: "m", createdAt: t)
        let md = DiaryNote.render(.init(day: day, recordedSeconds: 3700, recordings: [7], timeZone: cal.timeZone) { r in
            r.index == 0 ? DiaryNote.siblingLink("2026-11-13-周会 (1).md") : "openbean://open/\(r.recording)"
        })
        XCTAssertTrue(md.hasPrefix("---\ndate: 2026-11-13\n"))
        XCTAssertTrue(md.contains("recorded: \"1:01:40\""))
        XCTAssertTrue(md.contains("conversations: 1\n")) // 碎片不列
        XCTAssertTrue(md.contains("- 周五发布 ([09:12](../2026-11-13-周会%20%281%29.md))"))
        XCTAssertTrue(md.contains("- [ ] 写文档 — 小王 ([09:12]("))
        XCTAssertTrue(md.contains("- **People**: 小王 ([09:12]("))
        XCTAssertTrue(md.contains("### 09:12–09:40 周会\n\n过了进度。 [Transcript](../"))
        XCTAssertFalse(md.contains("11:12"))
    }

    func testBriefDayListsAllConversations() {
        let t = Date(timeIntervalSince1970: 1_794_550_000)
        let day = DayFile(date: "2026-11-13", timeZone: "UTC", dayStartHour: 4, signature: "x", status: .brief,
                          conversations: [DayConversation(ref: ConversationRef(recording: 1, index: 0), wallStart: t, wallEnd: t,
                                                          wallApprox: true, kind: "fragment")],
                          diary: nil, model: nil, createdAt: t)
        let md = DiaryNote.render(.init(day: day, recordedSeconds: 30, recordings: [1], timeZone: TimeZone(identifier: "UTC")!) { _ in "x" })
        XCTAssertFalse(md.contains("## Overview"))
        XCTAssertTrue(md.contains("### ~"))
    }
}

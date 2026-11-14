// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanVoice
import XCTest

/// 重点标记在送给大模型的文字、日记笔记和逐条笔记里的样子
final class MarkTextTests: XCTestCase {
    private let meeting = (0..<6).map { TimedLine(start: Double($0) * 5, text: "第\($0)句，张伟说下周三之前把远山咖啡的报价发给大家。") }

    func testMarkedLinesAreNotedForTheModel() async throws {
        let stub = try StubServer { _ in #"{"title":"报价","summary":"讨论了报价。","kind":"conversation"}"# }
        defer { stub.stop() }
        let s = ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10))
        _ = try await s.summarize(meeting, marked: [2])
        let body = try XCTUnwrap(stub.requests.first)
        let msgs = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let user = msgs.last?["content"] as? String ?? ""
        let system = msgs.first?["content"] as? String ?? ""
        XCTAssertTrue(user.contains("第2句，张伟说下周三之前把远山咖啡的报价发给大家。 " + ConversationSummarizer.markNote), user)
        XCTAssertEqual(user.components(separatedBy: ConversationSummarizer.markNote).count, 2) // 只有一处
        XCTAssertTrue(system.contains(ConversationSummarizer.markNote))
        // 没有标记：转写里不出现
        _ = try await s.summarize(meeting)
        XCTAssertFalse((((stub.requests.last?["messages"] as? [[String: Any]])?.last?["content"]) as? String ?? "").contains("MARKED"))
    }

    func testDiaryInputMentionsMarks() {
        let t0 = Date(timeIntervalSince1970: 1_794_500_000)
        let w = DiaryWriter(Summarizer(service: LLMService(endpoint: URL(string: "http://127.0.0.1:9")!)), timeZone: TimeZone(identifier: "UTC")!)
        func input(marks: [String]) -> DiaryWriter.Input {
            DiaryWriter.Input(ref: ConversationRef(recording: 1, index: 0), wallStart: t0, wallEnd: t0.addingTimeInterval(60),
                              kind: "conversation", summary: ConversationSummary(title: "报价", summary: "讨论了报价。"), chars: 600,
                              marks: marks)
        }
        let marked = w.render(input(marks: ["先说报价。 报价按三万个算。"]), label: "S1")
        XCTAssertTrue(marked.contains("Marked by the user as important:\n- \"先说报价。 报价按三万个算。\""), marked)
        XCTAssertFalse(w.render(input(marks: []), label: "S1").contains("Marked"))
        XCTAssertTrue(DiaryWriter.prompt.contains("Marked by the user"))
    }

    private func day(marks: [DiaryMark]) -> DayFile {
        let t = Date(timeIntervalSince1970: 1_794_560_400) // 2026-11-13 09:00 UTC
        let a = ConversationRef(recording: 7, index: 0)
        return DayFile(date: "2026-11-13", timeZone: "UTC", dayStartHour: 4, signature: "x", status: .brief,
                       conversations: [DayConversation(ref: a, wallStart: t, wallEnd: t.addingTimeInterval(1800), title: "周会")],
                       diary: nil, model: nil, createdAt: t, marks: marks)
    }

    func testDiaryNoteHasMarksSectionOnlyWhenThereAreMarks() {
        let t = Date(timeIntervalSince1970: 1_794_560_400)
        let m = DiaryMark(ref: ConversationRef(recording: 7, index: 0), at: 125, wall: t.addingTimeInterval(125),
                          quote: ["我们开始吧。", "先说报价。", "报价按三万个算。"])
        let utc = TimeZone(identifier: "UTC")!
        var labels = DiaryNote.Labels()
        labels.marks = "标记"
        let md = DiaryNote.render(.init(day: day(marks: [m]), recordedSeconds: 1800, recordings: [7], timeZone: utc, labels: labels) { _ in "../note.md" })
        XCTAssertTrue(md.contains("\n## 标记\n\n- **09:02** · [09:00–09:30 周会](../note.md)\n  > 我们开始吧。 先说报价。 报价按三万个算。\n"), md)
        // 内容太少的日子（没有概述）也有标记这一节
        XCTAssertFalse(md.contains("## Overview"))
        let none = DiaryNote.render(.init(day: day(marks: []), recordedSeconds: 1800, recordings: [7], timeZone: utc, labels: labels) { _ in "x" })
        XCTAssertFalse(none.contains("## 标记"))
    }

    func testNoteTranscriptFlagsMarkedLines() {
        let v = NoteTemplate.Values(title: "周会", start: Date(timeIntervalSince1970: 1_794_467_493), duration: 93.6, recordingID: 1,
                                    summary: nil, lines: [TimedLine(start: 0, text: "大家好。"), TimedLine(start: 65.4, text: "下周五发布。")],
                                    timeZone: TimeZone(identifier: "UTC")!, marks: [1: [64.2]])
        let md = NoteTemplate.render("{{transcript}}", v)
        XCTAssertEqual(md, "[00:00] 大家好。\n\n[01:05] ⚑ [01:04] 下周五发布。")
    }
}

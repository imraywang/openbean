// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class SummarizerTests: XCTestCase {
    // MARK: 分块

    func testTokenEstimateIsConservativeForChinese() {
        XCTAssertEqual(Summarizer.estimateTokens("今天开会"), 6)
        XCTAssertEqual(Summarizer.estimateTokens("hello world!"), 4)
        XCTAssertEqual(Summarizer.estimateTokens(""), 0)
    }

    func testChunksStayUnderBudget() {
        let lines = (0..<300).map { TimedLine(start: Double($0) * 4, text: "第\($0)句：我们讨论了下个季度的发布计划和预算安排。") }
        let budget = 500
        let chunks = Summarizer.chunk(lines, budget: budget)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            let cost = c.reduce(0) { $0 + Summarizer.estimateTokens(Summarizer.line($1)) + 1 }
            XCTAssertLessThanOrEqual(cost, budget)
        }
        // 不丢句、不打乱顺序
        XCTAssertEqual(chunks.flatMap { $0 }, lines)
    }

    func testOneChunkWhenShort() {
        let lines = [TimedLine(start: 0, text: "Short note."), TimedLine(start: 3, text: "  "), TimedLine(start: 5, text: "Buy milk.")]
        let chunks = Summarizer.chunk(lines, budget: 1800)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].map(\.text), ["Short note.", "Buy milk."])
        XCTAssertTrue(Summarizer.chunk([], budget: 100).isEmpty)
    }

    func testOverlongSentenceIsSplit() {
        let long = String(repeating: "这是一段没有停顿的很长的话", count: 60)
        let chunks = Summarizer.chunk([TimedLine(start: 12, text: long)], budget: 200)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.map { $0[0].text }.joined(), long)
        for c in chunks { XCTAssertLessThanOrEqual(Summarizer.estimateTokens(Summarizer.line(c[0])) + 1, 200) }
    }

    func testMergeGroupsShrinkEveryRound() {
        let parts = (0..<9).map { RecordingSummary(title: "Part \($0)", summary: String(repeating: "内容", count: 200)) }
        let groups = Summarizer.group(parts, budget: 300)
        XCTAssertLessThan(groups.count, parts.count)
        XCTAssertTrue(groups.allSatisfy { $0.count >= 2 })
        XCTAssertEqual(groups.flatMap { $0 }.map(\.title), parts.map(\.title))
    }

    func testLanguageLine() {
        XCTAssertTrue(Summarizer.languageLine(for: "我们明天下午三点开会").contains("Chinese"))
        XCTAssertTrue(Summarizer.languageLine(for: "We meet tomorrow at three").contains("same language"))
    }

    // MARK: 解析

    func testParsePlainJSON() {
        let s = Summarizer.parse(#"{"title":"周会","summary":"讨论了发布。","key_points":["周五发布"],"action_items":["小王写文档"]}"#)
        XCTAssertEqual(s, RecordingSummary(title: "周会", summary: "讨论了发布。", keyPoints: ["周五发布"], actionItems: ["小王写文档"]))
    }

    func testParseThinkBlockAndFence() {
        let raw = """
        <think>
        The user wants JSON. {"title": "wrong"}
        </think>
        Here you go:
        ```json
        {"title": "\\"Weekly sync\\"", "summary": "We planned the launch.", "key_points": ["- Launch Friday", "None"], "action_items": []}
        ```
        """
        let s = Summarizer.parse(raw)
        XCTAssertEqual(s?.title, "Weekly sync")
        XCTAssertEqual(s?.summary, "We planned the launch.")
        XCTAssertEqual(s?.keyPoints, ["Launch Friday"])
        XCTAssertEqual(s?.actionItems, [])
    }

    func testParseObjectActionItems() {
        let s = Summarizer.parse(#"{"title":"t","summary":"s","action_items":[{"task":"Send deck","owner":"Ana"}, "无"]}"#)
        XCTAssertEqual(s?.actionItems, ["Send deck (Ana)"])
        XCTAssertEqual(s?.keyPoints, [])
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(Summarizer.parse("Sorry, I can't help with that."))
        XCTAssertNil(Summarizer.parse("<think>still thinking about the answer and ran out of tok"))
        XCTAssertNil(Summarizer.parse(#"{"title": "x", "summary": ""}"#))
        XCTAssertNil(Summarizer.parse(#"{"title": "...", "summary": "..."}"#))
        XCTAssertNil(Summarizer.parse(#"{"title": "x", "summary": "unterminated"#))
        XCTAssertNil(Summarizer.parse(""))
    }

    // MARK: 和模拟服务对话

    func testSummarizeAgainstStubServer() async throws {
        let stub = try StubServer { body in
            let user = ((body["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
            if user.hasPrefix("Partial summaries") {
                return #"<think>merge</think>{"title":"Long meeting","summary":"All parts.","key_points":["a","b"],"action_items":["c"]}"#
            }
            return "```json\n{\"title\":\"part\",\"summary\":\"One part.\",\"key_points\":[\"p\"],\"action_items\":[]}\n```"
        }
        defer { stub.stop() }
        let lines = (0..<120).map { TimedLine(start: Double($0) * 5, text: "第\($0)句，关于项目进度和下一步的安排。") }
        let service = LLMService(endpoint: stub.url)
        let progress = Locked<[Double]>([])
        let s = try await Summarizer(service: service, budget: 400, timeout: 10)
            .summarize(lines) { p in progress.mutate { $0.append(p) } }
        XCTAssertEqual(s.title, "Long meeting")
        XCTAssertEqual(s.actionItems, ["c"])
        let calls = stub.requests
        XCTAssertGreaterThan(calls.count, 2)
        // 本机服务会关掉思考模式
        XCTAssertNotNil(calls.first?["chat_template_kwargs"])
        XCTAssertEqual(progress.value.last, 1)
    }

    func testSummarizeFailsOnUnusableReply() async throws {
        let stub = try StubServer { _ in "I think this recording is about cats." }
        defer { stub.stop() }
        do {
            _ = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)
                .summarize([TimedLine(start: 0, text: String(repeating: "今天我们聊一聊猫的事情。", count: 5))])
            XCTFail("expected failure")
        } catch Summarizer.Failure.unusable {
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(stub.requests.count, 2) // 重试过一次
    }
}

final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let l = NSLock()
    init(_ v: T) { self.v = v }
    var value: T { l.lock(); defer { l.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { l.lock(); f(&v); l.unlock() }

    func testChineseScriptIsNamed() {
        XCTAssertTrue(Summarizer.languageLine(for: "我们这个会开得还不错，问题都记录了").contains("Simplified"))
        XCTAssertTrue(Summarizer.languageLine(for: "我們這個會開得還不錯，問題都記錄了").contains("Traditional"))
    }

    func testCapAfterMerge() {
        let s = Summarizer.capped(RecordingSummary(title: "t", summary: "s", keyPoints: (0..<20).map { "k\($0)" },
                                                   actionItems: (0..<45).map { "a\($0)" }))
        XCTAssertEqual(s.keyPoints.count, 8)
        XCTAssertEqual(s.actionItems.count, 10)
        XCTAssertEqual(s.actionItems.first, "a0")
    }

    func testTooShortTranscriptIsNotSummarised() async {
        // 不该发任何请求：地址指向没人监听的端口，若发了请求会得到网络错误而不是 tooShort
        let s = Summarizer(service: LLMService(endpoint: URL(string: "http://127.0.0.1:9")!, model: "x"))
        do {
            _ = try await s.summarize([TimedLine(start: 0, text: "嗯，后面。")])
            XCTFail("expected tooShort")
        } catch Summarizer.Failure.tooShort {
        } catch { XCTFail("unexpected \(error)") }
    }

    func testEmptyOwnerSuffixIsDropped() {
        let s = Summarizer.parse(#"{"title":"t","summary":"s","action_items":["发报告给张经理 [无]","订会议室 (None)","周五前交稿 [李雷]"]}"#)
        XCTAssertEqual(s?.actionItems, ["发报告给张经理", "订会议室", "周五前交稿 [李雷]"])
    }

    func testGlossaryReachesPromptAndOutput() async throws {
        let stub = try StubServer { _ in #"{"title":"cloud code 用法","summary":"讲了 cloud code 的用法。","key_points":["comit 之前先测试"]}"# }
        defer { stub.stop() }
        let s = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10,
                                     glossary: ["Claude Code = cloud code", "commit = comit"])
            .summarize([TimedLine(start: 0, text: String(repeating: "今天讲一下 cloud code 怎么用，comit 之前要先测试。", count: 3))])
        XCTAssertEqual(s.title, "Claude Code 用法")
        XCTAssertEqual(s.keyPoints, ["commit 之前先测试"])
        XCTAssertTrue(Summarizer.termsLine(["Claude Code = cloud code", "录音豆"]).contains("Claude Code, 录音豆"))
        XCTAssertEqual(Summarizer.termsLine([]), "")
    }
}

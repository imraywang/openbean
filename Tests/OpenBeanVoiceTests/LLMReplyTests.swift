// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

/// 复现真机上长对话段摘要写不出来：模拟一个默认开思考的云端模型（像 deepseek-flash）——
/// 推理的 token 和输入长度成正比，而且算在 max_tokens 里；顶到上限时正文被截断或干脆是空的，finish_reason = length。
private enum ThinkingModel {
    static let conversation = #"{"title":"选址和预算","summary":"讨论了新店选址、第三季度预算和远山咖啡的报价，选址定在大学城。","kind":"conversation","key_points":["大学城铺子五十五平，月租一万四","第三季度预算一百二十万","远山咖啡报价每公斤一百一十八"],"decisions":["新店选址定在大学城"],"todos":["王磊下周五之前把租赁合同发给法务"],"people":["王磊","李娜","张伟"],"things":["远山咖啡"]}"#

    /// - thinking：模型会不会先推理（请求里带了关思考的参数就不推理）
    static func reply(_ req: [String: Any], answer: String = conversation, reasoningPerChar: Double = 1.0 / 3) -> [String: Any] {
        let maxT = (req["max_tokens"] as? Int) ?? (req["max_completion_tokens"] as? Int) ?? 8000
        let user = ((req["messages"] as? [[String: Any]])?.last?["content"] as? String) ?? ""
        let thinkingOff = (req["thinking"] as? [String: Any])?["type"] as? String == "disabled"
        let reasoning = thinkingOff ? 0 : Int(Double(user.count) * reasoningPerChar)
        var msg: [String: Any] = ["role": "assistant"]
        let finish: String
        let used: Int
        if reasoning >= maxT {
            msg["content"] = ""
            finish = "length"
            used = maxT
        } else if reasoning + answer.count > maxT {
            msg["content"] = String(answer.prefix(maxT - reasoning))
            finish = "length"
            used = maxT
        } else {
            msg["content"] = answer
            finish = "stop"
            used = reasoning + answer.count
        }
        if reasoning > 0 { msg["reasoning_content"] = String(repeating: "想", count: min(reasoning, 200)) }
        return ["choices": [["message": msg, "finish_reason": finish]],
                "usage": ["completion_tokens": used, "completion_tokens_details": ["reasoning_tokens": min(reasoning, maxT)]]]
    }
}

/// 编的长会议转写（一段对话，约 9000 字）
private func longConversation(lines: Int = 300) -> [TimedLine] {
    let said = ["上周我和王磊去看了大学城南门的铺子，五十五平，月租一万四。", "李娜说开学季的活动预算只有二十五万，有点紧。",
                "张伟下周三之前把远山咖啡的还价发过去，按每个月八百公斤谈。", "滨江路那个铺子人流主要在周末，工作日比较冷清。"]
    return (0..<lines).map { TimedLine(start: Double($0) * 7, text: "第\($0)句，" + said[$0 % said.count]) }
}

private final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }
}

final class LLMReplyTests: XCTestCase {
    private var log = LogBox()

    override func setUp() {
        log = LogBox()
        let box = log
        LLMLog.sink = { box.add($0) }
    }

    override func tearDown() { LLMLog.sink = nil }

    /// 推理占满 1000 的输出上限：以前直接「回复不能用」；现在记下元数据，把上限加大再问，写出来
    func testReasoningThatEatsTheOutputLimitIsRetriedWithMoreRoom() async throws {
        let stub = try StubServer(full: { ThinkingModel.reply($0) })
        defer { stub.stop() }
        let s = Summarizer(service: LLMService(endpoint: stub.url), budget: 24_000, timeout: 10)
        let r = try await ConversationSummarizer(s).summarize(longConversation())
        XCTAssertEqual(r.summary?.title, "选址和预算")
        let limits = stub.requests.compactMap { $0["max_tokens"] as? Int }
        XCTAssertEqual(limits.first, 1000, "第一次和以前一样")
        // 这段转写约 1.2 万字，推理约 4000 token：1000 → 4000（翻四倍，仍被推理占满）→ 8000（到顶）写出来
        XCTAssertEqual(limits, [1000, 4000, 8000], "有推理时上限翻四倍，最多 8000")
        XCTAssertEqual(r.calls, 3)
        // 日志：只有元数据，没有正文和转写
        let line = try XCTUnwrap(log.all.first { $0.hasPrefix("大模型回复不能用（段摘要") })
        XCTAssertTrue(line.contains("finish_reason=length"), line)
        XCTAssertTrue(line.contains("正文 0 字"), line)
        XCTAssertTrue(line.contains("推理 200 字"), line)
        XCTAssertTrue(line.contains("上限 1000"), line)
        XCTAssertTrue(line.contains("问题：truncated"), line)
        XCTAssertFalse(log.all.joined().contains("王磊"), "日志里不能有转写或回复的内容")
    }

    /// 关掉思考的方言（DeepSeek 预置服务）：一次就写出来
    func testDeepSeekDialectTurnsThinkingOff() async throws {
        let stub = try StubServer(full: { ThinkingModel.reply($0) })
        defer { stub.stop() }
        var svc = LLMService(endpoint: stub.url)
        svc.dialect = .deepseek
        let r = try await ConversationSummarizer(Summarizer(service: svc, budget: 24_000, timeout: 10)).summarize(longConversation())
        XCTAssertEqual(r.calls, 1)
        let body = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual((body["thinking"] as? [String: Any])?["type"] as? String, "disabled")
        XCTAssertEqual(body["max_tokens"] as? Int, 1000)
    }

    /// 手填 DeepSeek 的地址（Mac 的用法）也按 DeepSeek 的方言发；别家和本机服务不变
    func testDialectIsInferredFromTheEndpoint() throws {
        func dialect(_ s: String) throws -> LLMService.Dialect { LLMService(endpoint: try XCTUnwrap(URL(string: s))).dialect }
        XCTAssertEqual(try dialect("https://api.deepseek.com"), .deepseek)
        XCTAssertEqual(try dialect("https://API.DeepSeek.com/v1"), .deepseek)
        XCTAssertEqual(try dialect("https://api.openai.com/v1"), .standard)
        XCTAssertEqual(try dialect("https://openrouter.ai/api/v1"), .standard)
        XCTAssertEqual(try dialect("http://127.0.0.1:8092"), .standard)
        XCTAssertEqual(try dialect("https://notdeepseek.com"), .standard)
    }

    /// 没推理、只是 JSON 写到一半被截断：上限翻倍再问
    func testTruncatedJSONIsRetriedWithDoubleTheLimit() async throws {
        let long = #"{"title":"会议","summary":""# + String(repeating: "讨论了很多事情。", count: 160) + #"","key_points":[],"action_items":[]}"#
        let stub = try StubServer(full: { ThinkingModel.reply($0, answer: long, reasoningPerChar: 0) })
        defer { stub.stop() }
        let out = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10).summarize(longConversation(lines: 30))
        XCTAssertEqual(out.title, "会议")
        XCTAssertEqual(stub.requests.compactMap { $0["max_tokens"] as? Int }, [1000, 2000])
    }

    /// 上限加到顶还被截断：把半截 JSON 补齐用掉（标题和摘要已经写出来了）
    func testTruncatedAtTheCapIsRepairedWhenPossible() async throws {
        let stub = try StubServer(full: { req in
            let maxT = req["max_tokens"] as? Int ?? 0
            let text = #"{"title":"会议","summary":"讨论了选址。","key_points":["大学城","预算一百二"# // 永远写到这里就断
            return ["choices": [["message": ["content": text], "finish_reason": "length"]],
                    "usage": ["completion_tokens": maxT]]
        })
        defer { stub.stop() }
        let out = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10).summarize(longConversation(lines: 30))
        XCTAssertEqual(out.summary, "讨论了选址。")
        XCTAssertEqual(out.keyPoints, ["大学城", "预算一百二"])
        XCTAssertEqual(stub.requests.compactMap { $0["max_tokens"] as? Int }, [1000, 2000, 4000, 8000], "最多加到 8000")
        XCTAssertTrue(log.all.contains { $0.contains("补齐半截 JSON") })
    }

    /// 截断得什么都补不出来：抛 outputTruncated，缩小分块整体重来，最后放弃（次数有上限）
    func testHopelessTruncationGivesUpAfterABoundedNumberOfCalls() async throws {
        let stub = try StubServer(full: { _ in
            ["choices": [["message": ["content": "", "reasoning_content": "想"], "finish_reason": "length"]]]
        })
        defer { stub.stop() }
        do {
            _ = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), budget: 2000, timeout: 10))
                .summarize(longConversation(lines: 40))
            XCTFail("应该放弃")
        } catch {
            XCTAssertEqual(error as? LLMBackendError, .outputTruncated)
        }
        XCTAssertLessThan(stub.requests.count, 40, "请求次数有上限")
    }

    /// 模型在 JSON 外加了说明、代码块，结尾多了逗号：第一次就能用，不再重问
    func testWrappedReplyIsParsedLeniently() async throws {
        let wrapped = "好的，以下是摘要：\n```json\n" + #"{"title":"会议","summary":"讨论了预算。","key_points":["预算",],"action_items":[],}"#
            + "\n```\n希望对你有帮助 {如有需要请告诉我}"
        let stub = try StubServer { _ in wrapped }
        defer { stub.stop() }
        let out = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10).summarize(longConversation(lines: 30))
        XCTAssertEqual(out.keyPoints, ["预算"])
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertNotNil(JSONReply.object(wrapped))
    }

    /// 回复里没有 JSON：和以前一样再问一次就放弃
    func testNonJSONReplyIsAskedOnceMore() async throws {
        let stub = try StubServer { _ in "抱歉，我无法总结这段内容。" }
        defer { stub.stop() }
        do {
            _ = try await Summarizer(service: LLMService(endpoint: stub.url), timeout: 10).summarize(longConversation(lines: 30))
            XCTFail()
        } catch Summarizer.Failure.unusable {}
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertTrue(log.all.contains { $0.contains("问题：noJSON") })
    }

    func testRepairTruncated() {
        func obj(_ s: String) -> [String: Any]? {
            JSONReply.repairTruncated(s).flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        }
        XCTAssertEqual(obj(#"{"a":"xy"#)?["a"] as? String, "xy")
        XCTAssertEqual(obj(#"{"a":"x","b":["p","q"#)?["b"] as? [String], ["p", "q"])
        XCTAssertEqual(obj(#"{"a":"x","b":["p","#)?["b"] as? [String], ["p"])
        XCTAssertEqual(obj(#"{"a":"x","b"#)?.keys.sorted(), ["a"], "写了一半的键丢掉")
        XCTAssertEqual(obj(#"{"a":"x","b":"#)?.keys.sorted(), ["a"], "没有值的键丢掉")
        XCTAssertEqual(obj(#"{"a":1,"b":[{"t":"x","r":["S1"#)?["a"] as? Int, 1)
        XCTAssertEqual(obj(#"{"a":"转义\"引号"#)?["a"] as? String, "转义\"引号")
        XCTAssertNil(JSONReply.repairTruncated("没有 JSON"))
    }

    func testReplyMetadataParsing() throws {
        let d = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": NSNull(), "reasoning_content": "想一想"], "finish_reason": "length"]],
            "usage": ["completion_tokens": 1000, "completion_tokens_details": ["reasoning_tokens": 1000]],
        ])
        let r = try XCTUnwrap(LLMService.reply(d, maxTokens: 1000))
        XCTAssertEqual(r.text, "")
        XCTAssertTrue(r.truncated)
        XCTAssertTrue(r.reasoned)
        XCTAssertEqual(r.reasoningTokens, 1000)
        XCTAssertEqual(ReplyProblem.diagnose(r), .truncated)
        XCTAssertEqual(ReplyProblem.diagnose(LLMReply(text: "", finishReason: "stop")), .empty)
        XCTAssertEqual(ReplyProblem.diagnose(LLMReply(text: #"{"x":1}"#, finishReason: "stop")), .missingFields)
        XCTAssertEqual(ReplyProblem.diagnose(LLMReply(text: #"{"x":"#, finishReason: "stop")), .badJSON)
        // content 为 null 又没有推理：和以前一样算坏回复
        let bad = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": NSNull()]]]])
        XCTAssertNil(LLMService.reply(bad, maxTokens: 10))
    }

    func testDialectsOnlyTouchTheirOwnParameters() {
        var std: [String: Any] = ["max_tokens": 1000, "temperature": 0.2]
        LLMService.Dialect.standard.apply(&std)
        XCTAssertEqual(std.keys.sorted(), ["max_tokens", "temperature"], "Mac 和自定义地址：请求不变")
        var ds: [String: Any] = ["max_tokens": 1000]
        LLMService.Dialect.deepseek.apply(&ds)
        XCTAssertEqual((ds["thinking"] as? [String: String])?["type"], "disabled")
        var oa: [String: Any] = ["max_tokens": 1000]
        LLMService.Dialect.openai.apply(&oa)
        XCTAssertNil(oa["max_tokens"])
        XCTAssertEqual(oa["max_completion_tokens"] as? Int, 1000)
        XCTAssertEqual(oa["reasoning_effort"] as? String, "none")
        XCTAssertEqual(CloudPreset.deepseek.dialect, .deepseek)
        XCTAssertEqual(CloudPreset.openai.dialect, .openai)
        XCTAssertEqual(CloudPreset.openrouter.dialect, .standard)
    }
}

final class RetryLedgerTests: XCTestCase {
    func testBackoffThenGiveUp() {
        var l = RetryLedger()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(l.state("day:1", signature: "a", now: t0), .allowed)
        l.failed("day:1", signature: "a", reason: "truncated", now: t0)
        XCTAssertEqual(l.state("day:1", signature: "a", now: t0.addingTimeInterval(60)),
                       .waiting(until: t0.addingTimeInterval(600), failures: 1, reason: "truncated"))
        XCTAssertEqual(l.state("day:1", signature: "a", now: t0.addingTimeInterval(601)), .allowed)
        let t1 = t0.addingTimeInterval(700)
        l.failed("day:1", signature: "a", reason: "unusable", now: t1)
        XCTAssertEqual(l.state("day:1", signature: "a", now: t1.addingTimeInterval(1800)),
                       .waiting(until: t1.addingTimeInterval(3600), failures: 2, reason: "unusable"))
        let t2 = t1.addingTimeInterval(3700)
        l.failed("day:1", signature: "a", reason: "unusable", now: t2)
        XCTAssertEqual(l.state("day:1", signature: "a", now: t2.addingTimeInterval(86_400)), .gaveUp(failures: 3, reason: "unusable"))
        // 内容变了重新计数；手动重试清掉
        XCTAssertEqual(l.state("day:1", signature: "b", now: t2), .allowed)
        l.reset("day:1")
        XCTAssertEqual(l.state("day:1", signature: "a", now: t2), .allowed)
    }

    func testFailureOnNewContentStartsOver() {
        var l = RetryLedger()
        let t = Date()
        l.failed("seg:1#0", signature: "a", reason: "unusable", now: t)
        l.failed("seg:1#0", signature: "a", reason: "unusable", now: t)
        l.failed("seg:1#0", signature: "b", reason: "unusable", now: t)
        XCTAssertEqual(l.entries["seg:1#0"]?.failures, 1)
        l.succeeded("seg:1#0")
        XCTAssertNil(l.entries["seg:1#0"])
    }

    func testOnlyModelReplyFailuresCount() {
        XCTAssertTrue(RetryLedger.counts(Summarizer.Failure.unusable))
        XCTAssertTrue(RetryLedger.counts(LLMBackendError.outputTruncated))
        XCTAssertFalse(RetryLedger.counts(URLError(.timedOut)), "服务不通不算（没花钱，下次同步照常试）")
        XCTAssertFalse(RetryLedger.counts(LLMService.Failure.http(500)))
        XCTAssertEqual(RetryLedger.reason(LLMBackendError.outputTruncated), "truncated")
    }

    func testCodableRoundTrip() throws {
        var l = RetryLedger()
        l.failed("day:2026-11-12", signature: "s", reason: "unusable", now: Date(timeIntervalSince1970: 5))
        let back = try JSONDecoder().decode(RetryLedger.self, from: JSONEncoder().encode(l))
        XCTAssertEqual(back, l)
    }
}

// SPDX-License-Identifier: Apache-2.0

#if canImport(FoundationModels)
import FoundationModels
#endif
@testable import OpenBeanVoice
import XCTest

/// 假后端：按端侧模型的限制模拟（上下文窗口、结构化输出），记录每次请求
private final class FakeBackend: LLMBackend, @unchecked Sendable {
    let context: Int
    let lock = NSLock()
    private(set) var requests: [LLMRequest] = []
    var reply: (LLMRequest) -> String

    init(context: Int = 4096, reply: @escaping (LLMRequest) -> String) {
        self.context = context
        self.reply = reply
    }

    var modelName: String { "fake" }
    var sendsTextOffDevice: Bool { false }
    var defaultTimeout: TimeInterval { 10 }
    var promptOverhead: Int { 350 }
    var preferredMaxOutput: Int? { 700 }
    var tokenEstimateSlack: Double { 1.3 }
    func check() async -> LLMService.Status { .ok }
    func contextLength() async -> Int? { context }
    func open(timeout: TimeInterval) -> any LLMChannel { Channel(owner: self) }

    /// 真实的端侧模型按自己的分词器算；这里按「中文一字一 token、其余 4 字符一 token」（苹果文档的说法）
    static func tokens(_ s: String) -> Int {
        var wide = 0, other = 0
        for u in s.unicodeScalars { if u.value >= 0x2E80 { wide += 1 } else { other += 1 } }
        return wide + other / 4
    }

    struct Channel: LLMChannel {
        let owner: FakeBackend
        func complete(_ r: LLMRequest) async throws -> String {
            owner.lock.lock()
            owner.requests.append(r)
            owner.lock.unlock()
            // 提示词 + 转写 + 格式说明 + 输出上限 超过窗口就和真的一样报错
            if Self.cost(r, overhead: owner.promptOverhead) > owner.context { throw LLMBackendError.contextExceeded }
            return owner.reply(r)
        }
        static func cost(_ r: LLMRequest, overhead: Int) -> Int {
            FakeBackend.tokens(r.system) + FakeBackend.tokens(r.user) + overhead + r.maxTokens
        }
    }
}

private func meeting(minutes: Int) -> [TimedLine] {
    // 每分钟大约 250 字的中文会议（转写一句 30 字上下，八句一分钟；正常语速每分钟两三百字）
    let topics = ["远山咖啡的报价", "第三季度的预算", "新门店的选址", "供应商的交货时间", "下个月的促销活动"]
    var out: [TimedLine] = []
    for i in 0..<(minutes * 8) {
        let t = topics[i / 30 % topics.count]
        out.append(TimedLine(start: Double(i) * 6, text: "第\(i)句：张伟说关于\(t)，我们下周三之前要定下来，李娜负责跟进。"))
    }
    return out
}

private let summaryJSON = #"{"title":"会议","summary":"讨论了报价和预算。","key_points":["报价"],"action_items":["李娜跟进"]}"#

final class LLMChoiceTests: XCTestCase {
    func testMacAlwaysUsesTheService() {
        for a in OnDeviceAvailability.allCases {
            for s in ["", "onDevice", "service"] {
                XCTAssertEqual(LLMChoiceRule.resolve(stored: s, onDevice: a, isMac: true), .service)
            }
        }
    }

    func testPhoneDefaultsToOnDeviceOnlyWhenAvailable() {
        XCTAssertEqual(LLMChoiceRule.resolve(stored: "", onDevice: .available, isMac: false), .onDevice)
        for a in OnDeviceAvailability.allCases where a != .available {
            // 不可用时不整理，绝不默认去连云端
            XCTAssertEqual(LLMChoiceRule.resolve(stored: "", onDevice: a, isMac: false), .none, "\(a)")
        }
    }

    func testPhoneKeepsAnExplicitChoice() {
        XCTAssertEqual(LLMChoiceRule.resolve(stored: "service", onDevice: .available, isMac: false), .service)
        XCTAssertEqual(LLMChoiceRule.resolve(stored: "onDevice", onDevice: .modelNotReady, isMac: false), .onDevice)
        XCTAssertEqual(LLMChoiceRule.resolve(stored: "garbage", onDevice: .deviceNotEligible, isMac: false), .none)
    }

    func testWhatLeavesTheDevice() {
        XCTAssertFalse(LLMChoiceRule.sendsTextOffDevice(.onDevice, endpoint: "https://api.deepseek.com"))
        XCTAssertFalse(LLMChoiceRule.sendsTextOffDevice(.none, endpoint: "https://api.deepseek.com"))
        XCTAssertTrue(LLMChoiceRule.sendsTextOffDevice(.service, endpoint: "https://api.deepseek.com"))
        XCTAssertTrue(LLMChoiceRule.sendsTextOffDevice(.service, endpoint: " https://openrouter.ai/api/v1 "))
        XCTAssertFalse(LLMChoiceRule.sendsTextOffDevice(.service, endpoint: "http://192.168.1.20:11434"))
        XCTAssertFalse(LLMChoiceRule.sendsTextOffDevice(.service, endpoint: "http://mac-mini.local:8080"))
        // 填不出地址的按外发算（宁严勿宽）
        XCTAssertTrue(LLMChoiceRule.sendsTextOffDevice(.service, endpoint: ""))
        XCTAssertFalse(OnDeviceLLM().sendsTextOffDevice)
        XCTAssertTrue(LLMService(endpoint: URL(string: "https://api.openai.com/v1")!).sendsTextOffDevice)
    }

    func testCloudConfirmationIsAskedOnce() {
        XCTAssertTrue(LLMChoiceRule.needsCloudConfirmation(currentlySendsOut: false, toSendsOut: true, alreadyConfirmed: false))
        XCTAssertFalse(LLMChoiceRule.needsCloudConfirmation(currentlySendsOut: false, toSendsOut: true, alreadyConfirmed: true))
        // 云端之间换、或换到局域网，不问
        XCTAssertFalse(LLMChoiceRule.needsCloudConfirmation(currentlySendsOut: true, toSendsOut: true, alreadyConfirmed: false))
        XCTAssertFalse(LLMChoiceRule.needsCloudConfirmation(currentlySendsOut: false, toSendsOut: false, alreadyConfirmed: false))
        // 没确认过的外发服务不会被用来发请求
        XCTAssertFalse(LLMChoiceRule.usable(.service, sendsOut: true, confirmed: false))
        XCTAssertTrue(LLMChoiceRule.usable(.service, sendsOut: true, confirmed: true))
        XCTAssertTrue(LLMChoiceRule.usable(.service, sendsOut: false, confirmed: false))
        XCTAssertTrue(LLMChoiceRule.usable(.onDevice, sendsOut: false, confirmed: false))
        XCTAssertFalse(LLMChoiceRule.usable(.none, sendsOut: false, confirmed: true))
    }

    func testServiceNames() {
        XCTAssertEqual(LLMChoiceRule.serviceName(provider: "deepseek", endpoint: "https://api.deepseek.com"), "DeepSeek")
        XCTAssertEqual(LLMChoiceRule.serviceName(provider: "openrouter", endpoint: ""), "OpenRouter")
        XCTAssertEqual(LLMChoiceRule.serviceName(provider: "custom", endpoint: "https://llm.example.org/v1"), "llm.example.org")
        XCTAssertNil(LLMChoiceRule.serviceName(provider: "custom", endpoint: ""))
    }

    func testPresetsAreHTTPSAndHaveAModel() {
        for p in CloudPreset.all where !p.isCustom {
            XCTAssertTrue(p.endpoint.hasPrefix("https://"), p.id)
            XCTAssertFalse(p.models.isEmpty, p.id)
            XCTAssertNil(LLMConnectionTest.precheck(URL(string: p.endpoint)!, onPhone: true), p.id)
        }
    }
}

final class OnDeviceLLMTests: XCTestCase {
    func testUnavailableModelReportsWhyAndRefusesRequests() async throws {
        let a = OnDeviceLLM.availability
        try XCTSkipIf(a.isAvailable, "端侧模型在这台机器上可用，跑不了不可用的分支")
        let status = await OnDeviceLLM().check()
        XCTAssertEqual(status, .unreachable(a.rawValue))
        XCTAssertNotNil(OnDeviceAvailability(rawValue: a.rawValue))
        do {
            _ = try await OnDeviceLLM().open(timeout: 5).complete(LLMRequest(system: "s", user: "u", maxTokens: 10))
            XCTFail("不可用时不该有回复")
        } catch let e as LLMBackendError {
            XCTAssertEqual(e, .unavailable(a.rawValue))
        }
        // 读不到实际值时按文档的 4096
        let n = await OnDeviceLLM().contextLength()
        XCTAssertEqual(n, OnDeviceLLM.documentedContextSize)
    }

    func testWhichReasonsTheUserCanFix() {
        XCTAssertTrue(OnDeviceAvailability.appleIntelligenceOff.userCanFix)
        XCTAssertTrue(OnDeviceAvailability.modelNotReady.userCanFix)
        XCTAssertFalse(OnDeviceAvailability.deviceNotEligible.userCanFix)
        XCTAssertFalse(OnDeviceAvailability.unsupportedOS.userCanFix)
    }

    func testOnDeviceDefaultsAreSizedForTheSmallWindow() {
        let b = OnDeviceLLM()
        let budget = Summarizer.budget(contextLength: OnDeviceLLM.documentedContextSize, maxOutput: b.preferredMaxOutput!,
                                       overhead: b.promptOverhead)
        XCTAssertEqual(budget, Int(Double(4096 - 700 - 700 - 350) * 0.85))
        XCTAssertEqual(Summarizer.budget(for: b, contextLength: 4096, maxOutput: 700), Int(Double(budget) * 1.3))
        let svc = LLMService(endpoint: URL(string: "http://127.0.0.1:8092")!)
        XCTAssertEqual(Summarizer.budget(for: svc, contextLength: 8192, maxOutput: 1000), Summarizer.budget(contextLength: 8192))
        // Mac 的默认不变：没有 overhead 时和以前同一个公式
        XCTAssertEqual(Summarizer.budget(contextLength: 8192), Int(Double(8192 - 1000 - 700) * 0.85))
        XCTAssertEqual(Summarizer.budget(contextLength: nil), Summarizer.defaultBudget)
    }

    /// 回复结构都能翻成 Foundation Models 的生成格式（不需要模型可用）
    func testReplyShapesBuildGenerationSchemas() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else { throw XCTSkip("系统太旧") }
        for s in [Summarizer.shape, ConversationSummarizer.shape, DiaryWriter.shape, DiaryWriter.overviewShape] {
            XCTAssertNoThrow(try GenerationSchema(root: FM.dynamic(s, path: "Reply"), dependencies: []))
        }
        #else
        throw XCTSkip("没有 Foundation Models")
        #endif
    }
}

final class OnDeviceChunkingTests: XCTestCase {
    func testOneHourMeetingFitsTheWindowAndMerges() async throws {
        let fake = FakeBackend { r in summaryJSON }
        let s = await Summarizer.sized(backend: fake)
        XCTAssertEqual(s.maxOutput, 700)
        let lines = meeting(minutes: 60)
        let out = try await s.summarize(lines)
        XCTAssertEqual(out.title, "会议")
        let reqs = fake.requests
        // 每次请求都放得进 4096 的窗口（没有触发缩小重来）
        for r in reqs { XCTAssertLessThanOrEqual(FakeBackend.Channel.cost(r, overhead: fake.promptOverhead), 4096) }
        XCTAssertTrue(reqs.allSatisfy { $0.shape == Summarizer.shape })
        let parts = reqs.filter { $0.user.hasPrefix("Part ") }.count
        let merges = reqs.filter { $0.user.hasPrefix("Partial summaries") }.count
        XCTAssertGreaterThan(parts, 10)
        XCTAssertGreaterThanOrEqual(merges, 1)
    }

    func testAFewMinutesIsOneRequest() async throws {
        let fake = FakeBackend { _ in summaryJSON }
        let s = await Summarizer.sized(backend: fake)
        _ = try await s.summarize(meeting(minutes: 4))
        XCTAssertEqual(fake.requests.count, 1)
    }

    /// 估算比模型的分词器少算时，模型报超出窗口：缩小分块整体重来，而不是跳过那一块
    func testContextOverflowShrinksChunksAndRetries() async throws {
        let fake = FakeBackend(context: 1500) { _ in summaryJSON }
        let s = Summarizer(backend: fake, budget: 1800)
        let out = try await s.summarize(meeting(minutes: 10))
        XCTAssertEqual(out.summary, "讨论了报价和预算。")
        XCTAssertTrue(fake.requests.contains { FakeBackend.Channel.cost($0, overhead: 350) > 1500 }, "先按大块试过")
        let last = try XCTUnwrap(fake.requests.last)
        XCTAssertLessThanOrEqual(FakeBackend.Channel.cost(last, overhead: 350), 1500)
    }

    func testOverflowThatNeverFitsGivesUp() async {
        let fake = FakeBackend(context: 200) { _ in summaryJSON }
        do {
            _ = try await Summarizer(backend: fake, budget: 1800).summarize(meeting(minutes: 2))
            XCTFail("窗口太小时应该放弃")
        } catch {
            XCTAssertEqual(error as? LLMBackendError, .contextExceeded)
        }
    }

    func testConversationSummaryAndDiarySendShapes() async throws {
        let fake = FakeBackend { r in
            if r.shape == ConversationSummarizer.shape {
                return #"{"title":"报价","summary":"讨论报价。","kind":"conversation","key_points":[],"decisions":[],"todos":[],"people":["张伟"],"things":[]}"#
            }
            return #"{"overview":"开了会。","decisions":[],"todos":[]}"#
        }
        let s = await Summarizer.sized(backend: fake)
        let r = try await ConversationSummarizer(s).summarize(meeting(minutes: 3))
        XCTAssertEqual(r.summary?.people, ["张伟"])
        XCTAssertTrue(fake.requests.allSatisfy { $0.shape == ConversationSummarizer.shape })
    }

    func testOpenAICompatibleChannelIgnoresTheShape() async throws {
        let stub = try StubServer { _ in summaryJSON }
        defer { stub.stop() }
        let s = Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)
        XCTAssertEqual(s.maxOutput, 1000)
        _ = try await s.summarize(meeting(minutes: 2))
        let body = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(body["max_tokens"] as? Int, 1000)
        XCTAssertNil(body["response_format"])
        XCTAssertNotNil(body["chat_template_kwargs"], "本机服务照旧关掉思考")
    }
}

final class LLMConnectionTestTests: XCTestCase {
    private func body(_ s: String) -> Data { Data(s.utf8) }

    func testStatusMapping() {
        typealias C = LLMConnectionTest
        XCTAssertEqual(C.classify(status: 401, body: body(#"{"error":{"message":"Authentication Fails"}}"#), model: "m"), .badKey)
        XCTAssertEqual(C.classify(status: 403, body: nil, model: "m"), .badKey)
        XCTAssertEqual(C.classify(status: 402, body: body(#"{"error":{"message":"Insufficient Balance"}}"#), model: "m"), .noCredit)
        XCTAssertEqual(C.classify(status: 429, body: body(#"{"error":{"type":"insufficient_quota"}}"#), model: "m"), .noCredit)
        XCTAssertEqual(C.classify(status: 429, body: body(#"{"error":{"message":"Rate Limit Reached"}}"#), model: "m"), .rateLimited)
        XCTAssertEqual(C.classify(status: 404, body: body(#"{"error":{"code":"model_not_found","message":"The model `x` does not exist"}}"#),
                                  model: "x"), .modelNotFound(suggestions: []))
        XCTAssertEqual(C.classify(status: 400, body: body(#"{"error":{"message":"Model Not Exist"}}"#), model: "x"),
                       .modelNotFound(suggestions: []))
        XCTAssertEqual(C.classify(status: 400, body: body(#"{"error":{"message":"bad json"}}"#), model: "x"), .unexpected(400))
        XCTAssertEqual(C.classify(status: 503, body: nil, model: "x"), .server(503))
    }

    func testNetworkErrorMapping() {
        typealias C = LLMConnectionTest
        let cloud = URL(string: "https://api.deepseek.com")!, lan = URL(string: "http://192.168.1.20:11434")!
        XCTAssertEqual(C.classify(URLError(.notConnectedToInternet), endpoint: cloud), .offline)
        XCTAssertEqual(C.classify(URLError(.timedOut), endpoint: cloud), .timedOut)
        XCTAssertEqual(C.classify(URLError(.cannotFindHost), endpoint: cloud), .cannotFindHost)
        XCTAssertEqual(C.classify(URLError(.serverCertificateUntrusted), endpoint: cloud), .secureConnection)
        XCTAssertEqual(C.classify(URLError(.appTransportSecurityRequiresSecureConnection), endpoint: cloud), .needsHTTPS)
        // 局域网地址连不上：提示本地网络权限
        XCTAssertEqual(C.classify(URLError(.timedOut), endpoint: lan), .localNetwork(denied: false))
        XCTAssertEqual(C.classify(URLError(.notConnectedToInternet), endpoint: lan), .localNetwork(denied: false))
        XCTAssertEqual(C.classify(URLError(.cannotConnectToHost), endpoint: lan), .localNetwork(denied: false))
    }

    func testPrecheck() {
        typealias C = LLMConnectionTest
        XCTAssertEqual(C.precheck(URL(string: "http://127.0.0.1:8092")!, onPhone: true), .pointsToThisDevice)
        XCTAssertEqual(C.precheck(URL(string: "http://localhost:11434")!, onPhone: true), .pointsToThisDevice)
        XCTAssertNil(C.precheck(URL(string: "http://127.0.0.1:8092")!, onPhone: false))
        XCTAssertEqual(C.precheck(URL(string: "http://llm.example.org/v1")!, onPhone: true), .needsHTTPS)
        XCTAssertNil(C.precheck(URL(string: "http://192.168.1.20:11434")!, onPhone: true))
        XCTAssertEqual(C.precheck(URL(string: "api.deepseek.com")!, onPhone: true), .invalidAddress)
    }

    func testWrongModelNameSuggestsListedOnes() async throws {
        let stub = try StubServer(get: { path in
            path.hasSuffix("/models") ? (200, #"{"data":[{"id":"deepseek-flash"},{"id":"deepseek-v4-pro"},{"id":"other"}]}"#) : (404, "")
        }) { _ in "{}" }
        defer { stub.stop() }
        let p = await LLMConnectionTest.run(LLMService(endpoint: stub.url, model: "deepseek-chat"), onPhone: false)
        XCTAssertEqual(p, .modelNotFound(suggestions: ["deepseek-flash", "deepseek-v4-pro"]))
        let ok = await LLMConnectionTest.run(LLMService(endpoint: stub.url, model: "deepseek-flash"), onPhone: false)
        XCTAssertNil(ok)
    }

    func testBadKeyFromTheModelList() async throws {
        let stub = try StubServer(get: { _ in (401, #"{"error":{"message":"Authentication Fails"}}"#) }) { _ in "{}" }
        defer { stub.stop() }
        let p = await LLMConnectionTest.run(LLMService(endpoint: stub.url, apiKey: "sk-wrong", model: "m"), onPhone: false)
        XCTAssertEqual(p, .badKey)
    }
}

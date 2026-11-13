// SPDX-License-Identifier: Apache-2.0

import OpenBeanLibrary
@testable import OpenBeanVoice
import XCTest

final class NameFilterTests: XCTestCase {
    func testPronounsRolesAndPlaceholdersAreGeneric() {
        for n in ["我", "你", "他们", "大家", "店长", "督导", "员工", "发言人", "发言人2", "说话人A", "主持人", "客户", "经理", "老板",
                  "I", "you", "They", "Speaker 1", "speaker", "the speaker", "manager", "Store Manager", "team", "unknown", " ", "无"] {
            XCTAssertTrue(NameFilter.isGeneric(n), n)
        }
    }

    func testRealNamesAreKept() {
        for n in ["张伟", "王经理", "小王", "刘总监", "Priya", "Dr. Lee", "Tom", "陈默", "Speaker Smith", "店长小李"] {
            XCTAssertFalse(NameFilter.isGeneric(n), n)
        }
    }

    func testStripGenericOwner() {
        XCTAssertEqual(NameFilter.stripGenericOwner("发报价（发言人）"), "发报价")
        XCTAssertEqual(NameFilter.stripGenericOwner("Send the quote (speaker, Friday)"), "Send the quote（Friday）")
        XCTAssertEqual(NameFilter.stripGenericOwner("发报价（张伟，周三）"), "发报价（张伟，周三）")
        XCTAssertEqual(NameFilter.stripGenericOwner("发报价"), "发报价")
    }
}

final class TextSimilarityTests: XCTestCase {
    func testSimilar() {
        XCTAssertTrue(TextSimilarity.similar("周三前把报价发给刘经理", "把报价发给刘经理"))
        XCTAssertTrue(TextSimilarity.similar("Send the quote to Liu by Wednesday.", "send the quote to liu by wednesday"))
        XCTAssertFalse(TextSimilarity.similar("发报价", "发合同"))
        XCTAssertFalse(TextSimilarity.similar("下周一前发提案", "周三一起过提案"))
        XCTAssertEqual(TextSimilarity.dedupe(["周三前把报价发给刘经理", "把报价发给刘经理", "约牙医"]).count, 2)
    }
}

final class NoteRulesTests: XCTestCase {
    func testTitleIsOnlyReplacedWhenTheUserDidNotRename() {
        XCTAssertTrue(NoteRules.applyTitle(generated: "新标题", current: nil, lastApplied: nil))
        XCTAssertTrue(NoteRules.applyTitle(generated: "新标题", current: "", lastApplied: nil))
        // 重新摘要：标题还是上次摘要给的 → 换成新的
        XCTAssertTrue(NoteRules.applyTitle(generated: "新标题", current: "旧标题", lastApplied: "旧标题"))
        // 用户改过标题 → 不动
        XCTAssertFalse(NoteRules.applyTitle(generated: "新标题", current: "我起的名字", lastApplied: "旧标题"))
        XCTAssertFalse(NoteRules.applyTitle(generated: "新标题", current: "我起的名字", lastApplied: nil))
        XCTAssertFalse(NoteRules.applyTitle(generated: "", current: nil, lastApplied: nil))
    }

    func testEditedNotesAreNeverOverwritten() {
        XCTAssertEqual(NoteRules.existing(edited: false, mode: .auto), .overwrite)
        XCTAssertEqual(NoteRules.existing(edited: true, mode: .auto), .newFile)
        XCTAssertEqual(NoteRules.existing(edited: true, mode: .ask), .ask)
        XCTAssertEqual(NoteRules.existing(edited: false, mode: .ask), .overwrite)
        XCTAssertEqual(NoteRules.existing(edited: true, mode: .refresh), .skip)
        XCTAssertEqual(NoteRules.existing(edited: false, mode: .refresh), .overwrite)
        XCTAssertEqual(NoteRules.existing(edited: true, mode: .replace), .overwrite)
        XCTAssertEqual(NoteRules.existing(edited: false, mode: .newFile), .newFile)
        let t = Date()
        XCTAssertFalse(NoteRules.edited(modified: t.addingTimeInterval(1.5), writtenAt: t))
        XCTAssertTrue(NoteRules.edited(modified: t.addingTimeInterval(3), writtenAt: t))
    }
}

final class DiaryFolderTests: XCTestCase {
    private let notes = URL(fileURLWithPath: "/Vault/60-素材/20-录音/10-转录", isDirectory: true)

    func testRelativeFolders() {
        XCTAssertEqual(DiaryNote.folder("", notesFolder: notes, defaultName: "日记")?.path, "/Vault/60-素材/20-录音/10-转录/日记")
        XCTAssertEqual(DiaryNote.folder("日记", notesFolder: notes, defaultName: "x")?.path, "/Vault/60-素材/20-录音/10-转录/日记")
        XCTAssertEqual(DiaryNote.folder("../30-日记", notesFolder: notes, defaultName: "x")?.path, "/Vault/60-素材/20-录音/30-日记")
        XCTAssertEqual(DiaryNote.folder("./a/b/", notesFolder: notes, defaultName: "x")?.path, "/Vault/60-素材/20-录音/10-转录/a/b")
        XCTAssertEqual(DiaryNote.folder("a/../日记", notesFolder: notes, defaultName: "x")?.path, "/Vault/60-素材/20-录音/10-转录/日记")
        XCTAssertEqual(DiaryNote.folder("日:记", notesFolder: notes, defaultName: "x")?.lastPathComponent, "日-记")
    }

    func testUnsafeFoldersAreRefused() {
        for bad in ["/tmp/x", "~/x", "../../x", "..", "../", "a/..", ".", "../10-转录/../.."] {
            XCTAssertNil(DiaryNote.folder(bad, notesFolder: notes, defaultName: "x"), bad)
        }
        // 绕回笔记文件夹自己也不行
        XCTAssertNil(DiaryNote.folder("../10-转录", notesFolder: notes, defaultName: "x"))
    }

    func testRelativeLinks() {
        let note = notes.appendingPathComponent("2026-11-13-周会 (1).md")
        XCTAssertEqual(DiaryNote.relativeLink(from: notes.appendingPathComponent("日记"), to: note), "../2026-11-13-周会%20%281%29.md")
        XCTAssertEqual(DiaryNote.relativeLink(from: URL(fileURLWithPath: "/Vault/60-素材/20-录音/30-日记"), to: note),
                       "../10-转录/2026-11-13-周会%20%281%29.md")
        XCTAssertEqual(DiaryNote.relativeLink(from: notes.appendingPathComponent("a/b"), to: note), "../../2026-11-13-周会%20%281%29.md")
    }

    func testLabelsFollowTheApp() {
        let t = Date(timeIntervalSince1970: 1_794_550_000)
        let r = ConversationRef(recording: 1, index: 0)
        let day = DayFile(date: "2026-11-13", timeZone: "UTC", dayStartHour: 4, signature: "x", status: .diary,
                          conversations: [DayConversation(ref: r, wallStart: t, wallEnd: t, title: "会")],
                          diary: Diary(overview: "o", decisions: [DiaryItem(text: "d", refs: [r])]), model: nil, createdAt: t)
        let zh = DiaryNote.Labels(overview: "当天概述", decisions: "定了的事", todos: "待办", peopleAndThings: "提到的人和事", people: "人",
                                  things: "事", conversations: "对话", transcript: "全文", media: "媒体声")
        let md = DiaryNote.render(.init(day: day, recordedSeconds: 0, recordings: [1], timeZone: TimeZone(identifier: "UTC")!, labels: zh) { _ in "x" })
        XCTAssertTrue(md.contains("## 当天概述"))
        XCTAssertTrue(md.contains("## 定了的事"))
        XCTAssertTrue(md.contains("## 对话"))
        XCTAssertTrue(md.contains("[全文](x)"))
        XCTAssertFalse(md.contains("Overview"))
    }
}

final class ContextBudgetTests: XCTestCase {
    func testBudgetLeavesRoomForPromptAndOutput() {
        XCTAssertEqual(Summarizer.budget(contextLength: nil), Summarizer.defaultBudget)
        let b8k = Summarizer.budget(contextLength: 8192)
        XCTAssertGreaterThan(b8k, 5000)
        XCTAssertLessThan(b8k + 1000 + 700, 8192)
        XCTAssertEqual(Summarizer.budget(contextLength: 1_000_000), 24_000)
        XCTAssertEqual(Summarizer.budget(contextLength: 1024), 600)
    }

    func testLlamaServerProps() async throws {
        let stub = try StubServer(get: { path in
            path == "/props" ? (200, #"{"default_generation_settings":{"n_ctx":8192},"total_slots":4}"#) : (404, "")
        }, reply: { _ in "" })
        defer { stub.stop() }
        let n = await LLMService(endpoint: stub.url.appendingPathComponent("v1")).contextLength()
        XCTAssertEqual(n, 8192)
    }

    func testModelListEntry() async throws {
        let stub = try StubServer(get: { path in
            path == "/v1/models"
                ? (200, #"{"data":[{"id":"other","context_length":4096},{"id":"qwen","max_model_len":32768,"meta":{"n_ctx_train":262144}}]}"#)
                : (404, "")
        }, reply: { _ in "" })
        defer { stub.stop() }
        let n = await LLMService(endpoint: stub.url, model: "qwen").contextLength()
        XCTAssertEqual(n, 32768)
        // 列表里没有这个模型、又不止一个：不猜
        let none = await LLMService(endpoint: stub.url, model: "missing").contextLength()
        XCTAssertNil(none)
    }

    func testNothingKnown() async throws {
        let stub = try StubServer(reply: { _ in "" })
        defer { stub.stop() }
        let n = await LLMService(endpoint: stub.url).contextLength()
        XCTAssertNil(n)
    }
}

final class SummaryCleanupTests: XCTestCase {
    private let lines = (0..<6).map { TimedLine(start: Double($0) * 5, text: "第\($0)句，张伟说下周三之前把远山咖啡的报价发给刘经理，店长也同意了。") }

    func testGenericNamesOwnersAndDuplicatesAreCleaned() async throws {
        let stub = try StubServer { _ in
            #"""
            {"title":"报价","summary":"讨论了报价。","kind":"conversation",
             "decisions":["下周三前把报价发给刘经理","按三万个报价"],
             "todos":[{"task":"下周三前把报价发给刘经理","owner":"发言人"},"把报价发给刘经理（张伟）","另一件事","第三件"],
             "people":["张伟","我","店长","刘经理","发言人1"],"things":["远山咖啡"]}
            """#
        }
        defer { stub.stop() }
        let r = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10, glossary: ["远山咖啡"]))
            .summarize(lines)
        let s = try XCTUnwrap(r.summary)
        XCTAssertEqual(s.people, ["张伟", "刘经理"])
        XCTAssertEqual(r.droppedGeneric, 3)
        XCTAssertEqual(s.todos, ["下周三前把报价发给刘经理", "另一件事"]) // 泛称负责人去掉；相近的合并；最多两条
        XCTAssertEqual(s.decisions, ["按三万个报价"]) // 和待办重复的那条去掉
        // 词表不进提示词
        let system = ((stub.requests[0]["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
        XCTAssertFalse(system.contains("远山咖啡"))
    }

    func testShortSegmentsHaveNoTodos() async throws {
        let stub = try StubServer { _ in #"{"title":"t","summary":"提醒买东西。","todos":["买牛奶"],"people":[]}"# }
        defer { stub.stop() }
        let short = [TimedLine(start: 0, text: "提醒一下自己明天早上记得去楼下的超市买牛奶和面包，还有给妈妈打个电话。"),
                     TimedLine(start: 9, text: "顺便把上周借的那本书还给图书馆，再去取一下快递。")]
        let r = try await ConversationSummarizer(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)).summarize(short)
        XCTAssertEqual(r.summary?.todos, [])
    }
}

final class DiaryCleanupTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_794_550_000)

    private func input(_ i: Int, todos: [String] = [], decisions: [String] = [], people: [String] = []) -> DiaryWriter.Input {
        DiaryWriter.Input(ref: ConversationRef(recording: 1, index: i), wallStart: t0.addingTimeInterval(Double(i) * 3600),
                          wallEnd: t0.addingTimeInterval(Double(i) * 3600 + 600), kind: "conversation",
                          summary: ConversationSummary(title: "段\(i)", summary: "摘要", decisions: decisions, todos: todos, people: people),
                          chars: 400)
    }

    func testDuplicatesOwnersAndPeopleOrder() async throws {
        let stub = try StubServer { _ in
            #"""
            {"overview":"一天。",
             "decisions":[{"text":"周三前把报价发给刘经理","refs":["S1"]},{"text":"按三万个报价","refs":["S1"]}],
             "todos":[{"text":"周三前把报价发给刘经理","owner":"发言人","refs":["S1"]},
                      {"text":"把报价发给刘经理","owner":"张伟","refs":["S2"]},
                      {"text":"约面试","owner":"李娜","refs":["S2"]}]}
            """#
        }
        defer { stub.stop() }
        let inputs = [input(0, todos: ["发报价"], decisions: ["按三万个报价", "周三前发报价"], people: ["刘经理", "店长"]),
                      input(1, todos: ["张伟发报价", "约面试"], people: ["张伟", "刘经理"]),
                      input(2, people: ["王芳"])]
        let out = try await DiaryWriter(Summarizer(service: LLMService(endpoint: stub.url), timeout: 10)).write(inputs, languageSample: "")
        let d = try XCTUnwrap(out.diary)
        XCTAssertEqual(d.todos.map(\.text), ["周三前把报价发给刘经理", "约面试"])
        XCTAssertEqual(d.todos[0].refs.count, 2) // 合并时出处也合并
        XCTAssertEqual(d.todos[0].owner, "张伟") // 「发言人」不认，取合并进来的那条的负责人
        XCTAssertNil(d.todos[1].owner) // 李娜不在出处那段里
        XCTAssertEqual(d.decisions.map(\.text), ["按三万个报价"])
        XCTAssertEqual(out.duplicates, 2)
        XCTAssertEqual(out.droppedOwners, 2)
        // 人：泛称去掉，按出现的段数排
        XCTAssertEqual(d.people.map(\.name), ["刘经理", "张伟", "王芳"])
    }
}

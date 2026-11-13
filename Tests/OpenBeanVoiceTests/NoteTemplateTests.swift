// SPDX-License-Identifier: Apache-2.0

@testable import OpenBeanVoice
import XCTest

final class NoteTemplateTests: XCTestCase {
    private let tz = TimeZone(identifier: "Asia/Shanghai")!
    private var start: Date { Date(timeIntervalSince1970: 1_794_467_493) } // 2026-11-12 15:11:33 +08:00

    private func values(_ summary: RecordingSummary?) -> NoteTemplate.Values {
        NoteTemplate.Values(title: "周会 \"Q4\"", start: start, duration: 93.6, recordingID: 1_794_467_493, summary: summary,
                            lines: [TimedLine(start: 0, text: "大家好。"), TimedLine(start: 65.4, text: "下周五发布。")], timeZone: tz)
    }

    func testDefaultTemplateWithActionItems() {
        let s = RecordingSummary(title: "周会", summary: "讨论发布。", keyPoints: ["周五发布", "预算不变"], actionItems: ["小王写文档"])
        let md = NoteTemplate.render(NoteTemplate.defaultTemplate, values(s))
        XCTAssertEqual(md, """
        ---
        title: "周会 \\"Q4\\""
        created_at: 2026-11-12T15:11:33+08:00
        duration: "01:34"
        source: openbean
        recording_id: 1794467493
        tags: [recording]
        ---

        ## Summary

        讨论发布。

        ## Key points

        - 周五发布
        - 预算不变

        ## Action items

        - [ ] 小王写文档

        [Open in OpenBean](openbean://open/1794467493)

        ## Transcript

        [00:00] 大家好。

        [01:05] 下周五发布。

        """)
    }

    func testDefaultTemplateWithoutActionItemsOrSummary() {
        let s = RecordingSummary(title: "周会", summary: "讨论发布。", keyPoints: ["周五发布"])
        let md = NoteTemplate.render(NoteTemplate.defaultTemplate, values(s))
        XCTAssertFalse(md.contains("Action items"))
        XCTAssertTrue(md.contains("- 周五发布\n\n[Open in OpenBean]"))

        let bare = NoteTemplate.render(NoteTemplate.defaultTemplate, values(nil))
        XCTAssertFalse(bare.contains("## Summary"))
        XCTAssertFalse(bare.contains("## Key points"))
        XCTAssertTrue(bare.contains("tags: [recording]\n---\n\n[Open in OpenBean](openbean://open/1794467493)\n\n## Transcript"))
    }

    func testCustomTemplatePlaceholders() {
        let tpl = NoteTemplate.help + "# {{title}} ({{date}} {{time}})\n{{ duration }} {{unknown}} {{#action_items}}TODO{{/action_items}}{{#summary}}S={{summary}}{{/summary}}"
        let md = NoteTemplate.render(tpl, values(RecordingSummary(title: "x", summary: "Hi {{title}}")))
        // 说明注释去掉；未知占位符保留；值里的 {{title}} 不再替换
        XCTAssertEqual(md, "# 周会 \"Q4\" (2026-11-12 15:11)\n01:34 {{unknown}} S=Hi {{title}}")
    }

    func testSanitize() {
        XCTAssertEqual(NoteTemplate.sanitize("a/b:c*d?\"e\"<f>|g"), "a-b-c-d-e-f-g")
        XCTAssertEqual(NoteTemplate.sanitize("  [[链接]] #标签 ^块  "), "链接- -标签 -块")
        XCTAssertEqual(NoteTemplate.sanitize("line\nbreak\ttab"), "line break tab")
        XCTAssertEqual(NoteTemplate.sanitize("..hidden."), "hidden")
        XCTAssertEqual(NoteTemplate.sanitize("///"), "Recording")
        XCTAssertEqual(NoteTemplate.sanitize(String(repeating: "长", count: 200)).count, 80)
    }

    func testFileNameCollisions() {
        var taken: Set<String> = []
        func name() -> String { NoteTemplate.fileName(title: "周会/复盘", start: start, timeZone: tz) { taken.contains($0) } }
        XCTAssertEqual(name(), "2026-11-12-周会-复盘.md")
        taken.insert("2026-11-12-周会-复盘.md")
        XCTAssertEqual(name(), "2026-11-12-周会-复盘-1511.md")
        taken.insert("2026-11-12-周会-复盘-1511.md")
        XCTAssertEqual(name(), "2026-11-12-周会-复盘-1511-2.md")
    }

    func testFileNameWithoutTitleUsesTime() {
        var taken: Set<String> = []
        func name(_ t: String?) -> String { NoteTemplate.fileName(title: t, start: start, timeZone: tz) { taken.contains($0) } }
        XCTAssertEqual(name(nil), "2026-11-12-1511.md")
        XCTAssertEqual(name("  "), "2026-11-12-1511.md")
        taken.insert("2026-11-12-1511.md")
        XCTAssertEqual(name(nil), "2026-11-12-1511-2.md")
    }
}

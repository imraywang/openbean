// SPDX-License-Identifier: Apache-2.0

// 演示版（OPENBEAN_FLAVOR=demo bin/build-app → .build/OpenBean Demo.app）：
// 一套固定的假数据、假的录音豆，不初始化 CoreBluetooth、不加载识别模型、不调用大模型、不碰钥匙串和辅助功能。
// 只为看界面和截图（bin/ui-shots）。整个文件只在编译条件 DEMO 下存在，正式版和开发版里没有这些代码。
//
// 切状态用链接 openbean-demo://demo/<命令>[?seq=N]，带 seq 时处理完写 <数据目录>/demo-ack.json（截图脚本据此等待并取窗口号）：
//   state/connected|searching|connecting|failed|bluetooth-off|no-permission|lost|syncing|sync-failed|dictating|recording|low-battery|charging
//   hud/hidden|starting|listening|polishing|wrapping|typed|copied|nothing|error
//   page/today|library|dictation|recorder（overview 同 today）   today/<天数，负数往前>   settings/heart|voice|polish|library|agent|about（设置窗口）
//   select/summary|untranscribed|ondevice|long|segmented|none   search/<词>   filter/all|onRecorder|untranscribed|todos
//   play/<秒>|off   todo/check|clear   onboarding/<0–4>   close/onboarding|main|settings   window/main|onboarding/<宽>x<高>   appearance/light|dark|auto
//   trusted/yes|no   models/ready|missing|downloading   menu/open   ping   quit
//   sync/downloading|transcribing|diary|llm-down|cleanup-busy|cleaned|failed|finished|finished-expanded|none（心力模式页的四步条）
//   heart-intro/<0–3>|diary（心力模式介绍的各步；diary = 以前开着每日日记的人看到的第一步）
// 数据档：启动参数 -demoProfile empty 用空数据目录 openbean-demo-empty（第一次用：空库、没连过设备、向导未完成）。
// Debug 构建里也编进来：Xcode 预览（Previews.swift）用同一套假数据，见 Flavor.isPreview。
#if DEMO || DEBUG
import AppKit
import Observation
import OpenBeanKit
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI

/// 演示版里界面会读的几个状态
@MainActor @Observable
final class DemoState {
    static let shared = DemoState()
    /// 录音库搜索框
    var query = ""
    /// 向导停在第几步
    var onboardingStep = 0
    /// 心力模式介绍停在第几步；以前开着每日日记的人看到的版本
    var heartIntroStep = 0
    var heartIntroDiary = false
    /// 详情页假装正在播放到第几秒（nil：没在播放）
    var playAt: Double?
    /// 假装已经有辅助功能权限
    nonisolated(unsafe) static var trustedValue = true
    /// 预览、演示里大模型服务算不算连得上（设置 → 心力模式的状态行）
    nonisolated(unsafe) static var llmReachable = true
    var trusted: Bool { get { access(keyPath: \.trusted); return Self.trustedValue }
                        set { withMutation(keyPath: \.trusted) { Self.trustedValue = newValue } } }

    nonisolated static let profile: String = UserDefaults.standard.string(forKey: "demoProfile") ?? "default"
    nonisolated static var isEmpty: Bool { profile == "empty" }
    nonisolated static var dataFolder: String { profile == "default" ? "openbean-demo" : "openbean-demo-\(profile)" }
}

// MARK: - 假数据

enum DemoData {
    /// 在建任何存储之前调用：设置每次启动都重置成固定值；默认数据档的数据目录是空的就生成一套假录音
    static func prepare() {
        let d = Flavor.defaults
        let empty = DemoState.isEmpty
        let notes = AppPaths.support.appendingPathComponent("Notes")
        if !empty { try? FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true) }
        let values: [String: Any] = [
            "onboardingDone": !empty, "typeIntoApp": true, "polishEnabled": !empty,
            "polishEndpoint": "http://127.0.0.1:8092", "polishModel": "qwen3-8b",
            "summarizeRecordings": !empty, "notesEnabled": !empty, "notesFolder": empty ? "" : notes.path,
            "autoSync": true, "autoTranscribe": true, "buttonDictates": true, "readySound": true, "keepHistory": true,
            "hotkey": Hotkey.Preset.optionSpace.rawValue, "paragraphGap": 2.5, "sentencePause": 0.8,
            "deleteDictationAudio": true, "diaryFolder": "",
            ModeKeys.heartMode: !empty, ModeKeys.heartIntroSeen: !empty,
            ModeKeys.heartRecordingNotes: false, ModeKeys.heartDeleteFromRecorder: true,
            ModeKeys.heartAudioRetention: AudioRetention.default.rawValue, ModeKeys.heartAgentTranscripts: false,
        ]
        for (k, v) in values { d.set(v, forKey: k) }
        d.removeObject(forKey: "hotkeyCustom")
        d.removeObject(forKey: ModeKeys.legacyDailyDiary)
        guard !empty else { return }
        // 假数据改过（版本号变了）：预览的数据目录会一直留着，整个假录音库重新生成
        let marker = AppPaths.library.appendingPathComponent("demo-version")
        let fm = FileManager.default
        if (try? String(contentsOf: marker, encoding: .utf8)) != String(dataVersion), Flavor.isFake {
            for u in (try? fm.contentsOfDirectory(at: AppPaths.library, includingPropertiesForKeys: nil)) ?? [] { try? fm.removeItem(at: u) }
        }
        guard !fm.fileExists(atPath: AppPaths.library.appendingPathComponent("index.json").path) else { return }
        seed()
        try? String(dataVersion).write(to: marker, atomically: true, encoding: .utf8)
    }

    /// 假数据的版本：specs、台词、生成的文件改了就加 1
    static let dataVersion = 3

    /// 可重现的随机数（SplitMix64）：同一天生成的数据完全一样
    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    }

    enum Kind { case summary, transcript, raw, device, dictation }

    struct Spec {
        var day: Int, hour: Int, minute: Int
        var seconds: Double
        var kind: Kind
        var topic: String?
        /// 已从录音豆删掉（只在本机）
        var offDevice = false
        /// 一条录音里有几段隔得很远的谈话（台词、从第几秒开始、多长）：切段后是多段。空 = 用 topic 铺满整条
        var parts: [(topic: String, at: Double, seconds: Double)] = []
    }

    /// 二十多条录音，跨五周：今天（5 条，不算语音输入片段）、昨天（含一条跨午夜的、一条凌晨的）、本周、上个月都有；
    /// 7 天前那天没有录音
    static let specs: [Spec] = [
        Spec(day: 0, hour: 16, minute: 5, seconds: 184, kind: .device),
        Spec(day: 0, hour: 14, minute: 30, seconds: 1_092, kind: .device),
        Spec(day: 0, hour: 11, minute: 48, seconds: 21, kind: .dictation),
        Spec(day: 0, hour: 10, minute: 0, seconds: 3_486, kind: .summary, topic: "roadmap"),
        Spec(day: 0, hour: 13, minute: 15, seconds: 1_240, kind: .summary, topic: "growth2"),
        Spec(day: 0, hour: 8, minute: 52, seconds: 48, kind: .transcript, topic: "errands"),
        // 凌晨 1:40 的随手记：按「一天从 4 点算」归到昨天
        Spec(day: 0, hour: 1, minute: 40, seconds: 100, kind: .transcript, topic: "idea"),
        // 昨晚 23:30 开始、录到今天 1:20 的长录音：按开始时刻算昨天
        Spec(day: 1, hour: 23, minute: 30, seconds: 6_600, kind: .summary, topic: "retro"),
        Spec(day: 1, hour: 19, minute: 10, seconds: 3_122, kind: .device),
        Spec(day: 1, hour: 15, minute: 0, seconds: 2_534, kind: .summary, topic: "interview"),
        Spec(day: 1, hour: 9, minute: 30, seconds: 846, kind: .transcript, topic: "standup"),
        Spec(day: 2, hour: 17, minute: 40, seconds: 1_861, kind: .raw),
        Spec(day: 2, hour: 14, minute: 0, seconds: 2_820, kind: .summary, topic: "crit"),
        Spec(day: 2, hour: 10, minute: 15, seconds: 37, kind: .dictation),
        Spec(day: 3, hour: 16, minute: 30, seconds: 1_688, kind: .summary, topic: "oneonone"),
        Spec(day: 3, hour: 11, minute: 0, seconds: 1_320, kind: .transcript, topic: "hiring"),
        Spec(day: 4, hour: 20, minute: 15, seconds: 100, kind: .transcript, topic: "idea"),
        Spec(day: 5, hour: 14, minute: 0, seconds: 7_093, kind: .summary, topic: "podcast", offDevice: true),
        Spec(day: 6, hour: 10, minute: 0, seconds: 2_105, kind: .summary, topic: "growth", offDevice: true),
        Spec(day: 8, hour: 15, minute: 20, seconds: 724, kind: .summary, topic: "supplier", offDevice: true),
        Spec(day: 9, hour: 13, minute: 0, seconds: 5_640, kind: .raw, offDevice: true),
        Spec(day: 11, hour: 22, minute: 5, seconds: 352, kind: .summary, topic: "reading", offDevice: true),
        Spec(day: 13, hour: 18, minute: 30, seconds: 540, kind: .transcript, topic: "flat", offDevice: true),
        Spec(day: 15, hour: 9, minute: 15, seconds: 14, kind: .dictation),
        Spec(day: 19, hour: 10, minute: 0, seconds: 4_322, kind: .summary, topic: "retro", offDevice: true),
        Spec(day: 23, hour: 16, minute: 45, seconds: 1_980, kind: .summary, topic: "growth2", offDevice: true),
        Spec(day: 27, hour: 11, minute: 30, seconds: 2_411, kind: .raw, offDevice: true),
        Spec(day: 31, hour: 14, minute: 10, seconds: 1_245, kind: .summary, topic: "supplier2", offDevice: true),
        Spec(day: 36, hour: 9, minute: 40, seconds: 66, kind: .transcript, topic: "errands2", offDevice: true),
        // 傍晚开着录了两个半小时：站会、供应商电话、1:1 三段谈话，中间是长时间的安静（切成三段）
        Spec(day: 0, hour: 17, minute: 30, seconds: 9_000, kind: .transcript,
             parts: [("standup", 40, 300), ("supplier", 1_900, 420), ("oneonone", 5_600, 1_500)]),
        // 三天前 22:30 开着录了六个多小时：读书笔记一段，早上 4:20 又说了一句（按段归天：这一句算前天）
        Spec(day: 3, hour: 22, minute: 30, seconds: 22_000, kind: .transcript,
             parts: [("reading", 90, 300), ("errands2", 21_000, 40)]),
    ]

    static func seed() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var rng = RNG(state: 20_261_113)
        var list: [Recording] = []
        let enc = JSONEncoder()
        var dayConvs: [(Recording, Conversation)] = []
        for s in specs {
            let day = cal.date(byAdding: .day, value: -s.day, to: today)!
            let start = cal.date(bySettingHour: s.hour, minute: s.minute, second: 0, of: day)!
            let id = UInt32(start.timeIntervalSince1970)
            let downloaded = s.kind != .device && s.kind != .dictation
            var r = Recording(id: id, start: start, end: start.addingTimeInterval(s.seconds), durationMs: UInt32(s.seconds * 1000),
                              title: nil, onDevice: !s.offDevice, downloaded: downloaded,
                              transcribed: s.kind == .summary || s.kind == .transcript, isDictation: s.kind == .dictation)
            let dir = AppPaths.library.appendingPathComponent(String(id))
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if downloaded {
                try? enc.encode(peaks(&rng, seconds: s.seconds)).write(to: dir.appendingPathComponent("peaks.json"))
            }
            var segs: [TranscriptSegment] = []
            if r.transcribed, let topic = s.topic {
                segs = transcript(lines[topic] ?? [], seconds: s.seconds, rng: &rng)
            }
            for p in s.parts {
                segs += transcript(lines[p.topic] ?? [], seconds: p.seconds, rng: &rng)
                    .map { TranscriptSegment(start: $0.start + p.at, end: $0.end + p.at, text: $0.text) }
            }
            if r.transcribed, !segs.isEmpty {
                try? enc.encode(segs).write(to: dir.appendingPathComponent("transcript.json"))
                // 对话段：和 App 转写完以后算的一样
                var conv = ConversationFile.build(segs.map { ConversationFile.Line(start: $0.start, end: $0.end, text: $0.text) },
                                                  recordingStart: start, wallApprox: false)
                // 开着每日日记时会有的段摘要：有摘要的录音、分段录音里的各段
                let topics = s.parts.isEmpty ? [s.topic] : s.parts.map { Optional($0.topic) }
                for (i, t) in topics.enumerated() where i < conv.segments.count {
                    guard let t, s.kind == .summary || !s.parts.isEmpty, let cs = conversationSummaries[t] else { continue }
                    let k = s.parts.isEmpty ? conv.segments.indices : i..<(i + 1)
                    for j in k {
                        conv.segments[j].summary = cs.0
                        // 一个话题的长录音按长度切成了几段：小标题标上第几部分
                        if k.count > 1 { conv.segments[j].summary?.title += "（\(j + 1)/\(k.count)）" }
                        conv.segments[j].kind = cs.1
                        conv.segments[j].summaryModel = "qwen3-8b"
                    }
                }
                try? conv.encoded().write(to: dir.appendingPathComponent("segments.json"))
                dayConvs += conv.segments.map { (r, $0) }
            }
            if s.kind == .summary, let topic = s.topic, let sum = summaries[topic] {
                r.title = sum.title
                let stored = StoredSummary(summary: sum, createdAt: start.addingTimeInterval(s.seconds + 600),
                                           model: "qwen3-8b", appliedTitle: sum.title)
                try? enc.encode(stored).write(to: dir.appendingPathComponent("summary.json"))
            }
            list.append(r)
        }
        try? enc.encode(list).write(to: AppPaths.library.appendingPathComponent("index.json"))
        try? JSONEncoder.iso.encode(dictationEntries(today)).write(to: AppPaths.support.appendingPathComponent("dictation.json"))
        writeDays(dayConvs, recordings: list)
    }

    /// 日文件：今天有日记（概述、定了的事、待办、提到的人），4 天前只有一条随手记（内容太少，只列对话）
    static func writeDays(_ convs: [(Recording, Conversation)], recordings: [Recording]) {
        let b = DayBoundary(startHour: 4)
        func onDay(_ n: Int) -> [(Recording, Conversation)] {
            let day = b.day(b.day(of: Date()), offsetBy: -n)
            return convs.filter { b.day(of: $0.1.wallStart) == day }.sorted { $0.1.wallStart < $1.1.wallStart }
        }
        func dayConversations(_ cs: [(Recording, Conversation)]) -> [DayConversation] {
            cs.map { DayConversation(ref: ConversationRef(recording: $0.0.id, index: $0.1.index), wallStart: $0.1.wallStart,
                                     wallEnd: $0.1.wallEnd, kind: $0.1.kind, title: $0.1.summary?.title, summary: $0.1.summary?.summary) }
        }
        func ref(_ cs: [(Recording, Conversation)], _ title: String) -> [ConversationRef] {
            cs.filter { $0.1.summary?.title.hasPrefix(title) == true }.map { ConversationRef(recording: $0.0.id, index: $0.1.index) }
        }
        func write(_ n: Int, _ status: DayFile.Status, _ diary: Diary?) {
            let cs = onDay(n)
            guard !cs.isEmpty else { return }
            let key = DayFile.key(b.day(b.day(of: Date()), offsetBy: -n), calendar: b.calendar)
            let f = DayFile(date: key, timeZone: TimeZone.current.identifier, dayStartHour: 4, signature: "demo", status: status,
                            conversations: dayConversations(cs), diary: diary, model: "qwen3-8b", createdAt: Date(),
                            stats: DayStats(calls: diary == nil ? 0 : 1, seconds: 6, dropped: 0))
            let url = DayFile.url(library: AppPaths.library, date: key)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? f.encoded().write(to: url)
        }
        let today = onDay(0)
        // 人：照段摘要收集，不合并写法
        var people: [DiaryName] = []
        for (r, c) in today {
            for n in c.summary?.people ?? [] {
                let ref = ConversationRef(recording: r.id, index: c.index)
                if let i = people.firstIndex(where: { $0.name == n }) { people[i].refs.append(ref) } else { people.append(DiaryName(name: n, refs: [ref])) }
            }
        }
        write(0, .diary, Diary(
            overview: "上午过了 Q4 路线图，确定同步重写优先；午后看了激活率专项。傍晚连着三段：站会、和刘经理的咖啡袋报价电话，以及和 Priya 的 1:1，她会牵头团队版的权限管理。",
            decisions: [DiaryItem(text: "同步重写优先，批量导出顺延到一月", refs: ref(today, "Q4 路线图评审")),
                        DiaryItem(text: "定价页采用 B 版结构，团队版入口放回导航栏", refs: ref(today, "Q4 路线图评审")),
                        DiaryItem(text: "Priya 牵头团队版的权限管理", refs: ref(today, "1:1 · Priya"))],
            todos: [DiaryItem(text: "下周一前回复刘经理，确认起订量和设计稿", owner: "我", refs: ref(today, "供应商电话：咖啡袋报价")),
                    DiaryItem(text: "Priya：下周一前发一页提案", owner: "Priya", refs: ref(today, "1:1 · Priya")),
                    DiaryItem(text: "十二月初前把同步重写合进主干", owner: "Alex", refs: ref(today, "Q4 路线图评审"))],
            people: people,
            things: [DiaryName(name: "Q4 路线图", refs: ref(today, "Q4 路线图评审"))]))
        write(4, .brief, nil)
    }

    /// 段摘要（假的）：标题和段摘要、要点、定了的事、待办、提到的人；第二项是段的种类
    static let conversationSummaries: [String: (ConversationSummary, String)] = {
        var out: [String: (ConversationSummary, String)] = [:]
        let people: [String: [String]] = ["roadmap": ["Alex", "Priya", "陈默"], "supplier": ["刘经理"], "oneonone": ["Priya"],
                                          "standup": [], "growth2": [], "reading": [], "interview": [], "crit": [], "podcast": ["小周", "阿岚", "Tom"],
                                          "growth": [], "supplier2": [], "retro": []]
        for (k, s) in summaries {
            out[k] = (ConversationSummary(title: s.title, summary: s.summary, keyPoints: s.keyPoints, todos: Array(s.actionItems.prefix(3)),
                                          people: people[k] ?? []), k == "podcast" ? "media" : "conversation")
        }
        out["roadmap"]?.0.decisions = ["同步重写优先，批量导出顺延到一月", "定价页采用 B 版结构，团队版入口放回导航栏"]
        out["oneonone"]?.0.decisions = ["Priya 牵头团队版的权限管理"]
        out["standup"] = (ConversationSummary(title: "站会", summary: "上传重试已完成，同步测试不稳定；测试环境数据库磁盘又满了，会后扩容。新版设置页的稿子下午发出。",
                                              todos: ["会后给测试数据库扩容"]), "conversation")
        out["errands2"] = (ConversationSummary(title: "牙医复诊提醒", summary: "提醒自己下周二上午十点牙医复诊，带上次的片子。",
                                               todos: ["下周二上午十点牙医复诊，带片子"]), "monologue")
        return out
    }()

    /// 像说话的波形：一句一句的起伏，句间低谷
    static func peaks(_ rng: inout RNG, seconds: Double) -> [Float] {
        var out: [Float] = []
        var env = 0.0
        var talking = true
        var left = rng.range(8, 30)
        for _ in 0..<600 {
            left -= 1
            if left <= 0 { talking.toggle(); left = talking ? rng.range(10, 40) : rng.range(2, 7) }
            let target = talking ? rng.range(0.35, 1.0) : rng.range(0.02, 0.1)
            env = env * 0.55 + target * 0.45
            out.append(Float(min(max(env, 0), 1)))
        }
        return out
    }

    /// 把一段台词铺满录音时长，像真的说话一样：两三句连着说（句间停顿不到一秒），然后停一下换个话头。
    /// 长录音台词循环；话头之间的停顿按剩余时长拉开
    static func transcript(_ lines: [String], seconds: Double, rng: inout RNG) -> [TranscriptSegment] {
        guard !lines.isEmpty else { return [] }
        let n = min(240, max(lines.count, Int(seconds / 14)))
        let lens = (0..<n).map { i in Double(lines[i % lines.count].count) * 0.22 + 1 }
        // 先分组：每组 2–4 句
        var groups: [Int] = []
        var left = n
        while left > 0 { let g = min(left, 2 + Int(rng.next() % 3)); groups.append(g); left -= g }
        let talk = lens.reduce(0, +) + Double(n) * 0.6
        let pause = max((seconds - 2 - talk) / Double(max(groups.count, 1)), 2.6)
        var out: [TranscriptSegment] = []
        var t = 1.2
        var i = 0
        for g in groups {
            for _ in 0..<g {
                let len = lens[i]
                let end = min(t + len, seconds)
                out.append(TranscriptSegment(start: t, end: end, text: lines[i % lines.count]))
                t = end + rng.range(0.3, 0.9)
                i += 1
            }
            t += pause
        }
        return out
    }

    static func dictationEntries(_ today: Date) -> [DictationEntry] {
        let cal = Calendar.current
        let items: [(Int, Int, Int, Double, String, String?, Bool)] = [
            (0, 11, 48, 19, "好的，我下午三点前把修改后的方案发到群里，大家有问题直接在文档里评论。", "Slack", false),
            (0, 9, 20, 12, "提醒自己：今天要给刘经理回电话，确认咖啡袋的起订量。", "Notes", false),
            // 凌晨 1:20：按「一天从 4 点算」归到昨天
            (0, 1, 20, 6, "睡了，明早再说。", "微信", false),
            (1, 22, 5, 31, "Thanks for the quick turnaround. I left a few comments on the onboarding copy — mostly wording, nothing blocking.", "Mail", false),
            (1, 16, 40, 8, "收到，晚上回复你。", "微信", false),
            (1, 10, 2, 44, "把同步失败的重试逻辑改成指数退避，最多重试五次，每次失败都写日志，最后一次失败要在界面上提示用户。", "Cursor", false),
            (2, 10, 15, 37, "周三的设计评审改到周四上午十点，地点不变，Figma 链接我会提前发出来。", "Slack", false),
            (2, 21, 30, 15, "读书笔记：好的分组方式能让信息自己说话。", "Obsidian", false),
            (3, 14, 12, 26, "Can we move the 1:1 to Thursday? Wednesday is packed with interviews.", "Slack", false),
            (4, 9, 5, 52, "今天的计划：上午把定价页的数据看完，下午和 Priya 过一遍 B 版本，晚上整理访谈记录。", "Notes", true),
            (6, 18, 44, 9, "已经在路上了，大概二十分钟到。", "微信", false),
            (8, 11, 0, 23, "Release notes: faster sync, a clearer recorder page, and summaries for long recordings.", "Obsidian", false),
            (12, 15, 30, 17, "帮我查一下上个月燕麦奶的进货量，和这个月对比一下。", nil, true),
            (15, 9, 15, 14, "早上好，今天的站会我晚到五分钟。", "Slack", false),
        ]
        return items.map { day, h, m, dur, text, app, clip in
            let d = cal.date(bySettingHour: h, minute: m, second: 0, of: cal.date(byAdding: .day, value: -day, to: today)!)!
            return DictationEntry(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", day * 10_000 + h * 100 + m))!,
                                  date: d, duration: dur, text: text, app: app, viaClipboard: clip)
        }
    }

    // MARK: 台词（虚构的人和公司）

    static let lines: [String: [String]] = [
        "roadmap": [
            "好，我们开始吧。今天主要过一下 Q4 的路线图，Alex 先讲一下目前的进度。",
            "OK, so the sync rewrite is about 70% done. 剩下的主要是冲突处理和离线队列。",
            "离线队列这块我担心的是时间，十二月初能不能合进主干？",
            "I think we can, if we cut batch export from this release.",
            "批量导出可以挪到一月，客户那边问的人其实不多。",
            "那就这么定：同步重写优先，批量导出顺延。",
            "第二件事是定价页。Priya 上周做了三个版本，我们看一下数据。",
            "Version B converts best — about 4.1% versus 3.2% for the current page.",
            "但 B 把团队版藏得比较深，销售那边可能会有意见。",
            "我们可以把团队版的入口放回导航栏，其他保持 B 的结构。",
            "好，Priya 这周改完再跑一轮 A/B。",
            "最后一个是招聘。后端岗位现在有两个候选人进了终面。",
            "周四下午我和陈默一起面，周五给结论。",
            "还有别的吗？没有的话今天就到这里，谢谢大家。",
        ],
        "interview": [
            "先简单介绍一下您的店吧，开了多久了？",
            "开了四年多，在老城区，一共十二个座位，主要做外带。",
            "您现在每天的收银和库存是怎么管的？",
            "收银用的是平台送的那台机器，库存就靠一个 Excel，晚上打烊以后填。",
            "Excel 填起来大概要多久？",
            "忙的时候根本没空填，周末一般要补半个小时。",
            "有没有哪一次因为库存出过问题？",
            "有，上个月燕麦奶断了一整天，那天少卖了三十多杯。",
            "如果有个工具能提醒您补货，您最在意什么？",
            "别太复杂，手机上点两下就行，最好能直接跟供应商下单。",
            "价格上您能接受多少？",
            "一个月一百块以内吧，再贵就不如我自己多记一下。",
        ],
        "crit": [
            "Let's start with the onboarding flow. Can everyone see the Figma file?",
            "The first screen asks for too much: name, team size, role — and we don't use role anywhere.",
            "Agreed. Let's drop role and move team size to after the first project is created.",
            "What about the empty state on the dashboard? Right now it's just a grey box.",
            "I'd show a sample project people can poke at, with a clear “Start your own” button.",
            "Sample data is risky though — people sometimes think it's real.",
            "We can label it clearly, and delete it in one click.",
            "OK. Next: the invite step. Completion is 38%, the biggest drop in the funnel.",
            "Make it skippable and remind them later from the sidebar.",
            "Can we test that with five users before we ship?",
            "Yes, I'll set up sessions for next Tuesday and Wednesday.",
        ],
        "oneonone": [
            "最近怎么样？上次说的那个 side project 有进展吗？",
            "还行，主要是 pricing 的实验占了很多时间。",
            "I feel like I'm doing a lot of analysis but not shipping much.",
            "这个我理解。你希望下个季度多做一点什么？",
            "我想 own 一个完整的功能，从调研到上线。",
            "那团队版的权限管理怎么样？范围比较清楚，也需要数据支持。",
            "That sounds great. 我可以先写一个一页的提案。",
            "好，下周一之前发给我，我们周三一起过。",
        ],
        "podcast": [
            "欢迎收听《周末工坊》，我是主持人小周。今天请到的是 Blue Harbor Studio 的两位创始人。",
            "大家好，我是阿岚，负责产品和设计。",
            "Hi, I'm Tom. I mostly write the code.",
            "你们的项目开源已经两年了，最开始为什么决定开源？",
            "说实话，一开始是因为没钱做市场，开源是最便宜的分发方式。",
            "But it turned out the community found bugs faster than we could.",
            "那开源以后，怎么平衡社区的需求和你们自己的路线？",
            "我们每个月发一次 roadmap，issue 里点赞最多的前三个一定会排进去。",
            "有没有遇到过特别难处理的 PR？",
            "有一次有人提了一个三千行的重构，质量很好，但我们没精力 review。",
            "最后请他拆成了六个小 PR，花了一个多月才合完。",
            "收入方面呢？现在靠什么养活团队？",
            "托管版的订阅大概占八成，剩下是企业支持合同。",
        ],
        "growth": [
            "上周新注册 1,240，比前一周涨了 12%，主要来自那篇对比评测文章。",
            "付费转化还是 3.4%，没什么变化。",
            "试用到期提醒的邮件改版上线了吗？",
            "周三上线的，打开率从 31% 到了 44%。",
            "那这周重点看一下点击之后的落地页。",
            "SEO 这边，英文站的三篇长文已经排到第一页了。",
            "下周要不要在 Product Hunt 上发新版本？",
            "可以，但要先把 changelog 写好。",
        ],
        "growth2": [
            "这个月的目标是把激活率从 52% 提到 60%。",
            "我们发现第一次同步失败的用户，七天后基本都流失了。",
            "所以首要的事是把首次同步的成功率做上去。",
            "客服那边说最常见的问题是蓝牙权限没开。",
            "引导页里可以加一步检查权限，没开就直接给出打开的按钮。",
        ],
        "supplier": [
            "喂，刘经理您好，我是远山咖啡的，想问一下上次那款牛皮纸袋的报价。",
            "两百五十克的袋子，一万个起订是零点八六一个，带单向排气阀。",
            "如果做到三万个呢？",
            "三万个可以到零点七二，印刷两色以内。",
            "交期大概多久？",
            "打样一周，大货二十天左右。",
            "好的，我们内部确认一下设计稿，下周一前回复您。",
        ],
        "supplier2": [
            "这次想换一家烘焙商试试，主要是埃塞俄比亚的豆子。",
            "样品寄过来三款，耶加雪菲两款，西达摩一款。",
            "价格比现在的贵百分之八左右，但起订量低很多。",
            "先拿五公斤试一个月，看客人的反馈。",
        ],
        "reading": [
            "记一下今天读的第三章。作者说设计不是把东西变漂亮，而是把信息理清楚。",
            "印象最深的是那个例子：同一张地图，换一种分组方式，问路的人一下就看懂了。",
            "我们产品的设置页其实也有这个问题，选项是按技术分的，不是按用户的目的分的。",
            "明天开会可以提一下，先从语音输入这一组改起。",
        ],
        "retro": [
            "Q3 的目标有三个：留存、稳定性、上架企业版。我们一个一个看。",
            "三十天留存从 41% 到了 46%，达标。",
            "稳定性：P1 事故两次，目标是零次，没达标。",
            "两次都和数据库迁移有关，第二次回滚花了四十分钟。",
            "以后迁移要先在影子库跑一遍，这条写进流程。",
            "企业版延期了，SSO 那部分比预期复杂。",
            "Q4 先把 SSO 收尾，十一月底前给两家试点客户开通。",
        ],
        "standup": [
            "Yesterday I finished the retry logic for uploads. Today I'm on the flaky test in the sync suite.",
            "I'm blocked on the staging database — it ran out of disk again.",
            "I'll bump the volume right after this call.",
            "设计这边，新版设置页的稿子下午发出来。",
            "No blockers for me. Shipping the changelog page today.",
        ],
        "hiring": [
            "Two candidates left for the backend role: 陈思远 and Marco.",
            "思远的系统设计很扎实，但对我们这套技术栈不太熟。",
            "Marco knows the stack well but struggled with the concurrency question.",
            "我倾向思远，栈可以学，思路很难教。",
            "Let's do one more pairing session with each — an hour, on a real ticket.",
        ],
        "idea": [
            "刚才在地铁上想到，录音列表可以按人来分组，不只是按日期。",
            "比如所有和 Priya 的 1:1 放在一起，回顾的时候很方便。",
            "人名可以从摘要里取，不需要用户手动标。",
        ],
        "flat": [
            "这套是两室一厅，朝南，月租四千八，押一付三。",
            "厨房有点小，但是采光很好。",
            "物业费另算，一个月两百左右。",
            "离地铁站走路大概八分钟，楼下有菜市场。",
        ],
        "errands": ["周末记得买：咖啡豆、燕麦奶、五号电池，还有给妈妈的生日卡片。"],
        "errands2": ["下周二上午十点牙医复诊，记得带上次的片子。"],
    ]

    static let summaries: [String: RecordingSummary] = [
        "roadmap": RecordingSummary(
            title: "Q4 路线图评审",
            summary: "确认 Q4 优先完成同步重写，批量导出顺延到一月；定价页采用 B 版结构，并把团队版入口放回导航栏；后端岗位两位候选人周四终面。",
            keyPoints: ["同步重写完成约 70%，剩冲突处理和离线队列", "定价页 B 版转化 4.1%，现版 3.2%", "批量导出需求不多，可以顺延"],
            actionItems: ["Alex：十二月初前把同步重写合进主干", "Priya：本周改完定价页 B 版并重新跑 A/B", "林晓、陈默：周四下午终面，周五给结论"]),
        "interview": RecordingSummary(
            title: "用户访谈：老城区咖啡店主",
            summary: "店主经营一家 12 座的外带咖啡店，库存靠晚上手填 Excel，常常顾不上；上月燕麦奶断货一天，少卖三十多杯。希望补货提醒足够简单、能直接向供应商下单，月费在一百元以内。",
            keyPoints: ["库存记录依赖打烊后手填，忙时会漏", "断货有直接损失", "最在意简单：手机上点两下", "价格敏感：每月一百元以内"],
            actionItems: ["整理补货提醒的最小方案，找店主试用", "调研两家燕麦奶供应商是否有下单接口"]),
        "crit": RecordingSummary(
            title: "Design crit: onboarding flow",
            summary: "The team agreed to simplify the first onboarding screen, replace the empty dashboard with a clearly labelled sample project, and make the invite step skippable. Changes will be tested with five users before shipping.",
            keyPoints: ["Drop the unused role field; ask for team size later", "Sample project must be labelled and removable in one click", "Invite step has the biggest drop-off (38% completion)"],
            actionItems: ["Set up five user sessions for next Tuesday and Wednesday", "Update the Figma flow with the skippable invite step"]),
        "oneonone": RecordingSummary(
            title: "1:1 · Priya",
            summary: "Priya 觉得最近分析多、上线少，希望下季度负责一个完整功能。讨论后建议她牵头团队版的权限管理，先写一页提案。",
            keyPoints: ["定价实验占用了大部分时间", "希望从调研到上线完整负责一个功能"],
            actionItems: ["Priya：下周一前发一页提案", "周三一起过提案"]),
        "podcast": RecordingSummary(
            title: "播客：小团队如何做开源",
            summary: "Blue Harbor Studio 的两位创始人谈开源两年的经验：开源起初是为了低成本分发，后来社区反馈成了质量保障；每月公布路线图并承诺排入呼声最高的三个需求；收入主要来自托管版订阅。",
            keyPoints: ["开源是最便宜的分发方式", "每月 roadmap，点赞前三必做", "大 PR 请作者拆小再合", "托管订阅约占收入八成"],
            actionItems: ["剪辑成两期，下周五前发布第一期"]),
        "growth": RecordingSummary(
            title: "增长组周会",
            summary: "上周新注册 1,240（+12%），主要来自对比评测文章；付费转化持平 3.4%。试用到期提醒邮件改版后打开率从 31% 升到 44%。",
            keyPoints: ["注册增长来自内容", "转化持平", "邮件改版效果明显"],
            actionItems: ["本周分析邮件点击后的落地页", "写好 changelog 后在 Product Hunt 发布新版"]),
        "growth2": RecordingSummary(
            title: "激活率专项",
            summary: "本月目标是把激活率从 52% 提到 60%。首次同步失败的用户七天内几乎全部流失，最常见原因是没开蓝牙权限。",
            keyPoints: ["首次同步成功率决定激活", "蓝牙权限是头号问题"],
            actionItems: ["在引导页加入权限检查和一键打开"]),
        "supplier": RecordingSummary(
            title: "供应商电话：咖啡袋报价",
            summary: "250 克带排气阀的牛皮纸袋：一万个起订每个 0.86 元，三万个 0.72 元（两色印刷以内）；打样一周，大货约二十天。",
            keyPoints: ["1 万个 0.86 元 / 3 万个 0.72 元", "交期：打样 1 周 + 大货 20 天"],
            actionItems: ["下周一前回复刘经理，确认起订量和设计稿"]),
        "supplier2": RecordingSummary(
            title: "试用新的烘焙商",
            summary: "考虑换一家烘焙商，样品三款（耶加雪菲两款、西达摩一款），价格贵约 8% 但起订量低，先试五公斤一个月。",
            keyPoints: ["价格 +8%", "起订量低"],
            actionItems: ["下单五公斤试用", "一个月后收集客人反馈"]),
        "reading": RecordingSummary(
            title: "读书笔记：信息的分组",
            summary: "设计的核心是把信息理清楚；分组方式决定了别人能不能看懂。设置页目前按技术分组，应改为按用户目的分组。",
            keyPoints: ["设计 = 理清信息", "分组方式比视觉更重要"],
            actionItems: ["在周会上提出设置页重新分组，先改语音输入一组"]),
        "retro": RecordingSummary(
            title: "Q3 复盘",
            summary: "三个目标中留存达标（41% → 46%），稳定性未达标（两次 P1，都与数据库迁移有关），企业版因 SSO 延期。",
            keyPoints: ["留存达标", "两次 P1 事故都来自迁移", "SSO 比预期复杂"],
            actionItems: ["迁移先在影子库演练，写进流程", "十一月底前为两家试点客户开通 SSO"]),
    ]
}

// MARK: - 设备信息

extension DemoData {
    /// 拼一帧设备信息（字段顺序见 OpenBeanKit 的 DeviceInfo(frame:)）。电量 > 9 按百分比解析
    static func info(battery: Int = 72, charging: Bool = false, caseBattery: Int = 85, caseCharging: Bool = false,
                     recording: Bool = false) -> DeviceInfo? {
        func ascii(_ s: String, _ n: Int) -> [UInt8] { Array((Array(s.utf8) + Array(repeating: 0, count: n)).prefix(n)) }
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        let total: UInt32 = 32 * 1024 * 1024, free: UInt32 = 28_950_000
        var b = [UInt8](repeating: 0, count: 9)
        b += [1, UInt8(max(battery, 10)), charging ? 1 : 0]
        b += ascii("1.4.2", 5) + ascii("d32a0000c0ffee42", 16) + u32(total) + u32(free)
        b += [caseCharging ? 1 : 0] + ascii("0.9.7", 5) + [UInt8(max(caseBattery, 10))]
        b += [0x0C, 0x4F, 0x2A, 0x91, 0x3B, 0x77] + [0, 0, 0, 0, 0] + [recording ? 1 : 0] + ascii("2.1.0", 5)
        b += [0] // 校验字节（不解析）
        return DeviceInfo(frame: b)
    }
}

// MARK: - 状态切换和链接

@MainActor
final class DemoController {
    static let shared = DemoController()
    private var model: AppModel?
    var openWindow: OpenWindowAction?
    private var menuObserver: NSObjectProtocol?

    func start(_ m: AppModel) {
        model = m
        m.models.demoSet(DemoState.isEmpty ? .missing : .ready)
        m.hud.start()
        apply(state: DemoState.isEmpty ? "searching" : "connected")
    }

    func handle(_ path: String, query: String?) {
        guard let m = model else { return }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        var delay = 0.9
        switch parts[0] {
        case "ping": delay = 0.2
        case "state": apply(state: arg)
        case "hud": hud(arg)
        case "page":
            if let s = MainSection(link: arg) { m.nav.section = s }
            openMain()
        case "today":
            // today/<天数>：「今天」页翻到前几天（today/0 或 today 回到今天；today/-7 是一个没有录音的日子）
            let b = DayBoundary(startHour: m.settings.dayStartHour)
            let n = Int(arg) ?? 0
            m.nav.day = n == 0 ? nil : b.day(b.day(of: Date()), offsetBy: n)
            m.nav.section = .heart
            m.nav.showingSettings.remove(.heart)
            openMain()
        case "settings":
            // 老的设置窗口分页名照样认（见 SettingsRoute）；设置现在在主窗口里
            m.nav.open(SettingsRoute(link: arg) ?? .general(.top))
            openMain()
        case "select":
            DemoState.shared.query = ""
            m.library.filter = .all
            m.library.selection = pick(arg)
            m.nav.section = .library
            openMain()
        case "search":
            m.library.filter = .all
            DemoState.shared.query = parts.dropFirst().joined(separator: "/")
            m.library.selection = m.library.visible.first { m.library.matches($0, query: DemoState.shared.query) }?.id
            m.nav.section = .library
        case "filter":
            DemoState.shared.query = ""
            if let f = LibraryStore.Filter(rawValue: arg) { m.library.filter = f }
            m.library.selection = m.library.visible.first?.id
            m.nav.section = .library
        case "play":
            // play/<秒>：详情页假装播放到这里（看跟随高亮）；play/off 停
            DemoState.shared.playAt = Double(arg)
            m.library.selection = m.library.selection // 重新出现时读
        case "todo":
            // todo/check：把选中录音的第一条待办勾上；todo/clear：全部取消
            if let id = m.library.selection, let items = m.library.notes.summary(id)?.actionItems {
                for (i, t) in items.enumerated() { m.library.notes.setDone(id, t, arg == "check" && i == 0) }
            }
        case "onboarding":
            DemoState.shared.onboardingStep = Int(arg) ?? 0
            openWindow?(id: "onboarding")
            bringToFront("onboarding")
        case "heart-intro":
            // heart-intro/<0–3>；heart-intro/diary = 第一步，以前开着每日日记的人看到的版本
            DemoState.shared.heartIntroDiary = arg == "diary"
            DemoState.shared.heartIntroStep = Int(arg) ?? 0
            openWindow?(id: "heart-intro")
            bringToFront("heart-intro")
        case "close":
            window(arg)?.close()
            delay = 0.4
        case "window":
            if parts.count > 2 { resize(arg, parts[2]) }
            delay = 0.6
        case "appearance":
            NSApp.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        case "sync":
            // sync/<名字>：心力模式页顶上的四步条（见 DemoSyncRun.names；sync/none 不显示）
            DemoSyncRun.apply(arg, to: m.library.progress)
            m.nav.section = .heart
            m.nav.day = nil
            m.nav.showingSettings.remove(.heart)
            openMain()
        case "trusted": DemoState.shared.trusted = arg != "no"
        case "models":
            m.models.demoSet(arg == "missing" ? .missing : arg == "downloading" ? .downloading(0.42) : .ready)
        case "menu":
            openStatusMenu()
            delay = 0.1
        case "quit":
            NSApp.terminate(nil)
            return
        default:
            Log.write("演示：不认识的命令 \(path)")
        }
        guard let seq = query?.split(separator: "&").first(where: { $0.hasPrefix("seq=") })?.dropFirst(4) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.ack(String(seq)) }
    }

    private func openMain() {
        if let openWindow { openWindow(id: "main") }
        bringToFront("main")
    }

    private func pick(_ what: String) -> UInt32? {
        model.flatMap { Self.pick(what, in: $0.library) }
    }

    /// 选一条有代表性的录音：summary、untranscribed、ondevice、long、none 或录音 id
    static func pick(_ what: String, in lib: LibraryStore) -> UInt32? {
        let all = lib.recordings.filter { !$0.isDictation }
        switch what {
        case "summary": return all.first { lib.notes.summary($0.id) != nil }?.id
        case "untranscribed": return all.first { $0.downloaded && !$0.transcribed }?.id
        case "ondevice": return all.first { !$0.downloaded }?.id
        case "long": return all.max { $0.duration < $1.duration }?.id
        // 切成多段对话的录音（段最多的那条）
        case "segmented": return all.max { lib.conversations.conversations($0.id).count < lib.conversations.conversations($1.id).count }?.id
        case "none": return nil
        default: return UInt32(what)
        }
    }

    func apply(state name: String) {
        guard let m = model else { return }
        Self.apply(state: name, to: m)
    }

    /// 把一种设备状态摆到某个 AppModel 上（演示版的链接和 Xcode 预览共用）
    static func apply(state name: String, to m: AppModel) {
        let d = m.device
        m.library.demoSet(sync: .idle)
        m.dictation.demoSet(phase: .idle)
        switch name {
        case "searching": d.demoApply(state: .searching, info: nil, activity: .idle)
        case "connecting": d.demoApply(state: .connecting, info: nil, activity: .idle)
        case "failed":
            d.demoApply(state: .failed("\(LinkError.missing(String(localized: "recorder. Take it out of the case or press the case button to wake it.")))"),
                        info: nil, activity: .idle, problem: .notFound)
        case "bluetooth-off":
            d.demoApply(state: .failed("\(LinkError.bluetooth("蓝牙已关闭"))"), info: nil, activity: .idle, problem: .bluetoothOff)
        case "no-permission":
            d.demoApply(state: .failed("\(LinkError.bluetooth("没有蓝牙权限"))"), info: nil, activity: .idle, problem: .noPermission)
        case "lost":
            d.demoApply(state: .failed("\(LinkError.disconnected)"), info: nil, activity: .idle, problem: .lost)
        case "syncing":
            d.demoApply(state: .ready, info: DemoData.info(), activity: .syncing)
            let pending = m.library.pendingDownloads()
            let transcribing = m.library.recordings.first { $0.downloaded && !$0.transcribed && !$0.isDictation }?.id
            m.library.demoSet(sync: .downloading(id: pending.first?.id ?? 0, done: 1, total: max(pending.count, 2), fraction: 0.38, kbps: 22.4),
                              secondsLeft: 1_730, transcribing: transcribing.map { [$0: 0.42] } ?? [:])
        case "dictating":
            d.demoApply(state: .ready, info: DemoData.info(), activity: .dictating)
            m.dictation.demoSet(phase: .listening, level: 0.55, since: Date().addingTimeInterval(-14))
        case "sync-failed":
            d.demoApply(state: .ready, info: DemoData.info(), activity: .idle)
            m.library.demoSet(sync: .failed(String(localized: "The recorder stopped answering.")))
        case "recording": d.demoApply(state: .ready, info: DemoData.info(recording: true), activity: .idle)
        case "low-battery": d.demoApply(state: .ready, info: DemoData.info(battery: 10, caseBattery: 20), activity: .idle)
        case "charging": d.demoApply(state: .ready, info: DemoData.info(battery: 60, charging: true, caseCharging: true), activity: .idle)
        default: d.demoApply(state: .ready, info: DemoData.info(), activity: .idle)
        }
    }

    private func hud(_ mode: String) {
        guard let m = model else { return }
        let h = m.hud
        switch mode {
        case "starting": h.demoShow(.starting)
        case "listening":
            m.dictation.demoSet(phase: m.dictation.phase, level: 0.6, since: Date().addingTimeInterval(-23))
            h.demoShow(.listening)
        case "polishing":
            m.dictation.demoSet(phase: m.dictation.phase, polishing: 2)
            h.demoShow(.finishing)
        case "wrapping":
            m.dictation.demoSet(phase: m.dictation.phase)
            h.demoShow(.finishing)
        case "reconnecting": h.demoShow(.reconnecting)
        case "typed": h.demoShow(.done(count: 86, clipboard: false))
        case "copied": h.demoShow(.done(count: 86, clipboard: true))
        case "nothing": h.demoShow(.done(count: 0, clipboard: false))
        case "error": h.demoShow(.error(String(localized: "The recorder is recording. Stop it first.")))
        default: h.demoShow(.hidden)
        }
    }

    // MARK: 窗口

    func window(_ role: String) -> NSWindow? {
        switch role {
        case "hud": return model?.hud.demoPanel
        case "status": return NSApp.windows.first { String(describing: type(of: $0)).contains("StatusBarWindow") }
        default:
            return NSApp.windows.first { w in
                guard let id = w.identifier?.rawValue else { return false }
                return id == role || id.hasPrefix("\(role)-")
            }
        }
    }

    /// 内容区设成 宽x高，放在屏幕左上角固定位置（截图前后一致）
    private func resize(_ role: String, _ size: String) {
        let wh = size.split(separator: "x").compactMap { Double($0) }
        guard wh.count == 2, let w = window(role), let screen = w.screen ?? NSScreen.main else { return }
        let frame = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: wh[0], height: wh[1]))
        let vf = screen.visibleFrame
        w.setFrame(NSRect(x: vf.minX + 40, y: vf.maxY - 30 - frame.height, width: frame.width, height: frame.height), display: true)
    }

    /// 点开菜单栏图标的菜单。菜单跟踪会占住主线程，所以 6 秒后自己关掉
    private func openStatusMenu() {
        menuObserver.map(NotificationCenter.default.removeObserver)
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
            guard let menu = note.object as? NSMenu else { return }
            let t = Timer(timeInterval: 6, repeats: false) { _ in menu.cancelTracking() }
            RunLoop.main.add(t, forMode: .common)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard let w = self.window("status"), let button = Self.find(NSStatusBarButton.self, in: w.contentView) else {
                Log.write("演示：没找到菜单栏按钮"); return
            }
            button.performClick(nil)
        }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let v = view as? T { return v }
        for s in view.subviews { if let v = find(type, in: s) { return v } }
        return nil
    }

    /// 告诉截图脚本：第 seq 条命令处理完了，以及各窗口的窗口号（= CGWindowID）
    private func ack(_ seq: String) {
        var windows: [String: Int] = [:]
        for role in ["main", "onboarding", "heart-intro", "hud", "demo"] {
            if let w = window(role), w.isVisible { windows[role] = w.windowNumber }
        }
        var body: [String: Any] = ["seq": seq, "pid": Int(ProcessInfo.processInfo.processIdentifier), "windows": windows]
        // 菜单栏图标不是能单独截的窗口：给出它在屏幕上的位置（左上角为原点，screencapture -R 用）
        if let w = window("status"), let top = NSScreen.screens.first?.frame.maxY {
            let f = w.frame
            body["statusRect"] = "\(Int(f.minX) - 6),\(Int(top - f.maxY)),\(Int(f.width) + 12),\(Int(f.height))"
        }
        if let d = try? JSONSerialization.data(withJSONObject: body) {
            try? d.write(to: AppPaths.support.appendingPathComponent("demo-ack.json"), options: .atomic)
        }
    }
}

// MARK: - 启动时的小窗口

enum DemoScenes {
    /// 启动时打开、拿到 openWindow 之后就藏起来
    @SceneBuilder static func window(model: AppModel) -> some Scene {
        Window(Text(verbatim: "OpenBean Demo"), id: "demo") {
            DemoBinder(model: model)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)
    }
}

private struct DemoBinder: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(verbatim: "OpenBean Demo — openbean-demo://demo/…")
            .font(.caption).foregroundStyle(.secondary)
            .padding(12)
            .onAppear {
                DemoController.shared.openWindow = openWindow
                model.openMain = { openWindow(id: "main"); bringToFront("main") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { DemoController.shared.window("demo")?.orderOut(nil) }
            }
    }
}
#endif

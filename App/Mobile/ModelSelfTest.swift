// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanVoice

/// 端侧模型自检：启动参数 `-selftestSummarize YES`。用编的中文会议转写（几分钟一段、一小时一段）跑整条摘要和段摘要，
/// 把耗时、请求数、分块大小、模型实际的 token 数和输出写进日志（设置 → 日志）。不碰录音库、不联网。
/// 模拟器和不支持 Apple 智能的机器上只记下不可用的原因。真机上验证端侧模型用。
enum ModelSelfTest {
    static func run() async {
        let a = OnDeviceLLM.availability
        Log.write("自检（端侧模型）：可用性 \(a.rawValue)")
        guard a.isAvailable else { return }
        let backend = OnDeviceLLM()
        let ctx = await backend.contextLength()
        Log.write("自检：上下文 \(ctx.map(String.init) ?? "?") token")
        for (name, lines) in [("4 分钟", SampleMeeting.lines(minutes: 4)), ("60 分钟", SampleMeeting.lines(minutes: 60))] {
            let text = lines.map(\.text).joined()
            let real = await OnDeviceLLM.tokenCount(text)
            let s = await Summarizer.sized(backend: backend)
            let chunks = Summarizer.chunk(lines, budget: s.budget)
            Log.write("自检 \(name)：\(text.count) 字，估算 \(Summarizer.estimateTokens(text)) token，模型分词 \(real.map(String.init) ?? "?") token，"
                      + "每块预算 \(s.budget)，\(chunks.count) 块")
            let t0 = Date()
            do {
                let r = try await s.summarize(lines)
                Log.write(String(format: "自检 %@ 整条摘要：%.1f 秒。", name, Date().timeIntervalSince(t0))
                          + "标题「\(r.title)」摘要「\(r.summary)」要点 \(r.keyPoints) 待办 \(r.actionItems)")
            } catch {
                Log.write(String(format: "自检 %@ 整条摘要失败（%.1f 秒）：", name, Date().timeIntervalSince(t0)) + "\(error)")
            }
            let t1 = Date()
            do {
                let r = try await ConversationSummarizer(s).summarize(lines)
                Log.write(String(format: "自检 %@ 段摘要：%.1f 秒，%d 次调用，丢掉名字 %d 个。", name, Date().timeIntervalSince(t1), r.calls, r.droppedNames)
                          + "类型 \(r.kind)，\(r.summary.map { "「\($0.title)」\($0.summary) 定了 \($0.decisions) 待办 \($0.todos) 人 \($0.people)" } ?? "无")")
            } catch {
                Log.write(String(format: "自检 %@ 段摘要失败（%.1f 秒）：", name, Date().timeIntervalSince(t1)) + "\(error)")
            }
        }
    }
}

/// 编的中文会议转写：一家咖啡连锁的周会，几个议题轮流出现，带人名、数字、日期和待办。只用于自检
enum SampleMeeting {
    static let blocks: [[String]] = [
        ["好，我们开始吧，今天主要说三件事，新店选址、第三季度预算，还有远山咖啡的报价。",
         "先说选址，上周我和王磊去看了两个铺子，一个在滨江路，一个在大学城南门。",
         "滨江路那个面积大概八十平，月租两万六，人流主要是周末，工作日比较冷清。",
         "大学城那个小一点，五十五平，月租一万四，但是寒暑假会掉得很厉害。",
         "我倾向大学城，学生对价格敏感，但是复购高，我们的会员体系正好用得上。",
         "王磊你那边测过人流吗？测了，工作日中午十二点到一点，南门大概每分钟四十多个人经过。",
         "那这样，选址先定大学城，王磊下周五之前把租赁合同的条款发给法务看一下。"],
        ["第二件事是第三季度预算，财务那边给的总额是一百二十万，比第二季度少了百分之八。",
         "主要砍的是市场费用，从三十五万降到二十五万，剩下的保持不变。",
         "李娜你觉得二十五万够不够做开学季的活动？说实话有点紧，去年开学季我们花了十八万。",
         "如果今年还要做新店开业，那就不够了，我建议开业活动单独申请一笔。",
         "可以，那李娜你写一个开业活动的方案，预算控制在八万以内，月底前给我。",
         "另外设备采购那块，三台咖啡机的报价已经出来了，每台四万二，含三年保修。"],
        ["第三件事，远山咖啡的报价，他们这次给的豆子价格是每公斤一百一十八。",
         "比现在的供应商贵了十二块，但是他们答应免费做门店的品鉴培训，一年四次。",
         "我上周喝了他们的样品，云南的那款日晒风味挺好，深烘的那款一般。",
         "张伟你觉得能不能谈到一百一十块？可以试试，他们销售说过量大可以再谈。",
         "我们现在每个月大概用六百公斤，如果新店开起来，能到八百公斤。",
         "那就按八百公斤去谈，张伟下周三之前把还价发给他们，抄送给我和李娜。"],
        ["还有个小事，周六的员工培训改到周日上午十点，地点还是总部三楼会议室。",
         "新来的三个店员要参加，老员工自愿，培训内容是新菜单和收银系统的更新。",
         "收银系统的更新是下周一晚上十一点开始，大概两个小时，那天晚上门店早点关门。",
         "好的，那我在群里通知一下，各店店长确认收到。",
         "最后提醒一下，季度盘点是这个月二十八号，大家把库存表提前对一遍。"],
    ]

    /// 大约每分钟八句、两百多字；一小时就把这些议题按顺序轮几遍，每一轮的数字稍微变一下
    static func lines(minutes: Int) -> [TimedLine] {
        let flat = blocks.flatMap { $0 }
        var out: [TimedLine] = []
        for i in 0..<(minutes * 8) {
            let round = i / flat.count
            var text = flat[i % flat.count]
            if round > 0 { text = "（第\(round + 1)轮讨论）" + text }
            out.append(TimedLine(start: Double(i) * 7.5, text: text))
        }
        return out
    }
}

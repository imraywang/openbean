// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 「提到的人」「负责人」里不算人名的词：代词、泛称、职位和角色名。模型常把「我」「店长」「发言人」当成人名写进来。
/// 只做精确匹配（去掉空白、标点、大小写之后整个词在表里），不猜：带姓的称呼（「王经理」「Dr. Lee」）算人名。
public enum NameFilter {
    static let chinese: Set<String> = [
        // 代词
        "我", "你", "您", "他", "她", "它", "我们", "你们", "您们", "他们", "她们", "它们", "咱", "咱们", "大家", "自己", "本人",
        "别人", "人家", "对方", "某人", "有人", "谁", "这个人", "那个人", "这位", "那位", "各位",
        // 说话的人
        "发言人", "说话人", "讲话人", "主讲人", "演讲者", "主持人", "嘉宾", "听众", "观众", "用户", "客户", "顾客", "同事", "朋友",
        "老板", "领导", "上级", "下属", "员工", "同学", "老师", "学生", "家长", "医生", "护士", "司机", "师傅", "店员", "店主",
        "销售", "客服", "对接人", "负责人", "联系人", "参会者", "参会人员", "与会者", "团队", "小组", "全员", "所有人",
        // 职位
        "店长", "副店长", "督导", "区域经理", "经理", "总监", "主管", "组长", "队长", "总经理", "总裁", "董事长", "老总", "总",
        "产品经理", "项目经理", "设计师", "工程师", "开发", "测试", "运营", "市场", "财务", "人事", "hr", "助理", "秘书", "实习生",
        "导购", "收银", "收银员", "店助", "前台",
        // 亲属泛称
        "妈妈", "爸爸", "妈", "爸", "老婆", "老公", "孩子", "儿子", "女儿",
        // 占位
        "无", "未知", "不详", "未提及", "未指定", "某某", "待定",
    ]

    static let english: Set<String> = [
        "i", "me", "my", "you", "your", "he", "him", "his", "she", "her", "it", "we", "us", "our", "they", "them", "their",
        "someone", "somebody", "everyone", "everybody", "anyone", "nobody", "team", "theteam", "all", "everyoneelse",
        "speaker", "speaker1", "speaker2", "speakera", "speakerb", "thespeaker", "narrator", "host", "guest", "interviewer",
        "interviewee", "user", "customer", "client", "colleague", "friend", "boss", "manager", "storemanager", "supervisor",
        "director", "lead", "teamlead", "engineer", "designer", "developer", "owner", "assistant", "staff", "employee",
        "mom", "dad", "unknown", "none", "na", "tbd", "unspecified",
    ]

    /// 这个「名字」其实是代词、泛称或职位
    public static func isGeneric(_ name: String) -> Bool {
        let n = ConversationSummarizer.normalized(name)
        if n.isEmpty { return true }
        if chinese.contains(n) || english.contains(n) { return true }
        // 「发言人1」「Speaker 2」「说话人A」
        for p in ["发言人", "说话人", "speaker", "参会者"] where n.hasPrefix(p) {
            let rest = n.dropFirst(p.count)
            if rest.allSatisfy({ $0.isNumber || ($0.isLetter && $0.isASCII) }), rest.count <= 2 { return true }
        }
        return false
    }

    /// 去掉待办结尾括号里的泛称负责人：「发报价（发言人）」→「发报价」；括号里还有具体名字或时间的保留
    public static func stripGenericOwner(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespaces)
        guard let close = t.last, close == ")" || close == "）",
              let open = t.lastIndex(where: { $0 == "(" || $0 == "（" }) else { return t }
        let inner = t[t.index(after: open)..<t.index(before: t.endIndex)]
        let parts = inner.split(whereSeparator: { ",，、/;；".contains($0) }).map { $0.trimmingCharacters(in: .whitespaces) }
        let kept = parts.filter { !isGeneric($0) }
        if kept.count == parts.count { return t }
        t = String(t[..<open]).trimmingCharacters(in: .whitespaces)
        if !kept.isEmpty { t += "（\(kept.joined(separator: "，"))）" }
        return t
    }
}

/// 文字相近：去掉空白标点后，一条包含另一条，或者两两相邻字（bigram）的重合度够高
public enum TextSimilarity {
    public static func similar(_ a: String, _ b: String, threshold: Double = 0.7) -> Bool {
        let x = ConversationSummarizer.normalized(a), y = ConversationSummarizer.normalized(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y { return true }
        if min(x.count, y.count) >= 4, x.contains(y) || y.contains(x) { return true }
        let bx = bigrams(x), by = bigrams(y)
        guard !bx.isEmpty, !by.isEmpty else { return false }
        // 按短的那条算：短的大部分都在长的里面，就算同一件事
        return Double(bx.intersection(by).count) / Double(min(bx.count, by.count)) >= threshold
    }

    static func bigrams(_ s: String) -> Set<String> {
        let c = Array(s)
        guard c.count > 1 else { return c.isEmpty ? [] : [String(c)] }
        return Set((0..<(c.count - 1)).map { String(c[$0...$0 + 1]) })
    }

    /// 去掉和前面相近的条目（保留先出现的）
    public static func dedupe(_ items: [String]) -> [String] {
        var out: [String] = []
        for i in items where !out.contains(where: { similar($0, i) }) { out.append(i) }
        return out
    }
}

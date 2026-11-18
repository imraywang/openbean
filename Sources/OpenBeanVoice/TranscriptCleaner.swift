// SPDX-License-Identifier: Apache-2.0

import Foundation
import NaturalLanguage

/// 录音转写的「干净版」：按规则去掉不带意思的部分（语气词、口吃、紧挨着的重复、句首的口头禅），给人读。
/// 只删不加、不换顺序；拿不准就留着。存下来的转写不变，干净版每次从句子现算（所以总跟着个人词表走）。
/// 摘要、日记、切对话段、认佩戴者、词表都用原文，不用这里的结果。
///
/// 删什么（规则名见 `Rule`）：
/// - 语气词：呃、嗯、唔在哪都删；啊、哦、噢、唉、哎、诶、欸、额只在单独成段时删（前后是标点或句子边界，
///   「好快啊」「金额」「哎呀」不动）；英文 um、uh、er、erm、hmm、mm、emm、em 整词删
/// - 口吃：同一个汉字连着说（「我我觉得」「合合合作」「产产品」）。用系统分词判断：
///   落在同一个词里的保留（刚刚、看看、谢谢、认认真真、一一），第一个字是前面那个词的结尾时也保留
///   （「中国国家」「生产产品」「现在在哪」）——口吃重复的是下一个词的开头；另外保留笑声（哈、呵、嘿、嘻）、数字和量词（「2025年年底」「上上周」「一个个」）、
///   句末的叠字（多半是人名或昵称：「春春」）。应答的「对对对」「好好好」只留一个字
/// - 重复的词或短语：2–8 个汉字紧挨着说两遍（隔着逗号时只算整个小句的重复），而且两遍都正好落在词的边界上
///   （「我也我也」「你现在，你现在」「然后然后」）；保留「一个一个」这类「一X一X」、「研究研究」这类动词重叠；
///   英文同一个词连说两遍（the the）
/// - 话头：句首的「然后，」「就是，」「就是说，」「那个，」「这个，」（后面跟逗号才算）；
///   句中只删紧挨着语气词的「就是」「然后」（「然后就是呃你」→「然后你」），以及「那个呃，」「这个嗯，」
/// - 标点：删完留下的句首逗号、连着的逗号、逗号接句号、多余空格
///
/// 保底：口吃和重复删掉的是留下那份的拷贝，不丢意思；话头要是删掉了剩下内容的一半以上，就不删话头
public enum TranscriptCleaner {
    public enum Rule: String, CaseIterable, Sendable {
        case fillerSound, stutter, repeatedPhrase, discourseWord, punctuation
    }

    /// 一句的清理结果和每条规则删了几个字（评测用）
    public struct Trace: Sendable {
        public var text: String
        public var removed: [Rule: Int]
        /// 话头删得太多，这句没删话头
        public var guarded: Bool
    }

    /// 干净版的一句；整句都是语气词时返回空字符串
    public static func clean(_ text: String) -> String { trace(text).text }

    /// 同 clean，记住算过的句子（界面每次重画、搜索都会再要）。按原文记，所以词表改了句子就自然换成新的
    public static func cached(_ text: String) -> String {
        cacheLock.lock()
        if let hit = cache[text] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let out = clean(text)
        cacheLock.lock()
        if cache.count >= 200_000 { cache.removeAll(keepingCapacity: true) }
        cache[text] = out
        cacheLock.unlock()
        return out
    }

    /// 一篇转写读的时候每句显示什么：clean 时是干净版（整句是语气词的为空，界面上藏起来），否则原文。
    /// 下标和句子一一对应（点句子跳转、播放标亮、标记、佩戴者小圆点都按下标）
    public static func lines(_ texts: [String], clean: Bool) -> [String] {
        clean ? texts.map(cached) : texts
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    public static func trace(_ text: String) -> Trace {
        var removed: [Rule: Int] = [:]
        let full = fixedPoint(Array(text), discourse: true, &removed)
        guard removed[.discourseWord] != nil else { return Trace(text: String(full), removed: removed, guarded: false) }
        // 删了话头：和只用「删了不丢意思」的规则（语气词、口吃和重复，删掉的是留下那份的拷贝）比一比，
        // 话头删掉了剩下内容的一半以上就不删话头
        var removedLight: [Rule: Int] = [:]
        let light = fixedPoint(Array(text), discourse: false, &removedLight)
        if contentCount(full) * 2 < contentCount(light) {
            return Trace(text: String(light), removed: removedLight, guarded: true)
        }
        return Trace(text: String(full), removed: removed, guarded: false)
    }

    /// 反复跑各条规则直到不再变（保证清理两次和一次一样）
    private static func fixedPoint(_ start: [Character], discourse: Bool, _ removed: inout [Rule: Int]) -> [Character] {
        var s = start
        for _ in 0..<8 {
            let before = s
            if discourse { s = run(.discourseWord, discourseBeforeFiller, s, &removed) }
            s = run(.fillerSound, fillerSounds, s, &removed)
            s = run(.stutter, stutters, s, &removed)
            s = run(.repeatedPhrase, repeatedPhrases, s, &removed)
            s = run(.repeatedPhrase, repeatedEnglishWords, s, &removed)
            if discourse { s = run(.discourseWord, leadingDiscourse, s, &removed) }
            s = run(.punctuation, tidy, s, &removed)
            if s == before { break }
        }
        return s
    }

    private static func run(_ rule: Rule, _ pass: ([Character]) -> [Character], _ s: [Character],
                            _ removed: inout [Rule: Int]) -> [Character] {
        let out = pass(s)
        if out.count != s.count { removed[rule, default: 0] += s.count - out.count }
        return out
    }

    // MARK: - 字符分类

    static func isCJK(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value, c.unicodeScalars.count == 1 else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0xF900...0xFAFF).contains(v)
    }

    static func isASCIILetter(_ c: Character) -> Bool { c.isASCII && c.isLetter }

    /// 有内容的字：汉字、字母、数字
    static func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    static let weakPunct: Set<Character> = ["，", "、", "；", "：", ",", ";", ":"]
    static let strongPunct: Set<Character> = ["。", "！", "？", "!", "?"]

    private static func contentCount(_ s: [Character]) -> Int { s.reduce(0) { $0 + (isWord($1) ? 1 : 0) } }

    /// i 处是不是句子开头：文首，或前面（跳过空格）是句末标点
    private static func atSentenceStart(_ s: [Character], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, s[j] == " " { j -= 1 }
        return j < 0 || strongPunct.contains(s[j])
    }

    /// i 前面（跳过空格）没有字：文首或标点
    private static func boundaryBefore(_ s: [Character], _ i: Int) -> Bool {
        var j = i - 1
        while j >= 0, s[j] == " " { j -= 1 }
        return j < 0 || !isWord(s[j])
    }

    /// i 处（跳过空格）没有字：文末或标点
    private static func boundaryAt(_ s: [Character], _ i: Int) -> Bool {
        var j = i
        while j < s.count, s[j] == " " { j += 1 }
        return j >= s.count || !isWord(s[j])
    }

    private static func matches(_ s: [Character], _ i: Int, _ w: [Character]) -> Bool {
        guard i >= 0, i + w.count <= s.count else { return false }
        for k in w.indices where s[i + k] != w[k] { return false }
        return true
    }

    // MARK: - 语气词

    /// 在哪都是语气词
    static let alwaysFiller: Set<Character> = ["呃", "嗯", "唔"]
    /// 单独成段才是语气词（「好快啊」「金额」「哎呀」不算）
    static let standaloneFiller: Set<Character> = ["啊", "哦", "噢", "唉", "哎", "诶", "欸", "额", "哼"]
    static let englishFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "hmm", "hm", "mm", "mmm", "emm", "em"]

    static func fillerSounds(_ s: [Character]) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(s.count)
        var i = 0
        while i < s.count {
            let c = s[i]
            if alwaysFiller.contains(c) { i += 1; continue }
            if standaloneFiller.contains(c) {
                // 一串（可以夹着「呃嗯」）前后都没有字才删
                var j = i
                while j < s.count, standaloneFiller.contains(s[j]) || alwaysFiller.contains(s[j]) { j += 1 }
                if boundaryBefore(out, out.count) && boundaryAt(s, j) { i = j; continue }
                out.append(contentsOf: s[i..<j])
                i = j
                continue
            }
            if isASCIILetter(c), i == 0 || !isASCIILetter(s[i - 1]) {
                var j = i
                while j < s.count, isASCIILetter(s[j]) { j += 1 }
                let word = String(s[i..<j])
                if j - i <= 4, englishFillers.contains(word.lowercased()) { i = j; continue }
                out.append(contentsOf: s[i..<j])
                i = j
                continue
            }
            out.append(c)
            i += 1
        }
        return out
    }

    // MARK: - 话头

    static let leadingWords: [[Character]] = ["就是说", "然后", "就是", "那个", "这个"].map(Array.init)
    static let discourseWords: [[Character]] = ["然后", "就是", "那个", "这个", "所以"].map(Array.init)
    static let fillerBeforeWords: [[Character]] = ["就是", "然后"].map(Array.init)
    static let fillerPauseWords: [[Character]] = ["那个", "这个"].map(Array.init)

    /// 句首跟着逗号的口头禅：「然后，」「就是说，」「那个，」……（可以连着几个）
    static func leadingDiscourse(_ s: [Character]) -> [Character] {
        var s = s
        var i = 0
        while i < s.count {
            if atSentenceStart(s, i), s[i] != " " {
                var hit = false
                for w in leadingWords where matches(s, i, w) {
                    let k = i + w.count
                    if k < s.count, weakPunct.contains(s[k]), k + 1 < s.count, isWord(s[k + 1]) || s[k + 1] == " " {
                        s.removeSubrange(i...k)
                        hit = true
                        break
                    }
                }
                if hit { continue }
            }
            i += 1
        }
        return s
    }

    /// 贴着语气词的话头：「（句首/标点/话头）就是呃」「然后嗯」删掉「就是」「然后」；「那个呃，」「这个嗯，」删掉「那个」「这个」
    static func discourseBeforeFiller(_ s: [Character]) -> [Character] {
        var s = s
        var i = 0
        while i < s.count {
            guard alwaysFiller.contains(s[i]) else { i += 1; continue }
            var end = i
            while end < s.count, alwaysFiller.contains(s[end]) { end += 1 }
            var removedWord = false
            for w in fillerBeforeWords + fillerPauseWords {
                let start = i - w.count
                guard matches(s, start, w) else { continue }
                if fillerPauseWords.contains(w), !boundaryAt(s, end) { continue }
                let precededOK = boundaryBefore(s, start) || discourseWords.contains { matches(s, start - $0.count, $0) }
                guard precededOK else { continue }
                s.removeSubrange(start..<i)
                i = start + (end - i)
                removedWord = true
                break
            }
            if !removedWord { i = end }
        }
        return s
    }

    // MARK: - 口吃（同一个字连说）

    static let laughter: Set<Character> = ["哈", "呵", "嘿", "嘻", "嘎", "咯"]
    static let numerals: Set<Character> = Set("零〇一二三四五六七八九十百千万亿两几")
    /// 前面是数字时连着出现是正常的（「2025年年底」「3月月底」）；「上上周」「下下个月」
    static let unitChars: Set<Character> = Set("年月日号天周个次岁")
    static let beforeUpDown: Set<Character> = Set("周个次回星月期礼拜")
    /// 应答词连说三遍以上（「对对对」「好好好」）只留一个
    static let answers: Set<Character> = Set("对好是行")

    static func stutters(_ s: [Character]) -> [Character] {
        // 先找有没有连着的同一个汉字，没有就不分词
        var runs: [Range<Int>] = []
        var i = 0
        while i < s.count {
            var j = i + 1
            while j < s.count, s[j] == s[i] { j += 1 }
            if j - i >= 2, isCJK(s[i]), !laughter.contains(s[i]), !numerals.contains(s[i]) { runs.append(i..<j) }
            i = j
        }
        if runs.isEmpty { return s }
        let tokens = WordTokens(s)
        var out = s
        for r in runs.reversed() {
            let c = s[r.lowerBound]
            let n = r.count
            // 数字后面的单位、「上上周」「下下个月」
            if r.lowerBound > 0, s[r.lowerBound - 1].isNumber || numerals.contains(s[r.lowerBound - 1]), unitChars.contains(c) { continue }
            if c == "上" || c == "下", r.upperBound < s.count, beforeUpDown.contains(s[r.upperBound]), n == 2 { continue }
            // 句末的两个叠字（多半是人名、昵称、拟声）
            if n == 2, boundaryAt(s, r.upperBound) { continue }
            let keep = n >= 3 && answers.contains(c) ? 1 : max(1, tokens.keepCount(in: r))
            if keep >= n { continue }
            out.removeSubrange(r.lowerBound..<(r.lowerBound + n - keep))
        }
        return out
    }

    /// 系统分词（NLTokenizer，中文），按字的下标给出每个词的范围
    struct WordTokens {
        /// 每个字所在词的范围（标点、空格没有）
        private var span: [Range<Int>?]

        init(_ s: [Character]) {
            span = Array(repeating: nil, count: s.count)
            let str = String(s)
            // 字符下标 → String.Index
            var starts: [String.Index: Int] = [:]
            var idx = str.startIndex
            for k in 0..<s.count { starts[idx] = k; idx = str.index(after: idx) }
            var found: [Range<Int>] = []
            WordTokens.lock.lock()
            let tokenizer = WordTokens.shared
            tokenizer.string = str
            tokenizer.enumerateTokens(in: str.startIndex..<str.endIndex) { range, _ in
                guard let a = starts[range.lowerBound] else { return true }
                let b = range.upperBound == str.endIndex ? s.count : (starts[range.upperBound] ?? a + 1)
                found.append(a..<b)
                return true
            }
            WordTokens.lock.unlock()
            for r in found { for k in r where k < s.count { span[k] = r } }
        }

        // 分词器建一次很贵，共用一个（NLTokenizer 不是线程安全的，用锁）
        private static let lock = NSLock()
        nonisolated(unsafe) private static let shared: NLTokenizer = {
            let t = NLTokenizer(unit: .word)
            t.setLanguage(.simplifiedChinese)
            return t
        }()

        func token(at i: Int) -> Range<Int>? { i >= 0 && i < span.count ? span[i] : nil }

        /// 一串同样的字（下标范围 r）里该留几个。口吃重复的是下一个词的开头（「我我觉得」「产产品」），所以：
        /// 首字是前面那个多字词的结尾（「中国国家」「现在在哪」）时它算前面的词，留着；
        /// 剩下的里落在同一个多字词里的都留（「刚刚」「认认真真」），否则留一个
        func keepCount(in r: Range<Int>) -> Int {
            var lead = 0
            if let t = token(at: r.lowerBound), t.lowerBound < r.lowerBound, t.count >= 2 { lead = 1 }
            var best = 1
            var k = r.lowerBound + lead
            while k < r.upperBound {
                guard let t = token(at: k) else { k += 1; continue }
                let inside = min(t.upperBound, r.upperBound) - max(t.lowerBound, k)
                if t.count >= 2 { best = max(best, inside) }
                k = max(k + 1, t.upperBound)
            }
            return lead + min(best, r.count - lead)
        }

        func isBoundary(_ i: Int) -> Bool {
            guard i > 0, i < span.count, let t = span[i] else { return true }
            return t.lowerBound == i
        }

        func endsAt(_ i: Int) -> Bool {
            guard i > 0, i - 1 < span.count, let t = span[i - 1] else { return true }
            return t.upperBound == i
        }
    }

    // MARK: - 重复的词、短语

    /// 动词重叠（「研究研究」「商量商量」），不是重复
    static let reduplicatedVerbs: Set<String> = [
        "研究", "讨论", "商量", "考虑", "学习", "休息", "打听", "收拾", "整理", "了解", "介绍", "活动", "锻炼", "体验",
        "尝试", "熟悉", "交流", "沟通", "准备", "总结", "练习", "比较", "清理", "检查", "调整", "放松", "思考", "琢磨",
        "观察", "分析", "打扮", "表扬", "批评", "教育", "安慰", "鼓励", "帮助", "照顾", "关心", "参观", "欣赏", "享受",
        "感受", "回忆", "研讨", "梳理", "折腾", "溜达", "比划", "打扫", "认识", "联系", "试验", "调查", "评估", "测试",
        "雪白", "通红", "冰凉", "滚烫", "笔直", "漆黑",
    ]

    static func repeatedPhrases(_ s: [Character]) -> [Character] {
        var s = s
        var tokens: WordTokens?
        var i = 0
        outer: while i < s.count {
            guard isCJK(s[i]) else { i += 1; continue }
            for len in stride(from: 8, through: 2, by: -1) {
                guard i + len <= s.count else { continue }
                var next = i + len
                var sep = 0
                if next < s.count, s[next] == "，" || s[next] == "," { next += 1; sep = 1 }
                guard next + len <= s.count, (0..<len).allSatisfy({ s[i + $0] == s[next + $0] }) else { continue }
                let unit = Array(s[i..<(i + len)])
                guard unit.allSatisfy(isCJK), Set(unit).count > 1 else { continue }
                // 隔着逗号只删整个小句的重复（「关掉了，关掉了，」）：「我的水平，我的水平是……」第二遍接着往下说，留着
                if sep == 1, !boundaryAt(s, next + len) { continue }
                // 保护：「一个一个」「一点一点」、动词重叠、笑声
                if unit.first == "一", len == 2 { continue }
                if sep == 0, reduplicatedVerbs.contains(String(unit)) { continue }
                if unit.allSatisfy(laughter.contains) { continue }
                // 两遍都要正好落在词的边界上（「有没有没有」不是「有没」说了两遍）
                if tokens == nil { tokens = WordTokens(s) }
                let t = tokens!
                guard t.isBoundary(i), t.endsAt(i + len), t.isBoundary(next), t.endsAt(next + len) else { continue }
                s.removeSubrange(i..<next)
                tokens = nil
                continue outer
            }
            i += 1
        }
        return s
    }

    /// 英文不算重复的词（that that、had had 合语法；bye bye、ha ha、no no、so so 是说法）
    static let englishRepeatOK: Set<String> = ["that", "had", "is", "bye", "ha", "haha", "no", "so", "very", "la", "blah", "do", "yeah", "really"]

    static func repeatedEnglishWords(_ s: [Character]) -> [Character] {
        var s = s
        var i = 0
        while i < s.count {
            guard isASCIILetter(s[i]), i == 0 || !isASCIILetter(s[i - 1]) else { i += 1; continue }
            var j = i
            while j < s.count, isASCIILetter(s[j]) { j += 1 }
            let word = String(s[i..<j])
            guard j < s.count, s[j] == " " else { i = j; continue }
            let k = j + 1
            var e = k
            while e < s.count, isASCIILetter(s[e]) { e += 1 }
            if e > k, String(s[k..<e]).lowercased() == word.lowercased(), !englishRepeatOK.contains(word.lowercased()),
               !(e < s.count && s[e].isNumber) {
                s.removeSubrange(i..<k)
                continue
            }
            i = j
        }
        return s
    }

    // MARK: - 标点

    /// 删完留下的标点：句首和句号后的逗号、连着的逗号、逗号接句号、连着的同一个句号、多余空格；没有字了就是空字符串
    static func tidy(_ s: [Character]) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(s.count)
        for c in s {
            if c == " " {
                // 不在开头、不连着两个空格、不跟在中文标点后面
                guard let last = out.last, last != " ", !(weakPunct.contains(last) && !last.isASCII),
                      !(strongPunct.contains(last) && !last.isASCII) else { continue }
                out.append(c)
                continue
            }
            if weakPunct.contains(c) {
                while out.last == " " { out.removeLast() }
                guard let last = out.last, !weakPunct.contains(last), !strongPunct.contains(last) else { continue }
                out.append(c)
                continue
            }
            if strongPunct.contains(c) {
                while out.last == " " { out.removeLast() }
                while let last = out.last, weakPunct.contains(last) { out.removeLast() }
                if out.last == c { continue }
                guard !out.isEmpty else { continue }
                out.append(c)
                continue
            }
            out.append(c)
        }
        while out.last == " " { out.removeLast() }
        if !out.contains(where: isWord) { return [] }
        return out
    }
}

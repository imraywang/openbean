// SPDX-License-Identifier: Apache-2.0

import Foundation
import NaturalLanguage

/// 不用大模型的专有名词纠正：按个人词表把识别结果里「音对字错」的词换成词表里的写法。
///
/// 规则（都偏保守，宁可漏改也不误改）：
/// - 中文：逐字比较无声调拼音。多音字取「默认读音 ∪ 常见异读」，两边读音有交集就算同音。
///   - 词表里的单个汉字不参与纠正；
///   - 至少要有一个字和词表原字相同（全错的同音串更可能本来就是别的词）；
///   - 被换掉的字若是「的、了、都、也……」这类高频虚词，不换（「录音都很清楚」不能变成「录音豆很清楚」）；
///   - 两个字的词：只许错一个字，且系统分词要把这两个字切成两个单字——本身成词或与邻字成词都不改
///     （「公事」不会变「公式」，「开始时」不会变「开实时」），两个字里有虚词也不改（「时别」不变「识别」）；
///   - 近音（n/l、前后鼻音、平翘舌）只对 3 个字以上的词开，一次最多一个字近音，其余字必须原样相同。
/// - 英文或中英混合：只改大小写和空格、连字符（open bean / openbean / Open-Bean → 词表写法），只在单词边界上匹配。
/// - 文本里已经和词表一字不差的地方不动；重叠时取更长的词；标点从不改动。
public struct GlossaryCorrector: Sendable {
    public struct Replacement: Equatable, Sendable {
        public let original: String
        public let replacement: String
        public init(original: String, replacement: String) {
            self.original = original
            self.replacement = replacement
        }
    }

    // 词条编译后的元素
    enum Element: Sendable {
        case han(Character, Pinyin.Sound)
        /// 英文/数字片段（小写），splittable：长片段允许中间多一个空格（open bean → openbean）
        case word(String, splittable: Bool)
        /// 其它字符（. + 之类）必须原样相同
        case literal(Character)
    }

    struct Term: Sendable {
        let text: String
        let chars: [Character]
        let elements: [Element]
        let hanCount: Int
    }

    private let terms: [Term]

    public init(terms raw: [String]) {
        var seen = Set<String>()
        var list: [Term] = []
        for r in raw {
            let t = r.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !t.hasPrefix("#"), seen.insert(t).inserted else { continue }
            let elements = Self.compile(t)
            guard !elements.isEmpty else { continue }
            let hanCount = elements.filter { if case .han = $0 { return true }; return false }.count
            let hasWord = elements.contains { if case .word = $0 { return true }; return false }
            // 纯汉字的单字词不纠正；没有汉字也没有字母的词条（纯符号）跳过
            if hanCount == 1, !hasWord { continue }
            if hanCount == 0, !hasWord { continue }
            list.append(Term(text: t, chars: Array(t), elements: elements, hanCount: hanCount))
        }
        terms = list
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// 纠正一句话，返回新文本和每处替换（原文 → 词表写法）
    public func correct(_ text: String) -> (text: String, replacements: [Replacement]) {
        guard !terms.isEmpty, !text.isEmpty else { return (text, []) }
        let chars = Array(text)
        var ctx = Context(chars: chars, text: text)

        // 先找所有已经正确的位置，这些位置不再动
        var protected: [Range<Int>] = []
        var candidates: [(range: Range<Int>, term: Term)] = []
        for term in terms {
            var i = 0
            while i < chars.count {
                if let end = match(term, at: i, ctx: &ctx) {
                    if Array(chars[i..<end]) == term.chars {
                        protected.append(i..<end)
                    } else if accept(term, range: i..<end, ctx: &ctx) {
                        candidates.append((i..<end, term))
                    }
                }
                i += 1
            }
        }
        guard !candidates.isEmpty else { return (text, []) }

        // 长的优先，同样长取靠前的；与已正确的位置或已选的重叠则放弃
        candidates.sort {
            $0.range.count != $1.range.count ? $0.range.count > $1.range.count : $0.range.lowerBound < $1.range.lowerBound
        }
        var chosen: [(range: Range<Int>, term: Term)] = []
        for c in candidates where !protected.contains(where: { $0.overlaps(c.range) })
            && !chosen.contains(where: { $0.range.overlaps(c.range) }) {
            chosen.append(c)
        }
        chosen.sort { $0.range.lowerBound < $1.range.lowerBound }

        var out = ""
        var reps: [Replacement] = []
        var pos = 0
        for c in chosen {
            out += String(chars[pos..<c.range.lowerBound])
            out += c.term.text
            reps.append(Replacement(original: String(chars[c.range]), replacement: c.term.text))
            pos = c.range.upperBound
        }
        out += String(chars[pos...])
        return (out, reps)
    }

    // MARK: 匹配

    /// 一次 correct 调用里的缓存：每个字的读音、分词结果
    struct Context {
        let chars: [Character]
        let text: String
        var sounds: [Pinyin.Sound?]
        var tokens: Set<Range<Int>>?

        init(chars: [Character], text: String) {
            self.chars = chars
            self.text = text
            sounds = Array(repeating: nil, count: chars.count)
        }

        mutating func sound(_ i: Int) -> Pinyin.Sound {
            if let s = sounds[i] { return s }
            let s = Pinyin.sound(chars[i])
            sounds[i] = s
            return s
        }

        /// 系统分词得到的每个词（按字符下标）
        mutating func tokenRanges() -> Set<Range<Int>> {
            if let t = tokens { return t }
            var set = Set<Range<Int>>()
            let tok = NLTokenizer(unit: .word)
            tok.string = text
            tok.setLanguage(.simplifiedChinese)
            tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
                let lo = text.distance(from: text.startIndex, to: r.lowerBound)
                let hi = lo + text.distance(from: r.lowerBound, to: r.upperBound)
                set.insert(lo..<hi)
                return true
            }
            tokens = set
            return set
        }
    }

    /// 从 start 开始按词条结构匹配（汉字按拼音、英文不分大小写），返回结束位置
    func match(_ term: Term, at start: Int, ctx: inout Context) -> Int? {
        let chars = ctx.chars
        var i = start
        // 词条以英文开头：前一个字符不能是字母数字（单词边界）
        if case .word = term.elements.first, start > 0, Self.isAlnum(chars[start - 1]) { return nil }
        for (k, e) in term.elements.enumerated() {
            if k > 0 {
                // 英文片段之间、汉字与英文之间可以有空格（英文片段之间也可以是一个连字符）
                let prev = term.elements[k - 1]
                if Self.isWord(prev) || Self.isWord(e) {
                    let bothWords = Self.isWord(prev) && Self.isWord(e)
                    var n = 0
                    while i < chars.count, n < 1, chars[i] == " " || (bothWords && chars[i] == "-") { i += 1; n += 1 }
                }
            }
            guard i < chars.count else { return nil }
            switch e {
            case let .han(_, sound):
                guard Pinyin.isHan(chars[i]) else { return nil }
                let r = ctx.sound(i)
                guard !r.exact.isDisjoint(with: sound.exact) || !r.fuzzy.isDisjoint(with: sound.fuzzy) else { return nil }
                i += 1
            case let .word(w, splittable):
                guard let end = Self.matchWord(w, splittable: splittable, chars: chars, at: i) else { return nil }
                i = end
            case let .literal(c):
                guard chars[i] == c else { return nil }
                i += 1
            }
        }
        // 词条以英文结尾：后一个字符不能是字母数字
        if case .word = term.elements.last, i < chars.count, Self.isAlnum(chars[i]) { return nil }
        return i
    }

    /// 中文部分的保守规则（英文部分 match 已经保证只差大小写和空格）
    func accept(_ term: Term, range: Range<Int>, ctx: inout Context) -> Bool {
        // 把文本里的汉字和词条里的汉字一一对上
        let textHan = range.filter { Pinyin.isHan(ctx.chars[$0]) }
        let termHan: [(Character, Pinyin.Sound)] = term.elements.compactMap {
            if case let .han(c, r) = $0 { return (c, r) }
            return nil
        }
        guard textHan.count == termHan.count else { return false }
        var diffs = 0, fuzzy = 0
        for (k, idx) in textHan.enumerated() {
            let c = ctx.chars[idx]
            guard c != termHan[k].0 else { continue }
            diffs += 1
            if Self.functionChars.contains(c) { return false }
            if ctx.sound(idx).exact.isDisjoint(with: termHan[k].1.exact) { fuzzy += 1 }
        }
        if diffs == 0 { return true }                      // 只差大小写或空格
        let n = term.hanCount
        if n < 2 { return false }
        if diffs == n { return false }                     // 至少留一个原字
        if fuzzy > 0 { return n >= 3 && fuzzy == 1 && diffs == 1 }
        if n == 2 {
            guard diffs == 1 else { return false }
            // 纯两字词：系统分词必须把这两个字切成两个单字。
            // 本身成词（公事、威信）或和旁边的字连成词（开始|时、办公室、这里|明确）都说明大概率是别的词
            if term.elements.count == 2 {
                let a = textHan[0], tokens = ctx.tokenRanges()
                // 没换的那个字是虚词也不改（「这时别忘了」的「时别」不是「识别」）
                guard !Self.functionChars.contains(ctx.chars[a]), !Self.functionChars.contains(ctx.chars[a + 1]) else { return false }
                guard tokens.contains(a..<(a + 1)), tokens.contains((a + 1)..<(a + 2)) else { return false }
            }
        }
        return true
    }

    static func matchWord(_ w: String, splittable: Bool, chars: [Character], at start: Int) -> Int? {
        let letters = Array(w)
        var i = start, k = 0
        var splitUsed = false
        while k < letters.count {
            guard i < chars.count else { return nil }
            let c = chars[i]
            if c == " ", splittable, !splitUsed, k >= 3, letters.count - k >= 3 {
                splitUsed = true; i += 1; continue
            }
            guard c.isASCII, c.lowercased() == String(letters[k]) else { return nil }
            i += 1; k += 1
        }
        return i
    }

    static func isWord(_ e: Element) -> Bool { if case .word = e { return true }; return false }
    static func isAlnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }

    /// 词条拆成元素：汉字逐字；英文按空格、连字符、驼峰、字母数字交界拆段
    static func compile(_ term: String) -> [Element] {
        var out: [Element] = []
        var pieces: [String] = []
        var cur = ""
        func flushWord() {
            if !cur.isEmpty { pieces.append(cur); cur = "" }
            for p in pieces {
                out.append(.word(p.lowercased(), splittable: p.count >= 6))
            }
            pieces = []
        }
        func endPiece() { if !cur.isEmpty { pieces.append(cur); cur = "" } }
        var prev: Character?
        for c in term {
            if isAlnum(c) {
                if let p = prev, isAlnum(p) {
                    let camel = p.isLowercase && c.isUppercase
                    let digitEdge = p.isNumber != c.isNumber
                    if camel || digitEdge { endPiece() }
                }
                cur.append(c)
            } else if c == " " || c == "-" {
                endPiece()
            } else {
                flushWord()
                if Pinyin.isHan(c) {
                    out.append(.han(c, Pinyin.sound(c)))
                } else if !c.isWhitespace {
                    out.append(.literal(c))
                }
            }
            prev = c
        }
        flushWord()
        return out
    }

    /// 高频虚词、代词等：识别结果里出现这些字通常是真的，不当成错字换掉
    static let functionChars: Set<Character> = Set(
        "的地得了着过吗呢吧啊呀哦嘛呗也都就还又才再很太最更是在有和与跟及或而但被把给让对向从到为以之其这那哪个些我你他她它们不没别要会能可将已")
}

/// 无声调拼音（ü 写作 v），多音字带常见异读
enum Pinyin {
    /// 一个字的读音：精确读音集合、近音归一后的集合
    struct Sound: Sendable {
        let exact: Set<String>
        let fuzzy: Set<String>
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [Character: Sound] = [:]

    static func isHan(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first, c.unicodeScalars.count == 1 else { return false }
        switch s.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2EBEF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    static func readings(_ c: Character) -> Set<String> { sound(c).exact }

    static func sound(_ c: Character) -> Sound {
        lock.lock(); defer { lock.unlock() }
        if let s = cache[c] { return s }
        var r: Set<String> = []
        if isHan(c) {
            let base = latin(String(c))
            if !base.isEmpty { r.insert(base) }
            if let alt = alternates[c] { r.formUnion(alt.split(separator: " ").map(String.init)) }
        }
        let s = Sound(exact: r, fuzzy: Set(r.map(fuzzy)))
        cache[c] = s
        return s
    }

    /// Foundation 的汉字转拉丁字母，去声调；ü 先换成 v，免得 lü/lu、nü/nu 混成一样
    static func latin(_ s: String) -> String {
        let m = NSMutableString(string: s)
        CFStringTransform(m, nil, kCFStringTransformMandarinLatin, false)
        // 按 Unicode 标量处理：ǜ 分解成 u + ¨ + 声调，u 后面跟 ¨ 的写成 v，其余附加符号去掉
        var out = String.UnicodeScalarView()
        for sc in (m as String).decomposedStringWithCanonicalMapping.unicodeScalars {
            if sc.value == 0x0308, let last = out.last, last == "u" || last == "U" {
                out.removeLast(); out.append("v")
            } else if !(0x0300...0x036F).contains(sc.value) {
                out.append(sc)
            }
        }
        return String(out).lowercased().trimmingCharacters(in: .whitespaces)
    }

    /// 近音归一：平翘舌、n/l、前后鼻音
    static func fuzzy(_ s: String) -> String {
        var t = s
        for (a, b) in [("zh", "z"), ("ch", "c"), ("sh", "s")] where t.hasPrefix(a) {
            t = b + t.dropFirst(a.count)
        }
        if t.hasPrefix("l") { t = "n" + t.dropFirst() }
        for (a, b) in [("ang", "an"), ("eng", "en"), ("ing", "in")] where t.hasSuffix(a) {
            t = t.dropLast(a.count) + b
        }
        return t
    }

    /// 常见多音字的其它读音（Foundation 只给一个默认读音）
    static let alternates: [Character: String] = [
        "行": "xing hang", "重": "zhong chong", "长": "chang zhang", "乐": "le yue", "曾": "ceng zeng",
        "单": "dan shan chan", "朝": "chao zhao", "解": "jie xie", "查": "cha zha", "仇": "chou qiu",
        "区": "qu ou", "覃": "tan qin", "大": "da dai", "藏": "cang zang", "传": "chuan zhuan",
        "便": "bian pian", "参": "can shen cen", "差": "cha chai ci", "调": "diao tiao", "会": "hui kuai",
        "角": "jiao jue", "降": "jiang xiang", "校": "xiao jiao", "弹": "dan tan", "薄": "bo bao",
        "率": "lv shuai", "省": "sheng xing", "似": "si shi", "沈": "shen chen", "尉": "wei yu",
        "盛": "sheng cheng", "石": "shi dan", "柏": "bai bo", "秘": "mi bi", "系": "xi ji",
        "卡": "ka qia", "塞": "sai se", "壳": "ke qiao", "血": "xue xie", "露": "lu lou",
        "落": "luo la lao", "期": "qi ji", "识": "shi zhi", "属": "shu zhu", "宿": "su xiu",
        "圈": "quan juan", "扎": "zha za", "折": "zhe she", "转": "zhuan zhuai",
        "数": "shu shuo", "缪": "miao mou miu",
        "尾": "wei yi", "什": "shen shi", "提": "ti di", "模": "mo mu", "强": "qiang jiang",
        "称": "cheng chen", "奇": "qi ji",
        "核": "he hu", "恶": "e wu", "番": "fan pan", "炮": "pao bao", "厦": "sha xia",
        "叶": "ye xie", "车": "che ju", "莎": "sha suo", "茜": "qian xi", "蔚": "wei yu",
        "钥": "yao yue", "否": "fou pi", "给": "gei ji", "和": "he huo hu", "着": "zhe zhao zhuo",
        "得": "de dei", "地": "di de", "的": "de di", "了": "le liao", "还": "hai huan", "都": "du dou",
    ]
}

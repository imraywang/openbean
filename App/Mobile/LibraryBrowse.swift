// SPDX-License-Identifier: Apache-2.0

import CoreTransferable
import OpenBeanLibrary
import OpenBeanVoice
import SwiftUI
import UniformTypeIdentifiers

// 录音标签用的纯逻辑：筛选、搜索命中、分组、导出的文字。界面在 RecordingsTab / RecordingDetail

/// 按来源筛选
enum SourceFilter: String, CaseIterable, Identifiable {
    case all, heart, normal
    var id: String { rawValue }
    var label: LocalizedStringKey {
        switch self {
        case .all: return "All sources"
        case .heart: return "Heart mode"
        case .normal: return "Normal"
        }
    }
    func includes(_ r: Recording) -> Bool {
        switch self {
        case .all: return true
        case .heart: return r.recordingSource == .heart
        case .normal: return r.recordingSource == .normal
        }
    }
}

/// 按状态筛选
enum StatusFilter: String, CaseIterable, Identifiable {
    case all, onRecorder, untranscribed, summarized, marked, todos
    var id: String { rawValue }
    func label(heart: Bool) -> LocalizedStringKey {
        switch self {
        case .all: return "Any status"
        case .onRecorder: return DeviceWord.pick(heart, "On Heart bean", "On recorder")
        case .untranscribed: return "Waiting for transcript"
        case .summarized: return "Summarised"
        case .marked: return "Has marks"
        case .todos: return "Has to-dos"
        }
    }
    var icon: String {
        switch self {
        case .all: return "line.3.horizontal.decrease"
        case .onRecorder: return "arrow.down.circle"
        case .untranscribed: return "text.bubble"
        case .summarized: return "sparkles"
        case .marked: return "flag"
        case .todos: return "checklist"
        }
    }
}

/// 一条录音在列表里的处理状态（只取一个，按处理先后）
enum RecordingStatus: Equatable {
    case onRecorder
    case transcribing(Double)
    case waiting
    case transcribed
    case summarized

    var label: LocalizedStringKey {
        switch self {
        case .onRecorder: return "Not synced"
        case .transcribing: return "Transcribing…"
        case .waiting: return "Waiting for transcript"
        case .transcribed: return "Transcribed"
        case .summarized: return "Summarised"
        }
    }
}

/// 搜索命中：第几句、句子文字（只在转写里找到时有）、一共几处
struct SearchHit {
    var segment: Int?
    var text: String?
    var start: Double?
    var count: Int
}

@MainActor
extension LibraryStore {
    func status(_ r: Recording) -> RecordingStatus {
        if let p = transcribing[r.id] { return .transcribing(p) }
        if !r.downloaded { return .onRecorder }
        if !r.transcribed { return .waiting }
        return notes.cachedSummary(r.id) == nil ? .transcribed : .summarized
    }

    /// 标题：自己起的或摘要给的（摘要标题平常已经写进 title；没写进时用缓存的摘要标题）
    func listTitle(_ r: Recording) -> String {
        if let t = r.title, !t.isEmpty { return t }
        if let t = notes.cachedSummary(r.id)?.title, !t.isEmpty { return t }
        return r.start.formatted(date: .omitted, time: .shortened)
    }

    func includes(_ r: Recording, status f: StatusFilter) -> Bool {
        switch f {
        case .all: return true
        case .onRecorder: return !r.downloaded
        case .untranscribed: return r.downloaded && !r.transcribed
        case .summarized: return r.transcribed && notes.cachedSummary(r.id) != nil
        case .marked: return r.downloaded && !marks(r.id).isEmpty
        case .todos: return !notes.openTodos(r.id).isEmpty
        }
    }

    /// 搜标题、摘要和转写全文；没命中返回 nil
    func search(_ r: Recording, _ query: String) -> SearchHit? {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return SearchHit(count: 0) }
        var count = 0
        var first: SearchHit?
        if listTitle(r).localizedCaseInsensitiveContains(q) { count += 1 }
        if let s = notes.cachedSummary(r.id),
           ([s.summary] + s.keyPoints + s.actionItems).contains(where: { $0.localizedCaseInsensitiveContains(q) }) { count += 1 }
        if r.transcribed {
            for (i, seg) in transcript(r.id).enumerated() where seg.text.localizedCaseInsensitiveContains(q) {
                count += Self.occurrences(of: q, in: seg.text)
                if first == nil { first = SearchHit(segment: i, text: seg.text, start: seg.start, count: 0) }
            }
        }
        guard count > 0 else { return nil }
        var hit = first ?? SearchHit(count: 0)
        hit.count = count
        return hit
    }

    nonisolated static func occurrences(of q: String, in s: String) -> Int {
        var n = 0
        var range = s.startIndex..<s.endIndex
        while let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: range) {
            n += 1
            range = r.upperBound..<s.endIndex
        }
        return max(n, 1)
    }

    /// 按「一天从几点开始」分天，组标题是日期（今天、昨天、星期几、月日）
    func daySections(_ items: [Recording]) -> [(day: Date, items: [Recording])] {
        let b = dayBoundary
        var order: [Date] = []
        var groups: [Date: [Recording]] = [:]
        for r in items {
            let d = b.day(of: r.start)
            if groups[d] == nil { order.append(d) }
            groups[d, default: []].append(r)
        }
        return order.map { ($0, groups[$0]!) }
    }

    func dayTitle(_ day: Date) -> String {
        let b = dayBoundary
        let today = b.day(of: Date())
        if day == today { return String(localized: "Today") }
        if day == b.day(today, offsetBy: -1) { return String(localized: "Yesterday") }
        let days = Calendar.current.dateComponents([.day], from: day, to: today).day ?? 99
        if days < 7 { return day.formatted(.dateTime.weekday(.wide).month().day()) }
        if Calendar.current.isDate(day, equalTo: today, toGranularity: .year) { return day.formatted(.dateTime.month().day().weekday()) }
        return day.formatted(date: .long, time: .omitted)
    }

    /// 纯文本的转写：标题、时间，再按段落（每段前面是时间）
    func plainText(_ id: UInt32) -> String {
        guard let r = recordings.first(where: { $0.id == id }) else { return "" }
        let segs = transcript(id)
        var s = "\(listTitle(r))\n\(r.start.formatted(date: .long, time: .shortened)) · \(Self.clock(r.duration))\n\n"
        if let sum = notes.summary(id) {
            s += sum.summary + "\n\n"
            for p in sum.keyPoints { s += "• \(p)\n" }
            if !sum.keyPoints.isEmpty { s += "\n" }
            for a in sum.actionItems { s += "☐ \(a)\n" }
            if !sum.actionItems.isEmpty { s += "\n" }
        }
        for p in TranscriptParagraphs.group(segs) {
            var line = ""
            for i in p {
                if i > p.lowerBound { line += TranscriptParagraphs.joiner(after: segs[i - 1].text, before: segs[i].text) }
                line += segs[i].text
            }
            s += "[\(Self.clock(segs[p.lowerBound].start))] \(line)\n\n"
        }
        return s
    }

    /// 分享用的文件名（去掉文件名里不能有的字符）
    func exportName(_ r: Recording) -> String {
        let bad = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let t = listTitle(r).components(separatedBy: bad).joined(separator: "-")
        return "\(r.start.formatted(.iso8601.year().month().day())) \(t)"
    }
}

/// 分享面板里的文件：点了分享才写到临时目录。音频用硬链接（不复制几十 MB），文件名用录音的日期和标题
enum ExportFiles {
    nonisolated static func write(name: String, ext: String, data: Data?, link: URL?) throws -> SentTransferredFile {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).\(ext)")
        if let link {
            if (try? FileManager.default.linkItem(at: link, to: url)) == nil { try FileManager.default.copyItem(at: link, to: url) }
        } else {
            try (data ?? Data()).write(to: url)
        }
        return SentTransferredFile(url)
    }
}

struct MarkdownExport: Transferable {
    let name: String
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText) {
            try ExportFiles.write(name: $0.name, ext: "md", data: Data($0.text.utf8), link: nil)
        }
    }
}

struct PlainTextExport: Transferable {
    let name: String
    let text: String
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .utf8PlainText) {
            try ExportFiles.write(name: $0.name, ext: "txt", data: Data($0.text.utf8), link: nil)
        }
    }
}

struct AudioExport: Transferable {
    let name: String
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: UTType(filenameExtension: "ogg", conformingTo: .audio) ?? .audio) {
            try ExportFiles.write(name: $0.name, ext: "ogg", data: nil, link: $0.url)
        }
    }
}

/// 把命中的词标出来（列表的片段、详情的转写都用）
enum Highlight {
    static func apply(_ q: String, to s: inout AttributedString, base: String) {
        let q = q.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var from = base.startIndex
        while let r = base.range(of: q, options: [.caseInsensitive, .diacriticInsensitive], range: from..<base.endIndex) {
            if let ar = Range(r, in: s) {
                s[ar].backgroundColor = Color.yellow.opacity(0.45)
                s[ar].inlinePresentationIntent = .stronglyEmphasized
            }
            from = r.upperBound
        }
    }

    static func text(_ s: String, _ q: String) -> AttributedString {
        var a = AttributedString(s)
        apply(q, to: &a, base: s)
        return a
    }

    /// 长句子只留命中处前后一点
    static func excerpt(_ s: String, around q: String, radius: Int = 36) -> String {
        guard let r = s.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) else { return s }
        let lo = s.index(r.lowerBound, offsetBy: -radius, limitedBy: s.startIndex) ?? s.startIndex
        let hi = s.index(r.upperBound, offsetBy: radius, limitedBy: s.endIndex) ?? s.endIndex
        return (lo > s.startIndex ? "…" : "") + s[lo..<hi] + (hi < s.endIndex ? "…" : "")
    }
}

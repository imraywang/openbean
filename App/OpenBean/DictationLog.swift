// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// 一次语音输入
struct DictationEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    /// 从可以说话到结束，秒
    var duration: Double
    var text: String
    /// 输入到哪个 App（开始时的前台 App）
    var app: String?
    /// 没打进 App，放进了剪贴板
    var viaClipboard: Bool

    var characters: Int { text.filter { !$0.isWhitespace && !$0.isNewline }.count }
}

/// 语音输入记录：只存在这台 Mac 上（Application Support/openbean/dictation.json）
@MainActor @Observable
final class DictationLog {
    private(set) var entries: [DictationEntry] = []
    private let url = AppPaths.support.appendingPathComponent("dictation.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder.iso.decode([DictationEntry].self, from: data) {
            entries = list.sorted { $0.date > $1.date }
        }
    }

    func add(_ e: DictationEntry) {
        guard !e.text.isEmpty else { return }
        entries.insert(e, at: 0)
        save()
    }

    func delete(_ id: DictationEntry.ID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    func entries(in interval: DateInterval?) -> [DictationEntry] {
        guard let interval else { return entries }
        return entries.filter { interval.contains($0.date) }
    }

    private func save() {
        guard let data = try? JSONEncoder.iso.encode(entries) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static let iso: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()
}

extension JSONEncoder {
    static let iso: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted]; return e }()
}

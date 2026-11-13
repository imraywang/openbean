// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import OpenBeanVoice

/// 词表变了之后，把它重新应用到录音库里已有的转写（transcript.json）。
///
/// - 什么时候：App 启动时、词表文件所在的文件夹有变化（编辑器保存词表）、App 回到前台时检查一次；
///   词表（解析后的词条和别名）和上次应用的一样就什么都不做。`openbean://glossary/apply` 强制重来一遍。
/// - 怎么做：后台逐条录音读 transcript.json，每句从 raw（识别器原文）重算（TranscriptCorrection），有变化才写回；
///   写回后录音库丢掉缓存、笔记按规则刷新。新的检查来了就中断当前这遍、按新词表重来。
/// - 不动：语音输入记录（dictation.json）、正在转写的录音（转写本身就用最新词表）。
@MainActor
final class GlossaryBackfill {
    private let library: LibraryStore
    private var task: Task<Void, Never>?
    private var pendingCheck: Task<Void, Never>?
    private var watcher: DispatchSourceFileSystemObject?
    private var activeObserver: NSObjectProtocol?
    /// 上次完整应用到所有转写的词表指纹
    private static let hashKey = "glossaryAppliedHash"

    init(library: LibraryStore) {
        self.library = library
    }

    func start() {
        check(force: false)
        watchGlossaryFolder()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSoon() }
        }
    }

    /// 检查词表有没有变；变了（或 force）就开始一遍回填，正在跑的那遍中断
    func check(force: Bool) {
        let lines = AppPaths.readGlossary()
        let hash = TranscriptCorrection.glossaryHash(lines)
        let last = UserDefaults.standard.string(forKey: Self.hashKey)
        guard TranscriptCorrection.needsBackfill(currentHash: hash, lastApplied: last, force: force) else { return }
        Log.write(force ? "词表回填：手动触发" : "词表回填：词表和上次应用的不一样")
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            await previous?.value
            await self?.run(lines: lines, hash: hash)
        }
    }

    /// 文件夹里一下子会有好几次变化（编辑器先写临时文件再改名）：合并成 2 秒后的一次检查
    private func checkSoon() {
        pendingCheck?.cancel()
        pendingCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.check(force: false)
        }
    }

    /// 盯着词表所在的文件夹：编辑器保存时多半是「写临时文件 → 改名」，文件夹会变；原地写的编辑器靠回到前台时的检查
    private func watchGlossaryFolder() {
        let dir = AppPaths.glossary.deletingLastPathComponent()
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename], queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.checkSoon() } }
        src.setCancelHandler { close(fd) }
        src.resume()
        watcher = src
    }

    private func run(lines: [String], hash: String) async {
        let t0 = Date()
        let corrector = await Task.detached(priority: .utility) { GlossaryCorrector(terms: lines) }.value
        let ids = library.recordings.filter(\.transcribed).map(\.id)
        var touched = 0, changedLines = 0, skipped = 0
        for id in ids {
            if Task.isCancelled {
                Log.write("词表回填：中断（词表又变了），已处理 \(touched) 条有变化的录音")
                return
            }
            // 正在转写的这条会用最新的词表，不用管
            if library.transcribing[id] != nil { skipped += 1; continue }
            let url = library.transcriptURL(id)
            guard let n = await Task.detached(priority: .utility, operation: { Self.rewrite(url, with: corrector) }).value else {
                skipped += 1
                continue
            }
            if n > 0 {
                touched += 1
                changedLines += n
                library.transcriptRewritten(id)
            }
        }
        UserDefaults.standard.set(hash, forKey: Self.hashKey)
        Log.write(String(format: "词表回填：%d 条录音，%d 条有变化，共改了 %d 句%@，用时 %.1f 秒",
                         ids.count, touched, changedLines, skipped > 0 ? "（跳过 \(skipped) 条）" : "",
                         Date().timeIntervalSince(t0)))
    }

    /// 重新应用词表到一个转写文件；返回变了几句（0 = 没变、没写），读不了返回 nil
    nonisolated static func rewrite(_ url: URL, with corrector: GlossaryCorrector) -> Int? {
        guard let d = try? Data(contentsOf: url),
              var segs = try? JSONDecoder().decode([TranscriptSegment].self, from: d) else { return nil }
        let n = TranscriptCorrection.apply(corrector, to: &segs)
        if n > 0, let out = try? JSONEncoder().encode(segs) {
            guard (try? out.write(to: url, options: .atomic)) != nil else { return nil }
        }
        return n
    }
}


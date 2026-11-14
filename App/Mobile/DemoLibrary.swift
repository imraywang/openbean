// SPDX-License-Identifier: Apache-2.0

import Foundation
import OpenBeanVoice

/// 演示数据里录音标签要用的几个状态（只在 -demo 下）：一条正在转写、一份个人词表、「转写」按钮的假进度
@MainActor
enum DemoLibrary {
    private static var prepared = false

    static func prepare(_ library: LibraryStore) {
        guard Flavor.isFake, !prepared else { return }
        prepared = true
        // 第一条还没转写的（演示数据里是两条 raw 之一）：摆成正在转写
        if library.transcribing.isEmpty,
           let r = library.recordings.first(where: { $0.downloaded && !$0.transcribed && !$0.isDictation }) {
            library.demoSet(sync: library.sync, transcribing: [r.id: 0.42])
        }
        if GlossaryFile.load().entries.isEmpty {
            var f = GlossaryFile.load()
            for line in ["OpenBean", "Claude Code = cloud code, 克劳德 code", "Priya = 普瑞雅", "刘经理 = 刘静里", "心力豆", "激活率"] {
                if let e = GlossaryCorrector.Entry.parse(line) { f.append(e) }
            }
            f.save()
        }
    }

    /// 演示数据没有能转写的音频：进度走一圈后停在原样（不改录音库）
    static func fakeTranscribe(_ id: UInt32, library: LibraryStore) {
        Task { @MainActor in
            for p in stride(from: 0.0, through: 1.0, by: 0.1) {
                var t = library.transcribing
                t[id] = p
                library.demoSet(sync: library.sync, transcribing: t)
                try? await Task.sleep(for: .milliseconds(300))
            }
            var t = library.transcribing
            t[id] = nil
            library.demoSet(sync: library.sync, transcribing: t)
        }
    }
}

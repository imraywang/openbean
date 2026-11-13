// SPDX-License-Identifier: Apache-2.0

import Foundation

/// 续航统计用的电量日志行（`Scripts/battery-report.py` 读）：设备文件列表里新出现、或时长变长的录音。
///
/// 录音豆离开 Mac 时 App 看不到它，离线录了多久只能事后从文件列表里知道：
/// 文件 id 是开始时间（unix 秒），列表里有结束时间和时长。脚本拿「断开时的电量 + 重连时的电量 +
/// 这段空档里录音的总时长」算录音耗电。
public enum DeviceFileLog {
    /// `known`：这次读列表之前本机记得的各文件时长（毫秒）。新文件、或时长变了的文件各一行；
    /// 有任何一行时再加一行设备上的合计。没有变化返回空。
    public static func lines(known: [UInt32: UInt32], files: [RecordingFile], recorder: Int?) -> [String] {
        let level = recorder.map(String.init) ?? "?"
        var out: [String] = []
        for f in files.sorted(by: { $0.id < $1.id }) where f.durationMs > 0 && known[f.id] != f.durationMs {
            let end = f.endTime.map(String.init) ?? "?"
            out.append("battery event=device-file file=\(f.id) start=\(f.id) end=\(end) "
                       + "seconds=\(String(format: "%.1f", f.durationSeconds)) recorder=\(level)")
        }
        guard !out.isEmpty else { return [] }
        let total = files.reduce(0.0) { $0 + $1.durationSeconds }
        out.append("battery event=device-files count=\(files.count) seconds=\(String(format: "%.1f", total)) recorder=\(level)")
        return out
    }
}

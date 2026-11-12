// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import Foundation

// MARK: - 删除录音豆上的录音
//
// 1A/10 在设备上删一个录音文件，删了不能恢复。⚠️ 这条命令还没在真机上验证过：
// 帧格式和回包来自社区笔记（tacshi/Soundcore），见 docs/PROTOCOL.md。
// 所以这里把安全规则写死在代码里，App 和命令行都只能经过它删。

/// 能不能删：只有已经完整下载到本机的录音才能删。纯函数，方便测试。
public enum DeletePolicy {
    public enum Refusal: Error, Equatable, CustomStringConvertible {
        /// 正在同步或语音输入，连接被占用
        case busy
        /// 录音豆正在录音（或读不到录音状态）
        case recording
        case notOnRecorder
        case notDownloaded
        /// 本机音频文件不存在或解不开
        case localAudioMissing
        /// 设备上的时长是 0，无法核对
        case emptyRecording
        /// 本机音频解出来的时长和设备上的对不上
        case durationMismatch(local: Double, expected: Double)

        public var description: String {
            switch self {
            case .busy: return "正在同步或语音输入，稍后再删"
            case .recording: return "录音豆正在录音，录完再删"
            case .notOnRecorder: return "录音豆上已经没有这条录音"
            case .notDownloaded: return "还没下载到本机，不能删"
            case .localAudioMissing: return "本机的音频文件不存在或无法解码，不能删"
            case .emptyRecording: return "设备上这条录音时长为 0，无法核对，不能删"
            case let .durationMismatch(l, e):
                return String(format: "本机音频 %.1f 秒，设备上 %.1f 秒，对不上，不能删", l, e)
            }
        }
    }

    /// 允许的时长误差：1 秒或 1%，取大的。完整下载的文件帧数和设备列出的时长应当几乎一致。
    public static func tolerance(expected: Double) -> Double { max(1.0, expected * 0.01) }

    /// 返回 nil 表示可以删；否则是拒绝的原因（按检查顺序取第一个）。
    public static func check(onRecorder: Bool, downloaded: Bool, localSeconds: Double?, expectedSeconds: Double,
                             recorderRecording: Bool?, busy: Bool) -> Refusal? {
        if busy { return .busy }
        // 读不到录音状态也当作在录，宁可不删
        if recorderRecording != false { return .recording }
        if !onRecorder { return .notOnRecorder }
        if !downloaded { return .notDownloaded }
        guard let local = localSeconds, local > 0 else { return .localAudioMissing }
        guard expectedSeconds > 0 else { return .emptyRecording }
        if abs(local - expectedSeconds) > tolerance(expected: expectedSeconds) {
            return .durationMismatch(local: local, expected: expectedSeconds)
        }
        return nil
    }
}

public enum DeleteError: Error, CustomStringConvertible {
    case refused(DeletePolicy.Refusal)
    /// 设备回包 status 不是成功
    case rejected(status: UInt8)
    /// 回读列表时这条还在
    case stillPresent(UInt32)
    /// 回读列表时别的录音也不见了
    case othersMissing([UInt32])

    public var description: String {
        switch self {
        case let .refused(r): return r.description
        case let .rejected(st): return String(format: "录音豆拒绝删除（status=%02X）", st)
        case let .stillPresent(id): return "删除后录音豆上仍有 \(id)"
        case let .othersMissing(ids): return "删除后另外 \(ids.count) 条录音也不见了：\(ids.map(String.init).joined(separator: ", "))"
        }
    }

    /// 回读列表核对：要删的那条不见了，删之前的其它录音都还在（期间新录的可以多出来）。
    public static func verify(deleted id: UInt32, before: [RecordingFile], after: [RecordingFile]) throws {
        let now = Set(after.map(\.id))
        if now.contains(id) { throw DeleteError.stillPresent(id) }
        let missing = before.map(\.id).filter { $0 != id && !now.contains($0) }
        if !missing.isEmpty { throw DeleteError.othersMissing(missing.sorted()) }
    }
}

public enum LocalAudio {
    /// 把本机的音频文件（Ogg Opus）完整解码一遍，返回实际时长（秒）；文件不存在或解不开返回 nil。
    /// 不用 AVAudioFile.length：Ogg Opus 的 length 是估算值。
    public static func decodedSeconds(_ url: URL) -> Double? {
        guard FileManager.default.fileExists(atPath: url.path),
              let f = try? AVAudioFile(forReading: url) else { return nil }
        let rate = f.processingFormat.sampleRate
        guard rate > 0, let buf = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 48000 * 10) else { return nil }
        var frames: Int64 = 0
        while true {
            do {
                try f.read(into: buf, frameCount: buf.frameCapacity)
            } catch {
                // 读到末尾时 AVAudioFile 会抛错：多数情况是 eofErr（-39），命令行程序里实测是 nilError。
                // 已经读到数据就当作读完；中途坏掉也只会少算时长，结果是拒绝删除（安全的方向）。
                if frames > 0 { break }
                return nil
            }
            if buf.frameLength == 0 { break }
            frames += Int64(buf.frameLength)
        }
        return frames > 0 ? Double(frames) / rate : nil
    }
}

extension D3200Session {
    /// 删除录音豆上的一个录音。⚠️ 1A/10 未经真机验证，删了不能恢复。
    ///
    /// 1. 读设备信息：正在录音（或读不到状态）就不删。
    /// 2. 读文件列表，找到这条，交给 `approve` 用设备上最新的时长做本机检查（不通过就抛错）。
    /// 3. 发 1A/10，等 1A/10 回包（status 低 4 位为 1 才算成功）。
    /// 4. 再读一遍列表：这条必须不见了，其它录音必须都还在。返回删除后的列表。
    public func deleteFile(id: UInt32, approve: (RecordingFile) async throws -> Void) async throws -> [RecordingFile] {
        guard let info = try await deviceInfo() else { throw LinkError.missing("设备信息") }
        guard info.recording == false else { throw DeleteError.refused(.recording) }
        let before = try await listFiles()
        guard let file = before.first(where: { $0.id == id }) else { throw DeleteError.refused(.notOnRecorder) }
        try await approve(file)
        let ack = try await link.request(Cmd.deleteFile(id: id), timeout: 10, label: "删除录音 \(id)") {
            Rx.isTransport($0) && $0.id == Rx.deleteFile
        }
        guard ack.isSuccess else { throw DeleteError.rejected(status: ack.status) }
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = try await listFiles()
        try DeleteError.verify(deleted: id, before: before, after: after)
        return after
    }
}
